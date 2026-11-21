#include "view/resize_lag.h"

extern "C" {
#include <wlr/util/edges.h>
}

#include <algorithm>
#include <cmath>

namespace umbriel {
  double ResizeEdgeLag::magnitude() const { return std::max(std::abs(dx), std::abs(dy)); }

  ResizeEdgeLag resizeEdgeLag(uint32_t edges, double pointerX, double pointerY, const wlr_box& box) {
    ResizeEdgeLag lag;
    // An edge that is not grabbed has no pointer to compare against: a left-edge drag says nothing about the right
    // edge's distance from the pointer.
    if ((edges & WLR_EDGE_LEFT) != 0) {
      lag.dx = box.x - pointerX;
    } else if ((edges & WLR_EDGE_RIGHT) != 0) {
      lag.dx = (box.x + box.width) - pointerX;
    }
    if ((edges & WLR_EDGE_TOP) != 0) {
      lag.dy = box.y - pointerY;
    } else if ((edges & WLR_EDGE_BOTTOM) != 0) {
      lag.dy = (box.y + box.height) - pointerY;
    }
    return lag;
  }
} // namespace umbriel
