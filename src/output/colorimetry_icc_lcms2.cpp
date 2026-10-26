// ICC matrix-shaper parsing via lcms2 (umbriel#574). Compiled only when the
// build finds lcms2; colorimetry_icc_fallback.cpp is its inert counterpart.

#include "output/colorimetry.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <lcms2.h>
#include <limits>
#include <memory>
#include <span>
#include <string>
#include <vector>

namespace umbriel {

  namespace {

    // Forward-curve resolution for named-curve detection and encode inversion.
    constexpr size_t kCurveSamples = 256;
    // Named fast paths compare the evaluated curve; anything looser is baked.
    constexpr float kCurveMatchTolerance = 1e-3F;

    struct ProfileCloser {
      void operator()(void* profile) const {
        if (profile != nullptr) {
          cmsCloseProfile(profile);
        }
      }
    };
    using ProfilePtr = std::unique_ptr<void, ProfileCloser>;

    float srgbDecodeSample(float encoded) {
      return encoded <= 0.04045F ? encoded / 12.92F : std::pow((encoded + 0.055F) / 1.055F, 2.4F);
    }

    std::vector<float> evaluateCurve(const cmsToneCurve* curve) {
      std::vector<float> samples(kCurveSamples);
      for (size_t index = 0; index < kCurveSamples; ++index) {
        const float encoded = static_cast<float>(index) / static_cast<float>(kCurveSamples - 1);
        samples[index] = cmsEvalToneCurveFloat(curve, encoded);
      }
      return samples;
    }

    bool matchesDecode(const std::vector<float>& samples, float (*decode)(float)) {
      for (size_t index = 0; index < samples.size(); ++index) {
        const float encoded = static_cast<float>(index) / static_cast<float>(samples.size() - 1);
        if (std::abs(samples[index] - decode(encoded)) > kCurveMatchTolerance) {
          return false;
        }
      }
      return true;
    }

    bool sameCurve(const std::vector<float>& first, const std::vector<float>& second) {
      for (size_t index = 0; index < first.size(); ++index) {
        if (std::abs(first[index] - second[index]) > kCurveMatchTolerance) {
          return false;
        }
      }
      return true;
    }

    // Numeric inversion of the evaluated decode curve (encoded -> linear) into
    // the panel encode curve (linear -> encoded). The forward curve is sampled
    // monotonically and inverted by binary search + interpolation: an
    // estimation, accurate to the sampling resolution, and deliberately not a
    // gamma fit of parametric curves (KWin's iccprofile.cpp documents the same
    // pitfall in reverse).
    std::vector<float> invertDecodeCurve(const std::vector<float>& decode) {
      std::vector<float> encode(kCurveSamples);
      for (size_t target = 0; target < kCurveSamples; ++target) {
        const float linear = static_cast<float>(target) / static_cast<float>(kCurveSamples - 1);
        const auto upper = std::ranges::lower_bound(decode, linear);
        if (upper == decode.begin()) {
          encode[target] = 0.0F;
          continue;
        }
        if (upper == decode.end()) {
          encode[target] = 1.0F;
          continue;
        }
        const size_t high = static_cast<size_t>(upper - decode.begin());
        const size_t low = high - 1;
        const float span = decode[high] - decode[low];
        const float fraction = span > 0.0F ? (linear - decode[low]) / span : 0.0F;
        const float encoded = (static_cast<float>(low) + fraction) / static_cast<float>(decode.size() - 1);
        encode[target] = std::clamp(encoded, 0.0F, 1.0F);
      }
      return encode;
    }

    bool invert3x3(const double in[9], double out[9]) {
      const double determinant = in[0] * (in[4] * in[8] - in[5] * in[7])
          - in[1] * (in[3] * in[8] - in[5] * in[6])
          + in[2] * (in[3] * in[7] - in[4] * in[6]);
      if (!std::isfinite(determinant) || std::abs(determinant) < 1e-12) {
        return false;
      }
      out[0] = (in[4] * in[8] - in[5] * in[7]) / determinant;
      out[1] = (in[2] * in[7] - in[1] * in[8]) / determinant;
      out[2] = (in[1] * in[5] - in[2] * in[4]) / determinant;
      out[3] = (in[5] * in[6] - in[3] * in[8]) / determinant;
      out[4] = (in[0] * in[8] - in[2] * in[6]) / determinant;
      out[5] = (in[2] * in[3] - in[0] * in[5]) / determinant;
      out[6] = (in[3] * in[7] - in[4] * in[6]) / determinant;
      out[7] = (in[1] * in[6] - in[0] * in[7]) / determinant;
      out[8] = (in[0] * in[4] - in[1] * in[3]) / determinant;
      return true;
    }

    void multiplyMatrixVector(const double matrix[9], const cmsCIEXYZ& in, double out[3]) {
      out[0] = matrix[0] * in.X + matrix[1] * in.Y + matrix[2] * in.Z;
      out[1] = matrix[3] * in.X + matrix[4] * in.Y + matrix[5] * in.Z;
      out[2] = matrix[6] * in.X + matrix[7] * in.Y + matrix[8] * in.Z;
    }

    // Recover the measured colorimetry: the ICC tags are relative to the D50
    // PCS, and chad records the adaptation that was applied on the way there.
    // Undoing it maps colorants and white point back to the real white.
    cmsCIEXYZ unAdapt(const double chadInverse[9], const cmsCIEXYZ& tagged) {
      double xyz[3];
      multiplyMatrixVector(chadInverse, tagged, xyz);
      return {.X = xyz[0], .Y = xyz[1], .Z = xyz[2]};
    }

    wlr_color_cie1931_xy xyFromXyz(const cmsCIEXYZ& xyz) {
      const double sum = xyz.X + xyz.Y + xyz.Z;
      if (!std::isfinite(sum) || std::abs(sum) < 1e-9) {
        return {.x = 0.0F, .y = 0.0F};
      }
      return {
          .x = static_cast<float>(xyz.X / sum),
          .y = static_cast<float>(xyz.Y / sum),
      };
    }

    // Synthesis (wave 5): the ICC TRC tags carry the decode curve (encoded ->
    // linear), while a PanelTransfer carries the encode curve, so sampled
    // kinds are inverted numerically here and the parser inverts back on read.
    std::vector<float> decodeFromEncode(const PanelTransfer& transfer) {
      std::vector<float> decode(kCurveSamples);
      for (size_t index = 0; index < kCurveSamples; ++index) {
        const float encoded = static_cast<float>(index) / static_cast<float>(kCurveSamples - 1);
        float low = 0.0F;
        float high = 1.0F;
        for (int step = 0; step < 24; ++step) {
          const float middle = (low + high) * 0.5F;
          if (panelEncodeSample(transfer, middle) < encoded) {
            low = middle;
          } else {
            high = middle;
          }
        }
        decode[index] = (low + high) * 0.5F;
      }
      return decode;
    }

    cmsToneCurve* decodeCurve(const PanelTransfer& transfer) {
      switch (transfer.kind) {
      case PanelTransfer::Kind::Srgb: {
        // lcms2 parametric type 4 = ICC parametricCurveType format 3 (the sRGB
        // EOTF): Y = (aX + b)^g above d, else cX.
        const cmsFloat64Number params[5] = {2.4, 1.0 / 1.055, 0.055 / 1.055, 1.0 / 12.92, 0.04045};
        return cmsBuildParametricToneCurve(nullptr, 4, params);
      }
      case PanelTransfer::Kind::Gamma22:
        return cmsBuildGamma(nullptr, 2.2);
      case PanelTransfer::Kind::Curve:
        break;
      }
      const std::vector<float> decode = decodeFromEncode(transfer);
      std::vector<uint16_t> samples(decode.size());
      for (size_t index = 0; index < decode.size(); ++index) {
        samples[index] = static_cast<uint16_t>(std::lround(std::clamp(decode[index], 0.0F, 1.0F) * 65535.0F));
      }
      return cmsBuildTabulatedToneCurve16(nullptr, static_cast<cmsUInt32Number>(samples.size()), samples.data());
    }

  } // namespace

  IccParse parseIccProfile(std::span<const uint8_t> data, IccClassScope scope) {
    IccParse result;
    if (data.empty()) {
      result.error = "empty profile data";
      return result;
    }
    if (data.size() > static_cast<size_t>(std::numeric_limits<cmsUInt32Number>::max())) {
      result.error = "profile is too large";
      return result;
    }
    ProfilePtr profile(cmsOpenProfileFromMem(data.data(), static_cast<cmsUInt32Number>(data.size())));
    if (!profile) {
      result.error = "not a readable ICC profile";
      return result;
    }
    const cmsProfileClassSignature deviceClass = cmsGetDeviceClass(profile.get());
    const bool classInScope = deviceClass == cmsSigDisplayClass
        || (scope == IccClassScope::DisplayOrColorSpace && deviceClass == cmsSigColorSpaceClass);
    if (!classInScope) {
      result.error = scope == IccClassScope::DisplayOrColorSpace ? "not an ICC display or color space profile"
                                                                 : "not an ICC display profile";
      return result;
    }
    if (cmsGetColorSpace(profile.get()) != cmsSigRgbData) {
      result.error = "not a 3-channel RGB profile";
      return result;
    }
    if (cmsIsTag(profile.get(), cmsSigAToB0Tag)
        || cmsIsTag(profile.get(), cmsSigAToB1Tag)
        || cmsIsTag(profile.get(), cmsSigAToB2Tag)
        || cmsIsTag(profile.get(), cmsSigBToA0Tag)
        || cmsIsTag(profile.get(), cmsSigBToA1Tag)
        || cmsIsTag(profile.get(), cmsSigBToA2Tag)) {
      result.error = "LUT-based profiles (A2B0/B2A0) are unsupported; only matrix-shaper profiles are";
      return result;
    }
    if (cmsIsTag(profile.get(), cmsSigVcgtTag)) {
      result.warnings.push_back("ignoring vcgt tag (a pre-dispatch gamma ramp, not content colorimetry)");
    }

    const auto* red = static_cast<const cmsCIEXYZ*>(cmsReadTag(profile.get(), cmsSigRedColorantTag));
    const auto* green = static_cast<const cmsCIEXYZ*>(cmsReadTag(profile.get(), cmsSigGreenColorantTag));
    const auto* blue = static_cast<const cmsCIEXYZ*>(cmsReadTag(profile.get(), cmsSigBlueColorantTag));
    const auto* whitePoint = static_cast<const cmsCIEXYZ*>(cmsReadTag(profile.get(), cmsSigMediaWhitePointTag));
    if (red == nullptr || green == nullptr || blue == nullptr) {
      result.error = "not a matrix-shaper profile (rXYZ/gXYZ/bXYZ colorants missing)";
      return result;
    }
    if (whitePoint == nullptr) {
      result.error = "not a matrix-shaper profile (media white point missing)";
      return result;
    }

    // chad is an s15Fixed16 3x3 that lcms2 hands back as 9 doubles (validated
    // by the chad round-trip unit).
    double chadInverse[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    if (const auto* chad = static_cast<const double*>(cmsReadTag(profile.get(), cmsSigChromaticAdaptationTag))) {
      double chadMatrix[9];
      std::copy_n(chad, 9, chadMatrix);
      if (!invert3x3(chadMatrix, chadInverse)) {
        result.warnings.push_back("ignoring a singular chad tag");
        std::fill_n(chadInverse, 9, 0.0);
        chadInverse[0] = chadInverse[4] = chadInverse[8] = 1.0;
      }
    }

    const cmsCIEXYZ realRed = unAdapt(chadInverse, *red);
    const cmsCIEXYZ realGreen = unAdapt(chadInverse, *green);
    const cmsCIEXYZ realBlue = unAdapt(chadInverse, *blue);
    const cmsCIEXYZ realWhite = unAdapt(chadInverse, *whitePoint);

    PanelColorimetry panel{
        .primaries =
            {
                .red = xyFromXyz(realRed),
                .green = xyFromXyz(realGreen),
                .blue = xyFromXyz(realBlue),
                .white = xyFromXyz(realWhite),
            },
        .white = {0.0F, 0.0F},
        .transfer = {},
    };
    panel.white[0] = panel.primaries.white.x;
    panel.white[1] = panel.primaries.white.y;

    const auto* redTrc = static_cast<const cmsToneCurve*>(cmsReadTag(profile.get(), cmsSigRedTRCTag));
    const auto* greenTrc = static_cast<const cmsToneCurve*>(cmsReadTag(profile.get(), cmsSigGreenTRCTag));
    const auto* blueTrc = static_cast<const cmsToneCurve*>(cmsReadTag(profile.get(), cmsSigBlueTRCTag));
    if (redTrc == nullptr || greenTrc == nullptr || blueTrc == nullptr) {
      result.error = "not a matrix-shaper profile (rTRC/gTRC/bTRC missing)";
      return result;
    }

    const std::vector<float> redDecode = evaluateCurve(redTrc);
    if (!sameCurve(redDecode, evaluateCurve(greenTrc)) || !sameCurve(redDecode, evaluateCurve(blueTrc))) {
      result.warnings.push_back("per-channel TRCs differ; using the red channel curve");
    }

    if (matchesDecode(redDecode, srgbDecodeSample)) {
      panel.transfer.kind = PanelTransfer::Kind::Srgb;
    } else if (matchesDecode(redDecode, [](float encoded) { return std::pow(encoded, 2.2F); })) {
      panel.transfer.kind = PanelTransfer::Kind::Gamma22;
    } else {
      panel.transfer.kind = PanelTransfer::Kind::Curve;
      panel.transfer.encode = invertDecodeCurve(redDecode);
    }

    result.colorimetry = std::move(panel);
    return result;
  }

  IccProfileStore iccStoreForPanel(const PanelColorimetry* panel) {
    if (panel == nullptr) {
      return {};
    }
    // A matrix-shaper display profile carrying the panel's colorants, white
    // point and TRC. lcms2 adapts to the D50 PCS and records chad on the way;
    // the parser undoes that adaptation on read (pinned by
    // iccChadTagRecoversMeasuredWhiteAndColorants).
    const cmsCIExyY white = {.x = panel->white[0], .y = panel->white[1], .Y = 1.0};
    const cmsCIExyYTRIPLE primaries{
        .Red = {.x = panel->primaries.red.x, .y = panel->primaries.red.y, .Y = 1.0},
        .Green = {.x = panel->primaries.green.x, .y = panel->primaries.green.y, .Y = 1.0},
        .Blue = {.x = panel->primaries.blue.x, .y = panel->primaries.blue.y, .Y = 1.0},
    };
    cmsToneCurve* curves[3]{decodeCurve(panel->transfer), decodeCurve(panel->transfer), decodeCurve(panel->transfer)};
    if (curves[0] == nullptr || curves[1] == nullptr || curves[2] == nullptr) {
      for (cmsToneCurve* curve : curves) {
        if (curve != nullptr) {
          cmsFreeToneCurve(curve);
        }
      }
      return {};
    }
    cmsHPROFILE profile = cmsCreateRGBProfileTHR(nullptr, &white, &primaries, curves);
    for (cmsToneCurve* curve : curves) {
      cmsFreeToneCurve(curve);
    }
    if (profile == nullptr) {
      return {};
    }
    cmsUInt32Number size = 0;
    if (!cmsSaveProfileToMem(profile, nullptr, &size) || size == 0) {
      cmsCloseProfile(profile);
      return {};
    }
    auto bytes = std::make_shared<std::vector<uint8_t>>(size);
    if (!cmsSaveProfileToMem(profile, bytes->data(), &size)) {
      cmsCloseProfile(profile);
      return {};
    }
    bytes->resize(size);
    cmsCloseProfile(profile);
    return bytes;
  }

} // namespace umbriel
