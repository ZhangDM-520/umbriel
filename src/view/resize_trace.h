#pragma once

#include <cstdint>
#include <string_view>

struct wlr_box;

namespace umbriel {
  class View;

  // Resize-lag trace, compiled only with the harness option. It answers one question the compositor cannot be asked
  // from outside: for each step of a pointer resize, how far the drawn box was from the pointer, and how far the
  // compositor's own target was from it. The gap between those two numbers is the part of a resize lag the client owns.
  //
  // Records go to the file named by UMBRIEL_RESIZE_TRACE, one JSON object per line, appended as they happen. Every
  // function is a no-op in a build without the harness option, so no call site needs a guard.
  namespace resizeTrace {
    // A pointer step during a resize grab. `box` is the drawn box and `target` the box the compositor is heading for,
    // so `drawnLag` is what the eye sees and `targetLag` what the compositor has already decided.
    void step(
        std::string_view kind, uint32_t edges, double pointerX, double pointerY, const wlr_box& box,
        const wlr_box& target
    );

    // A size configure leaving the compositor (`floating` or `tiled`), and the client commit that answered it.
    void configure(std::string_view kind, int width, int height, uint32_t serial);
    void commit(const View& view);

    // A step the grab could not act on because a held switch owned the workspace.
    void deferred(std::string_view kind);
  } // namespace resizeTrace
} // namespace umbriel
