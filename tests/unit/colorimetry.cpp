// Panel characterization and SDR gamut mapping (umbriel#574 wave 1).
// ICC cases skip when built without lcms2; the pure matrix/TRC/decision pins always run.

#include "output/colorimetry.h"

#include "check.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <format>
#include <optional>
#include <print>
#include <span>
#include <string>
#include <vector>

#if UMBRIEL_HAS_LCMS2
#include <lcms2.h>
#endif

namespace {

  bool closeTo(double actual, double expected, double tolerance = 0.002) {
    return std::abs(actual - expected) < tolerance;
  }

  wlr_color_primaries srgbPrimaries() {
    return {
        .red = {.x = 0.64F, .y = 0.33F},
        .green = {.x = 0.30F, .y = 0.60F},
        .blue = {.x = 0.15F, .y = 0.06F},
        .white = {.x = 0.3127F, .y = 0.329F},
    };
  }

  wlr_color_primaries displayP3Primaries() {
    return {
        .red = {.x = 0.68F, .y = 0.32F},
        .green = {.x = 0.265F, .y = 0.69F},
        .blue = {.x = 0.15F, .y = 0.06F},
        .white = {.x = 0.3127F, .y = 0.329F},
    };
  }

  wlr_color_primaries bt2020Primaries() {
    return {
        .red = {.x = 0.708F, .y = 0.292F},
        .green = {.x = 0.170F, .y = 0.797F},
        .blue = {.x = 0.131F, .y = 0.046F},
        .white = {.x = 0.3127F, .y = 0.329F},
    };
  }

  // EDID base block with gamma 2.2 and D65 chromaticity (spec 3.7: two
  // low-bits blobs at bytes 25-26, then the 8 MSB bytes).
  std::array<uint8_t, 128> edidWithD65AndGamma22() {
    std::array<uint8_t, 128> edid{};
    edid[0] = 0x00;
    edid[1] = 0xFF;
    edid[2] = 0xFF;
    edid[3] = 0xFF;
    edid[4] = 0xFF;
    edid[5] = 0xFF;
    edid[6] = 0xFF;
    edid[7] = 0x00;
    edid[18] = 0x01;
    edid[19] = 0x04;
    edid[23] = 120; // gamma = 2.2
    // 10-bit fixed point: value = coordinate * 1024.
    const std::array<std::array<uint16_t, 2>, 4> xy{{
        {655, 338}, // red (0.64, 0.33)
        {307, 614}, // green (0.30, 0.60)
        {154, 61},  // blue (0.15, 0.06)
        {320, 337}, // white (D65 at EDID precision)
    }};
    edid[25] =
        static_cast<uint8_t>(((xy[0][0] & 3) << 6) | ((xy[0][1] & 3) << 4) | ((xy[1][0] & 3) << 2) | (xy[1][1] & 3));
    edid[26] =
        static_cast<uint8_t>(((xy[2][0] & 3) << 6) | ((xy[2][1] & 3) << 4) | ((xy[3][0] & 3) << 2) | (xy[3][1] & 3));
    edid[27] = static_cast<uint8_t>(xy[0][0] >> 2);
    edid[28] = static_cast<uint8_t>(xy[0][1] >> 2);
    edid[29] = static_cast<uint8_t>(xy[1][0] >> 2);
    edid[30] = static_cast<uint8_t>(xy[1][1] >> 2);
    edid[31] = static_cast<uint8_t>(xy[2][0] >> 2);
    edid[32] = static_cast<uint8_t>(xy[2][1] >> 2);
    edid[33] = static_cast<uint8_t>(xy[3][0] >> 2);
    edid[34] = static_cast<uint8_t>(xy[3][1] >> 2);
    uint8_t checksum = 0;
    for (size_t index = 0; index < 127; ++index) {
      checksum = static_cast<uint8_t>(checksum + edid[index]);
    }
    edid[127] = static_cast<uint8_t>(0 - checksum);
    return edid;
  }

#if UMBRIEL_HAS_LCMS2
  std::vector<uint8_t> saveProfile(cmsHPROFILE profile) {
    cmsUInt32Number size = 0;
    cmsSaveProfileToMem(profile, nullptr, &size);
    std::vector<uint8_t> bytes(size);
    cmsSaveProfileToMem(profile, bytes.data(), &size);
    bytes.resize(size);
    return bytes;
  }

  // Matrix-shaper RGB display profile, as Mutter's meta-color-device.c builds them in-test.
  std::vector<uint8_t> matrixShaperProfile(
      const cmsCIExyY& white, const cmsCIExyYTRIPLE& primaries, const std::array<cmsToneCurve*, 3>& curves
  ) {
    cmsHPROFILE profile = cmsCreateRGBProfileTHR(nullptr, &white, &primaries, curves.data());
    std::vector<uint8_t> bytes;
    if (profile != nullptr) {
      bytes = saveProfile(profile);
      cmsCloseProfile(profile);
    }
    return bytes;
  }

  cmsToneCurve* srgbDecodeCurve() {
    // lcms2 parametric type 4 = ICC parametricCurveType format 3 (the sRGB
    // EOTF): Y = (aX + b)^g above d, else cX.
    const cmsFloat64Number params[5] = {2.4, 1.0 / 1.055, 0.055 / 1.055, 1.0 / 12.92, 0.04045};
    return cmsBuildParametricToneCurve(nullptr, 4, params);
  }

  // Gamma 2.4 is deliberately not a named fast path, so it exercises the
  // sampled-curve baking.
  cmsToneCurve* tabulatedGamma24Curve() {
    constexpr size_t size = 256;
    std::vector<uint16_t> values(size);
    for (size_t index = 0; index < size; ++index) {
      const double encoded = static_cast<double>(index) / (size - 1);
      values[index] = static_cast<uint16_t>(std::lround(std::pow(encoded, 2.4) * 65535.0));
    }
    return cmsBuildTabulatedToneCurve16(nullptr, static_cast<cmsUInt32Number>(size), values.data());
  }

  cmsCIExyY xyY(double x, double y) { return {.x = x, .y = y, .Y = 1.0}; }
#endif

} // namespace

UMBRIEL_TEST(sdrGamutMatrixPinsSrgbToDisplayP3AndBt2020) {
  // Published constant matrices (both sets are D65, so absolute = relative here).
  constexpr std::array<float, 9> expectP3{
      0.8225F, 0.1775F, 0.0000F, 0.0332F, 0.9668F, 0.0000F, 0.0171F, 0.0724F, 0.9105F,
  };
  constexpr std::array<float, 9> expectBt2020{
      0.6274F, 0.3293F, 0.0433F, 0.0691F, 0.9195F, 0.0114F, 0.0164F, 0.0880F, 0.8956F,
  };
  float matrix[9];
  umbriel::sdrGamutMatrix(displayP3Primaries(), 0.0F, matrix);
  for (size_t index = 0; index < 9; ++index) {
    if (!closeTo(matrix[index], expectP3[index])) {
      umbriel::test::reportFailure(
          __FILE__, __LINE__,
          std::format("sRGB->P3 matrix[{}] = {}, expected {}", index, matrix[index], expectP3[index])
      );
    }
  }
  umbriel::sdrGamutMatrix(bt2020Primaries(), 0.0F, matrix);
  for (size_t index = 0; index < 9; ++index) {
    if (!closeTo(matrix[index], expectBt2020[index])) {
      umbriel::test::reportFailure(
          __FILE__, __LINE__,
          std::format("sRGB->BT.2020 matrix[{}] = {}, expected {}", index, matrix[index], expectBt2020[index])
      );
    }
  }
}

UMBRIEL_TEST(sdrGamutMatrixNativeWidenessIsIdentity) {
  float matrix[9];
  umbriel::sdrGamutMatrix(displayP3Primaries(), 1.0F, matrix);
  for (size_t row = 0; row < 3; ++row) {
    for (size_t column = 0; column < 3; ++column) {
      const float expected = row == column ? 1.0F : 0.0F;
      if (!closeTo(matrix[row * 3 + column], expected, 1e-4)) {
        umbriel::test::reportFailure(
            __FILE__, __LINE__,
            std::format("native wideness matrix[{}][{}] = {}", row, column, matrix[row * 3 + column])
        );
      }
    }
  }
}

UMBRIEL_TEST(trcEncodeBakingSeparatesGamma22FromSrgb) {
  const umbriel::PanelTransfer gamma22{.kind = umbriel::PanelTransfer::Kind::Gamma22, .encode = {}};
  const umbriel::PanelTransfer srgb{.kind = umbriel::PanelTransfer::Kind::Srgb, .encode = {}};

  CHECK_EQ(umbriel::panelEncodeSample(gamma22, 0.0F), 0.0F);
  CHECK_EQ(umbriel::panelEncodeSample(gamma22, 1.0F), 1.0F);
  CHECK(closeTo(umbriel::panelEncodeSample(gamma22, 0.5F), std::pow(0.5, 1.0 / 2.2), 1e-4));

  CHECK_EQ(umbriel::panelEncodeSample(srgb, 0.0F), 0.0F);
  CHECK_EQ(umbriel::panelEncodeSample(srgb, 1.0F), 1.0F);
  CHECK(closeTo(umbriel::panelEncodeSample(srgb, 0.5F), 1.055 * std::pow(0.5, 1.0 / 2.4) - 0.055, 1e-4));

  // The two curves must differ where the sRGB toe lives.
  CHECK(std::abs(umbriel::panelEncodeSample(gamma22, 0.02F) - umbriel::panelEncodeSample(srgb, 0.02F)) > 1e-3);

  const std::vector<uint16_t> lut = umbriel::bakeEncodeLut(gamma22, 3);
  CHECK_EQ(lut.size(), size_t{3});
  CHECK_EQ(lut[0], uint16_t{0});
  CHECK_EQ(lut[2], uint16_t{65535});
  CHECK(closeTo(lut[1], std::lround(std::pow(0.5, 1.0 / 2.2) * 65535.0), 1.0));
}

UMBRIEL_TEST(sdrGamutStagingDecisionPreservesNativePixels) {
  using umbriel::SdrGamut;
  // No characterization: nothing to map.
  CHECK(!umbriel::sdrGamutStaged(false, SdrGamut::Srgb, false));
  // "native" stages NO transform at all: pixels stay bit-identical.
  CHECK(!umbriel::sdrGamutStaged(true, SdrGamut::Native, false));
  CHECK(umbriel::sdrGamutStaged(true, SdrGamut::Srgb, false));
  // An active HDR image description owns the output transform.
  CHECK(!umbriel::sdrGamutStaged(true, SdrGamut::Srgb, true));
}

UMBRIEL_TEST(sdrGamutTransformBakesPanelEncodeCurve) {
  // A sampled encode curve runs through the LUT stage, which clamps negatives
  // the float matrix can leave behind, so the eval pins are exact here.
  umbriel::PanelColorimetry panel{
      .primaries = srgbPrimaries(),
      .white = {0.3127F, 0.329F},
      .transfer = {.kind = umbriel::PanelTransfer::Kind::Curve, .encode = {}},
  };
  // A gamma 2.2 encode curve, sampled the way the ICC parser bakes one.
  panel.transfer.encode.resize(1024);
  for (size_t index = 0; index < panel.transfer.encode.size(); ++index) {
    const float linear = static_cast<float>(index) / static_cast<float>(panel.transfer.encode.size() - 1);
    panel.transfer.encode[index] = std::pow(linear, 1.0F / 2.2F);
  }
  wlr_color_transform* transform = umbriel::buildSdrGamutTransform(panel);
  CHECK(transform != nullptr);
  if (transform == nullptr) {
    return;
  }
  float output[3]{};
  const float input[3]{0.5F, 0.0F, 0.0F};
  wlr_color_transform_eval(transform, output, input);
  CHECK(closeTo(output[0], std::pow(0.5, 1.0 / 2.2), 1e-3));
  CHECK(closeTo(output[1], 0.0, 1e-4));
  CHECK(closeTo(output[2], 0.0, 1e-4));
  wlr_color_transform_unref(transform);
}

UMBRIEL_TEST(edidColorimetryUsesColorantsGammaAndWhite) {
  const auto edid = edidWithD65AndGamma22();
  const wlr_color_primaries panel = displayP3Primaries();
  const std::optional<umbriel::PanelColorimetry> parsed = umbriel::panelColorimetryFromEdid(edid, &panel);
  CHECK(parsed.has_value());
  if (!parsed) {
    return;
  }
  CHECK(closeTo(parsed->primaries.red.x, 0.68));
  CHECK(closeTo(parsed->primaries.green.y, 0.69));
  CHECK(closeTo(parsed->white[0], 0.3127, 0.005));
  CHECK(closeTo(parsed->white[1], 0.329, 0.005));
  CHECK(parsed->transfer.kind == umbriel::PanelTransfer::Kind::Gamma22);
}

UMBRIEL_TEST(edidColorimetryStaysInertWithoutEdidOrPrimaries) {
  CHECK(!umbriel::panelColorimetryFromEdid({}, nullptr).has_value());
  const auto edid = edidWithD65AndGamma22();
  const wlr_color_primaries srgb = srgbPrimaries();
  CHECK(!umbriel::panelColorimetryFromEdid({}, &srgb).has_value());
  CHECK(!umbriel::panelColorimetryFromEdid(edid, nullptr).has_value());
}

UMBRIEL_TEST(iccMatrixShaperRoundTripsColorantsWhiteAndTrc) {
#if !UMBRIEL_HAS_LCMS2
  std::println("skip: built without lcms2");
#else
  std::array<cmsToneCurve*, 3> curves{
      cmsBuildGamma(nullptr, 2.2), cmsBuildGamma(nullptr, 2.2), cmsBuildGamma(nullptr, 2.2)
  };
  const std::vector<uint8_t> bytes = matrixShaperProfile(
      xyY(0.3127, 0.329), {.Red = xyY(0.64, 0.33), .Green = xyY(0.30, 0.60), .Blue = xyY(0.15, 0.06)}, curves
  );
  for (cmsToneCurve* curve : curves) {
    cmsFreeToneCurve(curve);
  }
  CHECK(!bytes.empty());
  const umbriel::IccParse parsed = umbriel::parseIccProfile(bytes);
  CHECK(parsed.error.empty());
  CHECK(parsed.colorimetry.has_value());
  if (!parsed.colorimetry) {
    return;
  }
  const umbriel::PanelColorimetry& panel = *parsed.colorimetry;
  CHECK(closeTo(panel.primaries.red.x, 0.64));
  CHECK(closeTo(panel.primaries.green.y, 0.60));
  CHECK(closeTo(panel.primaries.blue.x, 0.15));
  CHECK(closeTo(panel.white[0], 0.3127, 0.005));
  CHECK(closeTo(panel.white[1], 0.329, 0.005));
  CHECK(panel.transfer.kind == umbriel::PanelTransfer::Kind::Gamma22);
#endif
}

UMBRIEL_TEST(iccChadTagRecoversMeasuredWhiteAndColorants) {
#if !UMBRIEL_HAS_LCMS2
  std::println("skip: built without lcms2");
#else
  // A non-D50 white forces lcms2 to adapt the colorants and record chad; the
  // parser must undo that adaptation to recover the measured colorimetry.
  std::array<cmsToneCurve*, 3> curves{srgbDecodeCurve(), srgbDecodeCurve(), srgbDecodeCurve()};
  const std::vector<uint8_t> bytes = matrixShaperProfile(
      xyY(0.3324, 0.3474), // D55
      {.Red = xyY(0.68, 0.32), .Green = xyY(0.265, 0.69), .Blue = xyY(0.15, 0.06)}, curves
  );
  for (cmsToneCurve* curve : curves) {
    cmsFreeToneCurve(curve);
  }
  CHECK(!bytes.empty());
  const umbriel::IccParse parsed = umbriel::parseIccProfile(bytes);
  CHECK(parsed.colorimetry.has_value());
  if (!parsed.colorimetry) {
    return;
  }
  const umbriel::PanelColorimetry& panel = *parsed.colorimetry;
  CHECK(closeTo(panel.primaries.red.x, 0.68, 0.005));
  CHECK(closeTo(panel.primaries.green.y, 0.69, 0.005));
  CHECK(closeTo(panel.primaries.blue.y, 0.06, 0.005));
  CHECK(closeTo(panel.white[0], 0.3324, 0.005));
  CHECK(closeTo(panel.white[1], 0.3474, 0.005));
  CHECK(panel.transfer.kind == umbriel::PanelTransfer::Kind::Srgb);
#endif
}

UMBRIEL_TEST(iccTabulatedTrcBakesEncodeCurve) {
#if !UMBRIEL_HAS_LCMS2
  std::println("skip: built without lcms2");
#else
  std::array<cmsToneCurve*, 3> curves{tabulatedGamma24Curve(), tabulatedGamma24Curve(), tabulatedGamma24Curve()};
  const std::vector<uint8_t> bytes = matrixShaperProfile(
      xyY(0.3127, 0.329), {.Red = xyY(0.64, 0.33), .Green = xyY(0.30, 0.60), .Blue = xyY(0.15, 0.06)}, curves
  );
  for (cmsToneCurve* curve : curves) {
    cmsFreeToneCurve(curve);
  }
  CHECK(!bytes.empty());
  const umbriel::IccParse parsed = umbriel::parseIccProfile(bytes);
  CHECK(parsed.colorimetry.has_value());
  if (!parsed.colorimetry) {
    return;
  }
  const umbriel::PanelTransfer& transfer = parsed.colorimetry->transfer;
  CHECK(transfer.kind == umbriel::PanelTransfer::Kind::Curve);
  if (transfer.kind != umbriel::PanelTransfer::Kind::Curve) {
    return;
  }
  CHECK(transfer.encode.size() > 2);
  CHECK(closeTo(transfer.encode.front(), 0.0, 1e-3));
  CHECK(closeTo(transfer.encode.back(), 1.0, 1e-3));
  // The tabulated TRC is gamma 2.4 evaluated; the baked encode must invert it.
  CHECK(closeTo(umbriel::panelEncodeSample(transfer, 0.5F), std::pow(0.5, 1.0 / 2.4), 0.005));
#endif
}

UMBRIEL_TEST(iccLutProfilesAreRejected) {
#if !UMBRIEL_HAS_LCMS2
  std::println("skip: built without lcms2");
#else
  std::array<cmsToneCurve*, 3> curves{
      cmsBuildGamma(nullptr, 2.2), cmsBuildGamma(nullptr, 2.2), cmsBuildGamma(nullptr, 2.2)
  };
  const cmsCIExyY white = xyY(0.3127, 0.329);
  const cmsCIExyYTRIPLE primaries{
      .Red = xyY(0.64, 0.33),
      .Green = xyY(0.30, 0.60),
      .Blue = xyY(0.15, 0.06),
  };
  cmsHPROFILE profile = cmsCreateRGBProfileTHR(nullptr, &white, &primaries, curves.data());
  for (cmsToneCurve* curve : curves) {
    cmsFreeToneCurve(curve);
  }
  CHECK(profile != nullptr);
  if (profile == nullptr) {
    return;
  }
  // A presence-only probe: lcms2 refuses to serialize ad-hoc pipelines as
  // mAB/mBA, but the parser rejects on the tag's presence alone, so a raw
  // A2B0 tag is exactly what the rejection must key on.
  const std::array<uint8_t, 4> lutTag{0x6D, 0x66, 0x74, 0x32}; // 'mft2'
  CHECK(cmsWriteRawTag(profile, cmsSigAToB0Tag, lutTag.data(), static_cast<cmsUInt32Number>(lutTag.size())));
  const std::vector<uint8_t> bytes = saveProfile(profile);
  cmsCloseProfile(profile);

  const umbriel::IccParse parsed = umbriel::parseIccProfile(bytes);
  CHECK(!parsed.colorimetry.has_value());
  CHECK(parsed.error.contains("LUT"));
#endif
}

UMBRIEL_TEST(iccVcgtIsIgnoredOnMatrixShaperProfiles) {
#if !UMBRIEL_HAS_LCMS2
  std::println("skip: built without lcms2");
#else
  std::array<cmsToneCurve*, 3> curves{
      cmsBuildGamma(nullptr, 2.2), cmsBuildGamma(nullptr, 2.2), cmsBuildGamma(nullptr, 2.2)
  };
  const cmsCIExyY white = xyY(0.3127, 0.329);
  const cmsCIExyYTRIPLE primaries{
      .Red = xyY(0.64, 0.33),
      .Green = xyY(0.30, 0.60),
      .Blue = xyY(0.15, 0.06),
  };
  cmsHPROFILE profile = cmsCreateRGBProfileTHR(nullptr, &white, &primaries, curves.data());
  for (cmsToneCurve* curve : curves) {
    cmsFreeToneCurve(curve);
  }
  CHECK(profile != nullptr);
  if (profile == nullptr) {
    return;
  }
  // vcgt is a pre-dispatch gamma ramp, not content colorimetry: parse must warn and ignore it.
  const std::array<uint8_t, 4> ramp{0x00, 0x00, 0xFF, 0xFF};
  CHECK(cmsWriteRawTag(profile, cmsSigVcgtTag, ramp.data(), static_cast<cmsUInt32Number>(ramp.size())));
  const std::vector<uint8_t> bytes = saveProfile(profile);
  cmsCloseProfile(profile);

  const umbriel::IccParse parsed = umbriel::parseIccProfile(bytes);
  CHECK(parsed.colorimetry.has_value());
  CHECK(std::ranges::any_of(parsed.warnings, [](const std::string& warning) { return warning.contains("vcgt"); }));
#endif
}

UMBRIEL_TEST(iccVcgtOnlyProfilesAreRejected) {
#if !UMBRIEL_HAS_LCMS2
  std::println("skip: built without lcms2");
#else
  cmsHPROFILE profile = cmsCreateProfilePlaceholder(nullptr);
  CHECK(profile != nullptr);
  if (profile == nullptr) {
    return;
  }
  cmsSetDeviceClass(profile, cmsSigDisplayClass);
  cmsSetColorSpace(profile, cmsSigRgbData);
  cmsSetPCS(profile, cmsSigXYZData);
  const std::array<uint8_t, 4> ramp{0x00, 0x00, 0xFF, 0xFF};
  cmsWriteRawTag(profile, cmsSigVcgtTag, ramp.data(), static_cast<cmsUInt32Number>(ramp.size()));
  const std::vector<uint8_t> bytes = saveProfile(profile);
  cmsCloseProfile(profile);

  const umbriel::IccParse parsed = umbriel::parseIccProfile(bytes);
  CHECK(!parsed.colorimetry.has_value());
  CHECK(!parsed.error.empty());
#endif
}

UMBRIEL_TEST(iccTruncatedProfilesAreRejected) {
#if !UMBRIEL_HAS_LCMS2
  std::println("skip: built without lcms2");
#else
  std::array<cmsToneCurve*, 3> curves{
      cmsBuildGamma(nullptr, 2.2), cmsBuildGamma(nullptr, 2.2), cmsBuildGamma(nullptr, 2.2)
  };
  const std::vector<uint8_t> bytes = matrixShaperProfile(
      xyY(0.3127, 0.329), {.Red = xyY(0.64, 0.33), .Green = xyY(0.30, 0.60), .Blue = xyY(0.15, 0.06)}, curves
  );
  for (cmsToneCurve* curve : curves) {
    cmsFreeToneCurve(curve);
  }
  CHECK(!bytes.empty());
  const std::vector<uint8_t> truncated(bytes.begin(), bytes.begin() + static_cast<std::ptrdiff_t>(bytes.size() / 2));
  CHECK(!umbriel::parseIccProfile(truncated).colorimetry.has_value());
  CHECK(!umbriel::parseIccProfile({}).colorimetry.has_value());
#endif
}

UMBRIEL_TEST(iccStoreForFileProfileKeepsExactBytes) {
  // The store is the file as written on disk, never a reserialization of what
  // the parser understood: odd padding and trailing garbage survive verbatim.
  const std::vector<uint8_t> bytes{0x00, 0x11, 0x22, 0x33, 0xFF, 0x00, 0x7F, 0x42};
  const umbriel::IccProfileStore store = umbriel::iccStoreForFileProfile(bytes);
  CHECK(store != nullptr);
  if (store == nullptr) {
    return;
  }
  CHECK(*store == bytes);
  CHECK(umbriel::iccStoreForFileProfile({}) == nullptr);
}

UMBRIEL_TEST(inertCharacterizationStoresNoIccProfile) {
  CHECK(umbriel::iccStoreForPanel(nullptr) == nullptr);
#if !UMBRIEL_HAS_LCMS2
  // EDID-without-lcms2 cannot synthesize a profile and stores nothing.
  const umbriel::PanelColorimetry panel{
      .primaries = displayP3Primaries(),
      .white = {0.3127F, 0.329F},
      .transfer = {.kind = umbriel::PanelTransfer::Kind::Gamma22, .encode = {}},
  };
  CHECK(umbriel::iccStoreForPanel(&panel) == nullptr);
#endif
}

UMBRIEL_TEST(synthesizedEdidProfileRoundTripsThroughTheIccParser) {
#if !UMBRIEL_HAS_LCMS2
  std::println("skip: built without lcms2");
#else
  // The advertised bytes must describe the same panel the parser recovered
  // from the EDID: feed the synthesis back through the wave-1 parser.
  const auto edid = edidWithD65AndGamma22();
  const wlr_color_primaries defaults = displayP3Primaries();
  const std::optional<umbriel::PanelColorimetry> source = umbriel::panelColorimetryFromEdid(edid, &defaults);
  CHECK(source.has_value());
  if (!source) {
    return;
  }
  const umbriel::IccProfileStore store = umbriel::iccStoreForPanel(&*source);
  CHECK(store != nullptr);
  if (store == nullptr || store->empty()) {
    return;
  }
  const umbriel::IccParse parsed = umbriel::parseIccProfile(*store);
  CHECK(parsed.error.empty());
  CHECK(parsed.colorimetry.has_value());
  if (!parsed.colorimetry) {
    return;
  }
  const umbriel::PanelColorimetry& recovered = *parsed.colorimetry;
  CHECK(closeTo(recovered.primaries.red.x, source->primaries.red.x, 0.005));
  CHECK(closeTo(recovered.primaries.red.y, source->primaries.red.y, 0.005));
  CHECK(closeTo(recovered.primaries.green.x, source->primaries.green.x, 0.005));
  CHECK(closeTo(recovered.primaries.green.y, source->primaries.green.y, 0.005));
  CHECK(closeTo(recovered.primaries.blue.x, source->primaries.blue.x, 0.005));
  CHECK(closeTo(recovered.primaries.blue.y, source->primaries.blue.y, 0.005));
  CHECK(closeTo(recovered.white[0], source->white[0], 0.005));
  CHECK(closeTo(recovered.white[1], source->white[1], 0.005));
  CHECK(recovered.transfer.kind == source->transfer.kind);
#endif
}

UMBRIEL_TEST(synthesizedCurveTrcRoundTripsThroughTheIccParser) {
#if !UMBRIEL_HAS_LCMS2
  std::println("skip: built without lcms2");
#else
  // Gamma 2.4 is not a named fast path: the synthesized profile must carry the
  // sampled decode curve so the parser bakes the same encode back.
  umbriel::PanelColorimetry source{
      .primaries = bt2020Primaries(),
      .white = {0.3127F, 0.329F},
      .transfer = {.kind = umbriel::PanelTransfer::Kind::Curve, .encode = {}},
  };
  source.transfer.encode.resize(1024);
  for (size_t index = 0; index < source.transfer.encode.size(); ++index) {
    const float linear = static_cast<float>(index) / static_cast<float>(source.transfer.encode.size() - 1);
    source.transfer.encode[index] = std::pow(linear, 1.0F / 2.4F);
  }
  const umbriel::IccProfileStore store = umbriel::iccStoreForPanel(&source);
  CHECK(store != nullptr);
  if (store == nullptr || store->empty()) {
    return;
  }
  const umbriel::IccParse parsed = umbriel::parseIccProfile(*store);
  CHECK(parsed.error.empty());
  CHECK(parsed.colorimetry.has_value());
  if (!parsed.colorimetry) {
    return;
  }
  const umbriel::PanelColorimetry& recovered = *parsed.colorimetry;
  CHECK(closeTo(recovered.primaries.red.x, source.primaries.red.x, 0.005));
  CHECK(closeTo(recovered.primaries.green.y, source.primaries.green.y, 0.005));
  CHECK(recovered.transfer.kind == umbriel::PanelTransfer::Kind::Curve);
  if (recovered.transfer.kind != umbriel::PanelTransfer::Kind::Curve) {
    return;
  }
  for (const float at : {0.25F, 0.5F, 0.75F}) {
    CHECK(closeTo(
        umbriel::panelEncodeSample(recovered.transfer, at), umbriel::panelEncodeSample(source.transfer, at), 0.01
    ));
  }
#endif
}

UMBRIEL_TEST(fitTransferFitsNamedFastPathsAndPowerCurves) {
  // Exact named shapes stay named; only genuinely non-representable TRCs fall
  // back to the parametric power fit (fitTransfer's approximation contract).
  auto samples = [](auto encode) {
    constexpr size_t size = 256;
    std::vector<float> values(size);
    for (size_t index = 0; index < size; ++index) {
      values[index] = encode(static_cast<float>(index) / static_cast<float>(size - 1));
    }
    return values;
  };
  auto srgbEncode = [](float linear) {
    return linear >= 1.0F ? 1.0F
                          : (linear <= 0.0031308F ? 12.92F * linear : 1.055F * std::pow(linear, 1.0F / 2.4F) - 0.055F);
  };

  CHECK(
      umbriel::fitTransfer({.kind = umbriel::PanelTransfer::Kind::Srgb, .encode = {}}).kind
      == umbriel::TransferFit::Kind::Srgb
  );
  CHECK(
      umbriel::fitTransfer({.kind = umbriel::PanelTransfer::Kind::Gamma22, .encode = {}}).kind
      == umbriel::TransferFit::Kind::Gamma22
  );

  // Sampled curves re-detect the named shapes before fitting anything.
  const umbriel::TransferFit sampledSrgb =
      umbriel::fitTransfer({.kind = umbriel::PanelTransfer::Kind::Curve, .encode = samples(srgbEncode)});
  CHECK(sampledSrgb.kind == umbriel::TransferFit::Kind::Srgb);
  const umbriel::TransferFit sampledGamma22 = umbriel::fitTransfer(
      {.kind = umbriel::PanelTransfer::Kind::Curve, .encode = samples([](float x) { return std::pow(x, 1.0F / 2.2F); })}
  );
  CHECK(sampledGamma22.kind == umbriel::TransferFit::Kind::Gamma22);

  // Odd curves fit to their power exponent within tolerance.
  for (const float exponent : {1.8F, 2.4F, 2.8F}) {
    const umbriel::TransferFit fit =
        umbriel::fitTransfer({.kind = umbriel::PanelTransfer::Kind::Curve, .encode = samples([exponent](float x) {
                                                                             return std::pow(x, 1.0F / exponent);
                                                                           })});
    CHECK(fit.kind == umbriel::TransferFit::Kind::Power);
    CHECK(closeTo(fit.exponent, exponent, 0.01));
  }

  // An empty sampled table is the identity encode, i.e. linear.
  const umbriel::TransferFit linear = umbriel::fitTransfer({.kind = umbriel::PanelTransfer::Kind::Curve, .encode = {}});
  CHECK(linear.kind == umbriel::TransferFit::Kind::Power);
  CHECK(closeTo(linear.exponent, 1.0));
}

UMBRIEL_TEST(iccClassScopeAdmitsColorSpaceProfilesForClientIcc) {
#if !UMBRIEL_HAS_LCMS2
  std::println("skip: built without lcms2");
#else
  // set_icc_file admits Display *and* ColorSpace class profiles; output
  // characterization keeps its display-only vocabulary.
  std::array<cmsToneCurve*, 3> curves{
      cmsBuildGamma(nullptr, 2.2), cmsBuildGamma(nullptr, 2.2), cmsBuildGamma(nullptr, 2.2)
  };
  std::vector<uint8_t> bytes = matrixShaperProfile(
      xyY(0.3127, 0.329), {.Red = xyY(0.64, 0.33), .Green = xyY(0.30, 0.60), .Blue = xyY(0.15, 0.06)}, curves
  );
  for (cmsToneCurve* curve : curves) {
    cmsFreeToneCurve(curve);
  }
  CHECK(!bytes.empty());
  // Header bytes 12-15 carry the ICC device class signature.
  const auto setClass = [&bytes](char first, char second, char third, char fourth) {
    bytes[12] = static_cast<uint8_t>(first);
    bytes[13] = static_cast<uint8_t>(second);
    bytes[14] = static_cast<uint8_t>(third);
    bytes[15] = static_cast<uint8_t>(fourth);
  };

  setClass('s', 'p', 'a', 'c'); // ColorSpace class
  CHECK(!umbriel::parseIccProfile(bytes).colorimetry.has_value());
  CHECK(umbriel::parseIccProfile(bytes, umbriel::IccClassScope::DisplayOrColorSpace).colorimetry.has_value());

  setClass('p', 'r', 't', 'r'); // Printer class: out of scope everywhere
  CHECK(!umbriel::parseIccProfile(bytes).colorimetry.has_value());
  CHECK(!umbriel::parseIccProfile(bytes, umbriel::IccClassScope::DisplayOrColorSpace).colorimetry.has_value());
#endif
}

int main() { return RUN_TESTS(); }
