#!/usr/bin/env bash
# harness: outputs=2
# Releasing a dragged window over a pad that is on screen places it in that pad from any output: it keeps the drop
# position, is drawn above the pad backdrop rather than animating over it and snapping underneath, and restoring it
# returns to the workspace the drag started on. A pinned window's drag is declined and stays above the backdrop,
# because pinned windows outrank a pad; a lifted tab group is declined and settles under it.
set -euo pipefail
source "$UMBRIEL_HARNESS_LIB"

readonly CLIENT="${UMBRIEL_UNMAP_CLIENT:-./build-debug/tests/unmap-client}"
readonly BTN_LEFT=272
# HEADLESS-2 sits at x=0 and HEADLESS-1 at x=1280.
readonly LAYOUT_W=2560
readonly LAYOUT_H=720

field() {
  window_by_title "$1" | jq -r --arg key "$2" '.[$key] // ""'
}

# Mean green inside a window: full while the window is above a visible pad's backdrop, halved while it is under it.
green_at() {
  grim "$UMBRIEL_RUNTIME_DIR/$1.png"
  "$UMBRIEL_PIXEL_PROBE" "$UMBRIEL_RUNTIME_DIR/$1.png" mean 20x20+$2+$3 | awk '{ printf "%.0f", $2 }'
}

# Mean red at the top-left of an output: the white backdrop, dimmed while a pad shows there.
corner() {
  grim "$UMBRIEL_RUNTIME_DIR/corner-$1.png"
  "$UMBRIEL_PIXEL_PROBE" "$UMBRIEL_RUNTIME_DIR/corner-$1.png" mean 40x40+$2+600 | awk '{ printf "%.0f", $1 }'
}

cat >> "$UMBRIEL_CONFIG" <<'EOF'

[animation]
duration_ms = 400

[animation.scratchpad]
enabled = true
duration_ms = 400
curve = "linear"
dim = 0.5
blur = false

[colors]
backdrop = "#FFFFFFFF"

[appearance]
border_width = 0
outer_border_width = 0
corner_radius = 0

[[window_rule]]
match.title = "^drag-into-pad-float$"
default_output = "HEADLESS-2"
default_floating = true
default_floating_size_px = { width = 400, height = 300 }

[[window_rule]]
match.title = "^drag-into-pad-tile$"
default_output = "HEADLESS-2"

[[window_rule]]
match.title = "^drag-into-pad-pinned$"
default_output = "HEADLESS-2"
default_floating = true
default_floating_size_px = { width = 400, height = 300 }
EOF
"$UMBRIEL" msg config-reload > /dev/null

# A frozen clock cannot settle a running animation, so let time follow the wall clock again before waiting.
settle_motion() {
  "$UMBRIEL" clock-resume
  "$UMBRIEL" settle
}

spawn_window() {
  settle_motion
  FILL_COLOR=0xFF00FF00 "$CLIENT" "$1" 400 300 > "$UMBRIEL_RUNTIME_DIR/$1.log" 2>&1 &
  SPAWNED_PID=$!
  await_window "$1"
  "$UMBRIEL" settle
}

box() {
  window_by_title "$1" | jq -r '"\(.x) \(.y) \(.w) \(.h)"'
}

# A pad takes the pointer while it is on screen, so the drag starts first and the pad opens under it: that is the order
# in which a window is ever dragged over a pad.
start_drag() {
  local x=$1 y=$2 end_x=$3 end_y=$4
  pointer_hold $LAYOUT_W $LAYOUT_H mod logo move "$x" "$y" press "$BTN_LEFT" move "$end_x" "$end_y" \
    -- release "$BTN_LEFT" mod none
}

open_pad_mid_drag() {
  "$UMBRIEL" msg scratchpad-toggle > /dev/null
  "$UMBRIEL" clock-advance 1200
}

# A floating window dragged onto a pad on its own output.
spawn_window drag-into-pad-float
read -r wx wy ww wh < <(box drag-into-pad-float)
float_workspace=$(field drag-into-pad-float workspace)
"$UMBRIEL" clock-freeze
start_drag $((wx + ww / 2)) $((wy + 20)) $((wx + ww / 2 + 30)) $((wy + 90))
open_pad_mid_drag
if (( $(corner left 20) >= 200 )); then
  echo "the pad did not open on the left output during the drag: corner=$(corner left 20)"
  exit 1
fi
pointer_release
"$UMBRIEL" clock-advance 400

if [[ $(field drag-into-pad-float scratchpad) != default ]]; then
  echo "a floating window released over the pad was not placed in it: $("$UMBRIEL" windows --json)"
  exit 1
fi
drop_x=$(field drag-into-pad-float x)
drop_y=$(field drag-into-pad-float y)
if (( drop_x < wx + 20 || drop_x > wx + 60 || drop_y < wy + 70 || drop_y > wy + 110 )); then
  echo "the dropped floating window lost its drop position: $wx,$wy -> $drop_x,$drop_y"
  exit 1
fi
float_green=$(green_at float-dropped $((drop_x + 20)) $((drop_y + 40)))
if (( float_green < 220 )); then
  echo "the dropped floating window is not drawn above the pad backdrop: green=$float_green"
  exit 1
fi

"$UMBRIEL" msg window-restore-from-scratchpad > /dev/null
"$UMBRIEL" clock-advance 1200
if [[ $(field drag-into-pad-float scratchpad) != "" || $(field drag-into-pad-float workspace) != "$float_workspace" ]]; then
  echo "restoring the dropped floating window did not return it to $float_workspace: $("$UMBRIEL" windows --json)"
  exit 1
fi
# The pad stayed open, so the restored window is under its dim until the pad is toggled off.
"$UMBRIEL" msg scratchpad-toggle > /dev/null
"$UMBRIEL" clock-advance 1200
if (( $(corner left 20) < 200 )); then
  echo "toggling the empty pad off left it on screen: corner=$(corner left 20)"
  exit 1
fi
kill "$SPAWNED_PID" 2>/dev/null || true
await_window_closed drag-into-pad-float
settle_motion

# A tiled window dragged from the left output onto a pad on the right one.
spawn_window drag-into-pad-tile
read -r tx ty tw th < <(box drag-into-pad-tile)
tile_workspace=$(field drag-into-pad-tile workspace)
"$UMBRIEL" clock-freeze
start_drag $((tx + tw / 2)) $((ty + 20)) 1700 300
open_pad_mid_drag
if (( $(corner right 1300) >= 200 )); then
  echo "the pad did not open on the right output during the cross-output drag: corner=$(corner right 1300)"
  exit 1
fi
pointer_release
"$UMBRIEL" clock-advance 400

if [[ $(field drag-into-pad-tile scratchpad) != default ]]; then
  echo "a window dragged from another output was not placed in the pad: $("$UMBRIEL" windows --json)"
  exit 1
fi
tile_x=$(field drag-into-pad-tile x)
tile_y=$(field drag-into-pad-tile y)
# The grab point was (tw/2, 20) inside the tile, so the release point puts the box top-left at (1700 - tw/2, 280).
expected_x=$((1700 - tw / 2))
if (( tile_x < expected_x - 8 || tile_x > expected_x + 8 || tile_y < 272 || tile_y > 288 )); then
  echo "the dropped tile lost its drop position: expected $expected_x,280, got $tile_x,$tile_y"
  exit 1
fi
tile_green=$(green_at tile-dropped $((tile_x + 20)) $((tile_y + 40)))
if (( tile_green < 220 )); then
  echo "the cross-output dropped window is not drawn above the pad backdrop: green=$tile_green"
  exit 1
fi
"$UMBRIEL" msg window-restore-from-scratchpad > /dev/null
"$UMBRIEL" clock-advance 1200
if [[ $(field drag-into-pad-tile scratchpad) != "" || $(field drag-into-pad-tile workspace) != "$tile_workspace" ]]; then
  echo "restoring the cross-output drop did not return it to $tile_workspace: $("$UMBRIEL" windows --json)"
  exit 1
fi
"$UMBRIEL" msg scratchpad-toggle > /dev/null
"$UMBRIEL" clock-advance 1200
if (( $(corner right 1300) < 200 )); then
  echo "the cross-output pad was not still showing before it was toggled off: corner=$(corner right 1300)"
  exit 1
fi
kill "$SPAWNED_PID" 2>/dev/null || true
await_window_closed drag-into-pad-tile
settle_motion

# A pinned window's drag is a pin gesture, so the pad declines it. The declined window must settle under the backdrop
# from its first frame instead of riding the drag layer above it.
spawn_window drag-into-pad-pinned
"$UMBRIEL" msg window-focus "$(field drag-into-pad-pinned id)" > /dev/null
"$UMBRIEL" msg window-toggle-pinned > /dev/null
read -r px py pw ph < <(box drag-into-pad-pinned)
"$UMBRIEL" clock-freeze
start_drag $((px + pw / 2)) $((py + 20)) $((px + pw / 2 + 30)) $((py + 90))
open_pad_mid_drag
if (( $(corner left 20) >= 200 )); then
  echo "the pad did not open during the pin drag: corner=$(corner left 20)"
  exit 1
fi
pointer_release
"$UMBRIEL" clock-advance 100
if [[ $(field drag-into-pad-pinned scratchpad) != "" ]]; then
  echo "a pinned window's drag was placed in the pad: $("$UMBRIEL" windows --json)"
  exit 1
fi
if [[ $(field drag-into-pad-pinned pinned) != true ]]; then
  echo "a declined pin drag unpinned the window: $("$UMBRIEL" windows --json)"
  exit 1
fi
# Pinned windows outrank a scratchpad backdrop, so this one keeps full green; what the drop must not do is join the pad.
declined_green=$(green_at declined $((px + pw / 2)) $((py + ph / 2)))
if (( declined_green < 220 )); then
  echo "a declined pin drag lost its pinned presentation: green=$declined_green"
  exit 1
fi
"$UMBRIEL" clock-advance 1200
"$UMBRIEL" msg scratchpad-toggle > /dev/null
"$UMBRIEL" clock-advance 1200
kill "$SPAWNED_PID" 2>/dev/null || true
await_window_closed drag-into-pad-pinned
settle_motion

# A lifted tab group is declined as well: the group lands on the workspace under the pad instead of being split into it.
TAB_PIDS=()
spawn_tab() {
  FILL_COLOR=0xFF00FF00 "$CLIENT" "$1" 400 300 > "$UMBRIEL_RUNTIME_DIR/$1.log" 2>&1 &
  TAB_PIDS+=("$!")
  await_window "$1"
}
spawn_tab drag-into-pad-tab-a
spawn_tab drag-into-pad-tab-b
"$UMBRIEL" msg window-consume-left > /dev/null
"$UMBRIEL" msg column-toggle-tabbed > /dev/null
settle_motion
read -r gx gy gw gh < <(box drag-into-pad-tab-b)
"$UMBRIEL" clock-freeze
start_drag $((gx + gw / 2)) $((gy + 40)) 900 400
open_pad_mid_drag
if (( $(corner left 20) >= 200 )); then
  echo "the pad did not open during the tab-group drag: corner=$(corner left 20)"
  exit 1
fi
pointer_release
"$UMBRIEL" clock-advance 1200
if [[ $(field drag-into-pad-tab-a scratchpad) != "" || $(field drag-into-pad-tab-b scratchpad) != "" ]]; then
  echo "a lifted tab group was placed in the pad: $("$UMBRIEL" windows --json)"
  exit 1
fi
if [[ $(field drag-into-pad-tab-a tabbed) != true || $(field drag-into-pad-tab-b tabbed) != true ]]; then
  echo "a declined tab-group drop split the group: $("$UMBRIEL" windows --json)"
  exit 1
fi
read -r gx gy gw gh < <(box drag-into-pad-tab-b)
group_green=$(green_at group $((gx + gw / 2)) $((gy + 40)))
if (( group_green > 160 )); then
  echo "a declined tab group was left above the pad backdrop: green=$group_green"
  exit 1
fi
"$UMBRIEL" msg scratchpad-toggle > /dev/null
"$UMBRIEL" clock-advance 1200
kill "${TAB_PIDS[@]}" 2>/dev/null || true
await_window_closed drag-into-pad-tab-a
await_window_closed drag-into-pad-tab-b
settle_motion

echo "drops over an open pad joined it (float $float_green, cross-output $tile_green), declined a pin drag ($declined_green) and a tab group ($group_green) onto the workspace"
