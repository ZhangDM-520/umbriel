#pragma once

extern "C" {
#include <wlr/util/box.h>
}

#include <cstdint>

namespace umbriel {
  // Which box edge the pointer is holding, and how far that edge is from the pointer. A resize grab owns one or two
  // edges; comparing the wrong one reports the window's size as lag, so the arithmetic lives here where a test can pin
  // it. All values are logical layout coordinates.
  struct ResizeEdgeLag {
    // Distance from the pointer to the grabbed edge along each axis. Zero for an axis no grabbed edge belongs to.
    double dx = 0;
    double dy = 0;
    // The larger of the two, which is the figure a check bounds.
    double magnitude() const;
  };

  // `edges` is a WLR_EDGE_* mask. `box` is the drawn box, so the result is the lag the eye sees rather than the lag
  // between the pointer and a request the compositor has not drawn yet.
  ResizeEdgeLag resizeEdgeLag(uint32_t edges, double pointerX, double pointerY, const wlr_box& box);
} // namespace umbriel
