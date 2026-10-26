#include "output/colorimetry.h"

#include "output/hdr_metadata.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>

extern "C" {
#include <libdisplay-info/edid.h>
#include <libdisplay-info/info.h>
}

namespace umbriel {

  namespace {

    // Encode-curve resolution for PanelTransfer::Kind::Curve and LUT baking.
    constexpr size_t kCurveSamples = 256;
    constexpr size_t kEncodeLutDim = 1024;

    float srgbEncode(float linear) {
      // Exact endpoints keep baked LUT ramps anchored at 0 and 65535.
      if (linear >= 1.0F) {
        return 1.0F;
      }
      return linear <= 0.0031308F ? 12.92F * linear : 1.055F * std::pow(linear, 1.0F / 2.4F) - 0.055F;
    }

    float clampedUnit(float value) { return std::clamp(value, 0.0F, 1.0F); }

    wlr_color_cie1931_xy lerpXy(const wlr_color_cie1931_xy& from, const wlr_color_cie1931_xy& to, float amount) {
      return {
          .x = from.x + (to.x - from.x) * amount,
          .y = from.y + (to.y - from.y) * amount,
      };
    }

    std::vector<float> samplesFromEncode(float (*encode)(float, float), float shape) {
      std::vector<float> samples(kCurveSamples);
      for (size_t index = 0; index < kCurveSamples; ++index) {
        const float linear = static_cast<float>(index) / static_cast<float>(kCurveSamples - 1);
        samples[index] = encode(linear, shape);
      }
      return samples;
    }

    void identityMatrix(float matrix[9]) {
      constexpr float identity[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
      std::copy(identity + 0, identity + 9, matrix);
    }

  } // namespace

  void ColorTransformDeleter::operator()(wlr_color_transform* transform) const { wlr_color_transform_unref(transform); }

  float panelEncodeSample(const PanelTransfer& transfer, float linear) {
    const float x = clampedUnit(linear);
    switch (transfer.kind) {
    case PanelTransfer::Kind::Srgb:
      return srgbEncode(x);
    case PanelTransfer::Kind::Gamma22:
      return std::pow(x, 1.0F / 2.2F);
    case PanelTransfer::Kind::Curve:
      break;
    }
    if (transfer.encode.empty()) {
      return x;
    }
    const float position = x * static_cast<float>(transfer.encode.size() - 1);
    const size_t lower = static_cast<size_t>(position);
    const size_t upper = std::min(lower + 1, transfer.encode.size() - 1);
    const float fraction = position - static_cast<float>(lower);
    return transfer.encode[lower] + (transfer.encode[upper] - transfer.encode[lower]) * fraction;
  }

  std::vector<uint16_t> bakeEncodeLut(const PanelTransfer& transfer, size_t dim) {
    std::vector<uint16_t> lut(std::max<size_t>(dim, 2));
    for (size_t index = 0; index < lut.size(); ++index) {
      const float linear = static_cast<float>(index) / static_cast<float>(lut.size() - 1);
      const float encoded = std::clamp(panelEncodeSample(transfer, linear), 0.0F, 1.0F);
      lut[index] = static_cast<uint16_t>(std::lround(encoded * 65535.0F));
    }
    return lut;
  }

  TransferFit fitTransfer(const PanelTransfer& transfer) {
    switch (transfer.kind) {
    case PanelTransfer::Kind::Srgb:
      return {.kind = TransferFit::Kind::Srgb};
    case PanelTransfer::Kind::Gamma22:
      return {.kind = TransferFit::Kind::Gamma22};
    case PanelTransfer::Kind::Curve:
      break;
    }
    if (transfer.encode.size() < 2) {
      // An empty sampled table is the identity encode, i.e. a linear EOTF.
      return {.kind = TransferFit::Kind::Power, .exponent = 1.0F};
    }
    // Named fast paths first: an exact match is reported as the named curve,
    // never as an approximating power fit. The power fit is log-log
    // least squares through the origin for encode(x) = x^(1/e), i.e.
    // log(encode) = (1/e) * log(x); endpoints are skipped because log(0).
    constexpr float kMatchTolerance = 1e-3F;
    bool matchesSrgb = true;
    bool matchesGamma22 = true;
    double sumXX = 0.0;
    double sumXY = 0.0;
    for (size_t index = 1; index < transfer.encode.size(); ++index) {
      const float linear = static_cast<float>(index) / static_cast<float>(transfer.encode.size() - 1);
      const float encoded = transfer.encode[index];
      if (std::abs(encoded - srgbEncode(linear)) > kMatchTolerance) {
        matchesSrgb = false;
      }
      if (std::abs(encoded - std::pow(linear, 1.0F / 2.2F)) > kMatchTolerance) {
        matchesGamma22 = false;
      }
      if (encoded > 0.0F) {
        const double logLinear = std::log(static_cast<double>(linear));
        const double logEncoded = std::log(static_cast<double>(encoded));
        sumXX += logLinear * logLinear;
        sumXY += logLinear * logEncoded;
      }
    }
    if (matchesSrgb) {
      return {.kind = TransferFit::Kind::Srgb};
    }
    if (matchesGamma22) {
      return {.kind = TransferFit::Kind::Gamma22};
    }
    // A degenerate table has no exponent to fit; linear is the least wrong
    // declared shape and keeps the reported tf_power value meaningful.
    const float slope = sumXX > 0.0 ? static_cast<float>(sumXY / sumXX) : 0.0F;
    const float exponent = slope > 0.0F && std::isfinite(slope) ? 1.0F / slope : 1.0F;
    return {.kind = TransferFit::Kind::Power, .exponent = exponent};
  }

  void sdrGamutMatrix(const wlr_color_primaries& panel, float wideness, float matrix[9]) {
    wlr_color_primaries srgb{};
    wlr_color_primaries_from_named(&srgb, WLR_COLOR_NAMED_PRIMARIES_SRGB);
    const float amount = std::clamp(wideness, 0.0F, 1.0F);
    if (amount <= 0.0F) {
      // Strict sRGB interpretation: the plain sRGB -> panel mapping.
      wlr_color_primaries_transform_absolute_colorimetric(&srgb, &panel, matrix);
      return;
    }
    if (amount >= 1.0F) {
      // Native: content is already in the panel's gamut, so the mapping is the
      // identity and only the panel TRC would remain (the runtime stages
      // nothing at all instead, see sdrGamutStaged).
      identityMatrix(matrix);
      return;
    }
    // Linear interpolation between the two gamuts (KWin's wideness semantics):
    // the primaries slide while the white stays fixed.
    const wlr_color_primaries interp{
        .red = lerpXy(srgb.red, panel.red, amount),
        .green = lerpXy(srgb.green, panel.green, amount),
        .blue = lerpXy(srgb.blue, panel.blue, amount),
        .white = srgb.white,
    };
    wlr_color_primaries_transform_absolute_colorimetric(&interp, &panel, matrix);
  }

  wlr_color_transform* buildSdrGamutTransform(const PanelColorimetry& panel) {
    float matrix[9];
    sdrGamutMatrix(panel.primaries, 0.0F, matrix);
    wlr_color_transform* matrixStage = wlr_color_transform_init_matrix(matrix);
    if (matrixStage == nullptr) {
      return nullptr;
    }

    wlr_color_transform* encodeStage = nullptr;
    switch (panel.transfer.kind) {
    case PanelTransfer::Kind::Srgb:
      encodeStage = wlr_color_transform_init_linear_to_inverse_eotf(WLR_COLOR_TRANSFER_FUNCTION_SRGB);
      break;
    case PanelTransfer::Kind::Gamma22:
      encodeStage = wlr_color_transform_init_linear_to_inverse_eotf(WLR_COLOR_TRANSFER_FUNCTION_GAMMA22);
      break;
    case PanelTransfer::Kind::Curve: {
      const std::vector<uint16_t> lut = bakeEncodeLut(panel.transfer, kEncodeLutDim);
      encodeStage = wlr_color_transform_init_lut_3x1d(lut.size(), lut.data(), lut.data(), lut.data());
      break;
    }
    }
    if (encodeStage == nullptr) {
      wlr_color_transform_unref(matrixStage);
      return nullptr;
    }

    wlr_color_transform* stages[2] = {matrixStage, encodeStage};
    wlr_color_transform* pipeline = wlr_color_transform_init_pipeline(stages, 2);
    wlr_color_transform_unref(matrixStage);
    wlr_color_transform_unref(encodeStage);
    return pipeline;
  }

  IccProfileStore iccStoreForFileProfile(std::span<const uint8_t> fileBytes) {
    if (fileBytes.empty()) {
      return {};
    }
    // The store is the file exactly as read: get_information advertises the
    // profile the user configured, quirks and all.
    return std::make_shared<const std::vector<uint8_t>>(fileBytes.begin(), fileBytes.end());
  }

  std::optional<PanelColorimetry>
  panelColorimetryFromEdid(std::span<const uint8_t> edid, const wlr_color_primaries* defaultPrimaries) {
    if (edid.empty() || defaultPrimaries == nullptr || !validDisplayPrimaries(*defaultPrimaries)) {
      return std::nullopt;
    }
    std::unique_ptr<di_info, decltype(&di_info_destroy)> info(
        di_info_parse_edid(edid.data(), edid.size()), di_info_destroy
    );
    if (!info) {
      return std::nullopt;
    }
    const di_edid* parsed = di_info_get_edid(info.get());
    if (parsed == nullptr) {
      return std::nullopt;
    }

    PanelColorimetry panel{
        .primaries = *defaultPrimaries,
        .white = {defaultPrimaries->white.x, defaultPrimaries->white.y},
        .transfer = {},
    };
    if (const di_edid_chromaticity_coords* coords = di_edid_get_chromaticity_coords(parsed); coords != nullptr
        && std::isfinite(coords->white_x)
        && std::isfinite(coords->white_y)
        && coords->white_x > 0.0F
        && coords->white_y > 0.0F
        && coords->white_x + coords->white_y <= 1.0F) {
      panel.white[0] = coords->white_x;
      panel.white[1] = coords->white_y;
    }
    panel.primaries.white = {.x = panel.white[0], .y = panel.white[1]};

    // EDID gamma is the decode exponent; its inverse is the panel encode.
    // Unknown/implausible values fall back to the common 2.2 convention.
    const float gamma = di_edid_get_basic_gamma(parsed);
    if (std::isfinite(gamma) && std::abs(gamma - 2.2F) <= 0.01F) {
      panel.transfer.kind = PanelTransfer::Kind::Gamma22;
    } else if (std::isfinite(gamma) && gamma >= 1.0F && gamma <= 4.0F) {
      panel.transfer.kind = PanelTransfer::Kind::Curve;
      panel.transfer.encode =
          samplesFromEncode([](float linear, float shape) { return std::pow(linear, 1.0F / shape); }, gamma);
    } else {
      panel.transfer.kind = PanelTransfer::Kind::Gamma22;
    }
    return panel;
  }

} // namespace umbriel
