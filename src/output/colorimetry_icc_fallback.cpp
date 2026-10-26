// Inert ICC parsing for builds without lcms2 (umbriel#574). Same shape as
// umbrielfx/render/color_fallback.c: the ICC path reports itself unsupported
// and `color_profile = "<path>"` warns and falls back at apply time.

#include "output/colorimetry.h"

#include <span>

namespace umbriel {

  IccParse parseIccProfile(std::span<const uint8_t>, IccClassScope) {
    return {.colorimetry = std::nullopt, .error = "ICC profiles are unsupported (built without lcms2)", .warnings = {}};
  }

  IccProfileStore iccStoreForPanel(const PanelColorimetry*) {
    // No synthesis without lcms2: an EDID characterization advertises nothing.
    return {};
  }

} // namespace umbriel
