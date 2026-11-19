#include "view/resize_trace.h"

#ifdef UMBRIEL_HARNESS

#include "view/resize_lag.h"
#include "view/view.h"
#include "wlr.h"

#include <cstdlib>
#include <ctime>
#include <fcntl.h>
#include <format>
#include <string>
#include <string_view>
#include <unistd.h>

namespace umbriel::resizeTrace {
  namespace {
    bool initialised = false;
    bool enabled = false;
    const char* tracePath = nullptr;

    // Monotonic microseconds: whole milliseconds are too coarse for a configure round trip on a fast client.
    uint64_t monoUs() {
      timespec ts{};
      clock_gettime(CLOCK_MONOTONIC, &ts);
      return (static_cast<uint64_t>(ts.tv_sec) * 1'000'000) + (static_cast<uint64_t>(ts.tv_nsec) / 1'000);
    }

    bool traceEnabled() {
      if (!initialised) {
        initialised = true;
        tracePath = std::getenv("UMBRIEL_RESIZE_TRACE");
        enabled = tracePath != nullptr && tracePath[0] != '\0';
      }
      return enabled;
    }

    // One line per call, opened and closed each time: a trace is a diagnostic, and an interrupted run must still leave
    // every record it wrote. A failure to write is not a compositor error and is ignored.
    void writeLine(std::string_view line) {
      if (!traceEnabled() || line.empty()) {
        return;
      }
      const int fd = open(tracePath, O_WRONLY | O_CREAT | O_APPEND, 0644);
      if (fd < 0) {
        return;
      }
      size_t written = 0;
      while (written < line.size()) {
        const ssize_t result = write(fd, line.data() + written, line.size() - written);
        if (result <= 0) {
          break;
        }
        written += static_cast<size_t>(result);
      }
      close(fd);
    }

    std::string_view edgeName(uint32_t edges) {
      switch (edges) {
      case WLR_EDGE_TOP:
        return "top";
      case WLR_EDGE_BOTTOM:
        return "bottom";
      case WLR_EDGE_LEFT:
        return "left";
      case WLR_EDGE_RIGHT:
        return "right";
      case WLR_EDGE_TOP | WLR_EDGE_LEFT:
        return "top_left";
      case WLR_EDGE_TOP | WLR_EDGE_RIGHT:
        return "top_right";
      case WLR_EDGE_BOTTOM | WLR_EDGE_LEFT:
        return "bottom_left";
      case WLR_EDGE_BOTTOM | WLR_EDGE_RIGHT:
        return "bottom_right";
      default:
        return "unknown";
      }
    }
  } // namespace

  void step(
      std::string_view kind, uint32_t edges, double pointerX, double pointerY, const wlr_box& box, const wlr_box& target
  ) {
    if (!traceEnabled()) {
      return;
    }
    const ResizeEdgeLag drawn = resizeEdgeLag(edges, pointerX, pointerY, box);
    const ResizeEdgeLag aimed = resizeEdgeLag(edges, pointerX, pointerY, target);
    const std::string line = std::format(
        R"({{"t_us":{},"kind":"{}","edge":"{}","pointer":[{:.1f},{:.1f}],"drawn":[{},{},{},{}],"target":[{},{},{},{}],"drawn_lag":[{:.1f},{:.1f}],"target_lag":[{:.1f},{:.1f}]}})"
        "\n",
        monoUs(), kind, edgeName(edges), pointerX, pointerY, box.x, box.y, box.width, box.height, target.x, target.y,
        target.width, target.height, drawn.dx, drawn.dy, aimed.dx, aimed.dy
    );
    writeLine(line);
  }

  void configure(std::string_view kind, int width, int height, uint32_t serial) {
    if (!traceEnabled()) {
      return;
    }
    const std::string line = std::format(
        R"({{"t_us":{},"event":"configure","kind":"{}","size":[{},{}],"serial":{}}})"
        "\n",
        monoUs(), kind, width, height, serial
    );
    writeLine(line);
  }

  void commit(const View& view) {
    if (!traceEnabled()) {
      return;
    }
    const wlr_box content = view.committedContentBox();
    const wlr_box drawn = view.presentedBox();
    const std::string line = std::format(
        R"({{"t_us":{},"event":"commit","committed":[{},{}],"drawn":[{},{}]}})"
        "\n",
        monoUs(), content.width, content.height, drawn.width, drawn.height
    );
    writeLine(line);
  }

  void deferred(std::string_view kind) {
    if (!traceEnabled()) {
      return;
    }
    const std::string line = std::format(
        R"({{"t_us":{},"event":"deferred","kind":"{}"}})"
        "\n",
        monoUs(), kind
    );
    writeLine(line);
  }
} // namespace umbriel::resizeTrace

#else

// The header promises the symbols exist in every build; a release resolves them to nothing.
namespace umbriel::resizeTrace {
  void step(std::string_view, uint32_t, double, double, const wlr_box&, const wlr_box&) {}
  void configure(std::string_view, int, int, uint32_t) {}
  void commit(const View&) {}
  void deferred(std::string_view) {}
} // namespace umbriel::resizeTrace

#endif
