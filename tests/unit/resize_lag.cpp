#include "view/resize_lag.h"

#include "check.h"
extern "C" {
#include <wlr/util/edges.h>
}

namespace {
  constexpr wlr_box kBox{.x = 100, .y = 50, .width = 400, .height = 300};
}

UMBRIEL_TEST(resizeLagReadsOnlyTheGrabbedEdge) {
  // A left-edge drag says nothing about the right edge: reporting it would read the window's width as lag.
  const auto left = umbriel::resizeEdgeLag(WLR_EDGE_LEFT, 100, 200, kBox);
  CHECK_EQ(left.dx, 0.0);
  CHECK_EQ(left.dy, 0.0);

  const auto lagging = umbriel::resizeEdgeLag(WLR_EDGE_LEFT, 130, 200, kBox);
  CHECK_EQ(lagging.dx, -30.0);
  CHECK_EQ(lagging.magnitude(), 30.0);
}

UMBRIEL_TEST(resizeLagUsesTheFarEdgeOfACornerGrab) {
  // A bottom-right grab compares the pointer against the box's right and bottom edges, not its origin.
  const auto lag = umbriel::resizeEdgeLag(WLR_EDGE_BOTTOM | WLR_EDGE_RIGHT, 480, 330, kBox);
  CHECK_EQ(lag.dx, 20.0);
  CHECK_EQ(lag.dy, 20.0);
  CHECK_EQ(lag.magnitude(), 20.0);
}

UMBRIEL_TEST(resizeLagIsZeroWhenTheEdgeIsUnderThePointer) {
  for (const uint32_t edges : {WLR_EDGE_TOP, WLR_EDGE_BOTTOM, WLR_EDGE_LEFT, WLR_EDGE_RIGHT}) {
    const double x = (edges & WLR_EDGE_LEFT) != 0 ? kBox.x : (edges & WLR_EDGE_RIGHT) != 0 ? kBox.x + kBox.width : 0;
    const double y = (edges & WLR_EDGE_TOP) != 0 ? kBox.y : (edges & WLR_EDGE_BOTTOM) != 0 ? kBox.y + kBox.height : 0;
    CHECK_EQ(umbriel::resizeEdgeLag(edges, x, y, kBox).magnitude(), 0.0);
  }
}

UMBRIEL_TEST(resizeLagIgnoresAnUngrabbedAxis) {
  // A horizontal-only grab reports zero on the vertical axis even when the pointer is far from the box.
  const auto lag = umbriel::resizeEdgeLag(WLR_EDGE_RIGHT, 500, 5000, kBox);
  CHECK_EQ(lag.dx, 0.0);
  CHECK_EQ(lag.dy, 0.0);
}

int main() { return RUN_TESTS(); }
