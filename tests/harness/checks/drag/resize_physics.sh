#!/usr/bin/env bash
# Floating pointer resize with [animation.windows_resize] physics = true deforms the window as an elastic sheet pinned
# at the anchored edge while the dragged edge lags behind growth inside the new box, then relaxes to fill the final
# box after release. Programmatic size changes cancel an active resize grab without loading the jump, disabling
# physics mid-resize clears the bound deformation slot on release, and with physics = false the resize draws immediately
# and leaves no animation running, held or released.
set -euo pipefail
source "$UMBRIEL_HARNESS_LIB"
readonly BTN_RIGHT=273
readonly OUTPUT_W=1280
readonly OUTPUT_H=720
readonly RESIZE_DW=120
readonly IMAGE="$UMBRIEL_RUNTIME_DIR/resize-physics.png"
cat >> "$UMBRIEL_CONFIG" <<'EOF'

[colors]
backdrop = "#000000FF"
[appearance]
border_width = 0
outer_border_width = 0
corner_radius = 0
drag_opacity = 1.0
[appearance.shadow]
enabled = false
[animation]
duration_ms = 1
curve = "linear"
[animation.windows_in]
enabled = false
[animation.windows_move]
enabled = false
[animation.windows_drag]
physics = false
[animation.windows_resize]
enabled = false
physics = true
[[window_rule]]
match.title = "^resize-physics$"
default_floating = true
EOF
"$UMBRIEL" msg config-reload > /dev/null

green_count() { "$UMBRIEL_PIXEL_PROBE" "$IMAGE" count 'g > 0.9 && r < 0.1 && b < 0.1' "$1"; }

spawn() {
  local log=$1
  FILL_COLOR=0xFF00FF00 FOLLOW_CONFIGURES=1 "$UMBRIEL_UNMAP_CLIENT" resize-physics 400 300 \
    > "$UMBRIEL_RUNTIME_DIR/$log" 2>&1 &
  await_window resize-physics
  "$UMBRIEL" settle > /dev/null
  window=$(window_by_title resize-physics)
}

resize_right() {
  local grab_x=$1 grab_y=$2
  pointer_hold "$OUTPUT_W" "$OUTPUT_H" move "$grab_x" "$grab_y" mod super press "$BTN_RIGHT" \
    move $((grab_x + 40)) "$grab_y" move $((grab_x + 80)) "$grab_y" move $((grab_x + RESIZE_DW)) "$grab_y" \
    -- release "$BTN_RIGHT" mod none
}

await_width() {
  local op=$1 target_w=$2
  for _ in $(seq 80); do
    window=$(window_by_title resize-physics)
    local cur_w
    cur_w=$(jq -r '.w' <<< "$window")
    case "$op" in
      eq) ((cur_w == target_w)) && return 0 ;;
      gt) ((cur_w > target_w)) && return 0 ;;
    esac
    sleep 0.025
  done
  echo "resized client never satisfied width $op $target_w: $window"
  return 1
}

outside_green() {
  local bx=$1 by=$2 bw=$3 bh=$4 band=0
  for strip in "$((bw + 24))x10+$((bx - 12))+$((by - 12))" "$((bw + 24))x10+$((bx - 12))+$((by + bh + 2))" \
    "10x$((bh + 4))+$((bx - 12))+$((by - 2))" "10x$((bh + 4))+$((bx + bw + 2))+$((by - 2))"; do
    band=$((band + $(green_count "$strip")))
  done
  echo "$band"
}

assert_interrupted_cleanly() {
  local action=$1
  read -r x y w h id < <(jq -r '"\(.x) \(.y) \(.w) \(.h) \(.id)"' <<< "$window")
  "$UMBRIEL" clock-freeze
  local gx=$((x + w - 10)) gy=$((y + h / 2))
  pointer_hold "$OUTPUT_W" "$OUTPUT_H" move "$gx" "$gy" mod super press "$BTN_RIGHT" \
    move $((gx + 40)) "$gy" -- release "$BTN_RIGHT" mod none
  await_width eq $((w + 40))
  # Advance past settle_after_pause_s (0.25s) so the held sheet snaps to rest while the resize grab stays held.
  "$UMBRIEL" clock-advance 300 > /dev/null
  "$UMBRIEL" settle > /dev/null
  local -a action_args
  read -ra action_args <<< "$action"
  "$UMBRIEL" msg "${action_args[@]}" > /dev/null
  await_width gt $((w + 40))
  read -r mx my mw mh < <(jq -r '"\(.x) \(.y) \(.w) \(.h)"' <<< "$window")
  "$UMBRIEL" clock-advance 16 > /dev/null
  if ! "$UMBRIEL" settle > /dev/null 2>&1; then
    echo "$action during a resize grab left resize physics running"
    exit 1
  fi
  grim "$IMAGE"
  if (($(green_count "20x40+$((mx + mw - 25))+$((my + mh / 2 - 20))") != 800)); then
    echo "$action during a resize grab deformed the resized right edge"
    exit 1
  fi
  pointer_release
  "$UMBRIEL" clock-resume
}

spawn first.log
read -r x y w h id < <(jq -r '"\(.x) \(.y) \(.w) \(.h) \(.id)"' <<< "$window")

# Growing the right edge loads negative X displacement at u = 1 so the dragged edge lags behind growth inside the
# committed box, leaving a trailing empty strip just inside the new right edge while the anchored left edge stays
# pinned at mid-height.
"$UMBRIEL" clock-freeze
resize_right $((x + w - 10)) $((y + h / 2))
new_w=$((w + RESIZE_DW))
await_width eq "$new_w"
"$UMBRIEL" clock-advance 16 > /dev/null
grim "$IMAGE"

mid_y=$((y + h / 2 - 20))
trail_gap=$(green_count "20x40+$((x + new_w - 25))+${mid_y}")
inner_fill=$(green_count "20x40+$((x + new_w - 80))+${mid_y}")
left_out=$(green_count "20x40+$((x - 22))+${mid_y}")
left_in=$(green_count "20x40+${x}+${mid_y}")
if ((trail_gap != 0)); then
  echo "expected trailing empty gap inside the growing right edge, got $trail_gap green pixels"
  exit 1
fi
if ((inner_fill != 800)); then
  echo "expected solid window body behind the trailing gap, got $inner_fill/800 green pixels"
  exit 1
fi
if ((left_out != 0 || left_in != 800)); then
  echo "anchored left edge did not hold pin at mid-height (outside=$left_out, inside=$left_in)"
  exit 1
fi
pointer_release

# After release the sheet relaxes out to the full final box.
settle_frozen
grim "$IMAGE"
window=$(window_by_title resize-physics)
read -r fx fy fw fh < <(jq -r '"\(.x) \(.y) \(.w) \(.h)"' <<< "$window")
if ((fx != x || fy != y || fw != new_w || fh != h)); then
  echo "settled window box ${fw}x${fh}+${fx}+${fy} differed from expected ${new_w}x${h}+${x}+${y}"
  exit 1
fi
if (($(green_count "20x40+$((fx + fw - 25))+${mid_y}") != 800)); then
  echo "the right edge did not relax back to the final box after release"
  exit 1
fi
if (($(outside_green "$fx" "$fy" "$fw" "$fh") > 0)); then
  echo "green pixels remained outside the settled window box"
  exit 1
fi
if (($(green_count "${fw}x${fh}+${fx}+${fy}") < fw * fh * 9 / 10)); then
  echo "the settled resized window did not fill its final box"
  exit 1
fi

"$UMBRIEL" msg window-close "$id" > /dev/null
"$UMBRIEL" clock-resume
await_window_closed resize-physics

spawn interrupt.log
assert_interrupted_cleanly "window-set-primary-extent 0.5"
assert_interrupted_cleanly "window-toggle-maximize"
"$UMBRIEL" msg window-close "$id" > /dev/null
await_window_closed resize-physics

# Disabling resize physics mid-resize clears the bound deformation slot immediately on reload even while held,
# while drag physics keeps the shared shader alive and the frozen clock skips repeat ticks.
sed -i '/^\[animation\.windows_drag\]/,/^\[/ s/^physics = false$/physics = true/' "$UMBRIEL_CONFIG"
"$UMBRIEL" msg config-reload > /dev/null
spawn reload.log
read -r x y w h id < <(jq -r '"\(.x) \(.y) \(.w) \(.h) \(.id)"' <<< "$window")
"$UMBRIEL" clock-freeze
resize_right $((x + w - 10)) $((y + h / 2))
new_w=$((w + RESIZE_DW))
await_width eq "$new_w"
"$UMBRIEL" clock-advance 16 > /dev/null
sed -i '/^\[animation\.windows_resize\]/,/^\[/ s/^physics = true$/physics = false/' "$UMBRIEL_CONFIG"
"$UMBRIEL" msg config-reload > /dev/null
if ! "$UMBRIEL" settle > /dev/null 2>&1; then
  echo "reloading physics = false mid-resize left an animation running while held"
  exit 1
fi
grim "$IMAGE"
if (($(green_count "20x40+$((x + new_w - 25))+$((y + h / 2 - 20))") != 800)); then
  echo "reloading physics = false mid-resize kept a stale deformation bound while held"
  exit 1
fi
pointer_release
if ! "$UMBRIEL" settle > /dev/null 2>&1; then
  echo "reloading physics = false mid-resize left an animation running after release"
  exit 1
fi
"$UMBRIEL" msg window-close "$id" > /dev/null
"$UMBRIEL" clock-resume
await_window_closed resize-physics

# physics = false: the resize stays rigid and runs no animation, held or released.
sed -i '/^\[animation\.windows_drag\]/,/^\[/ s/^physics = true$/physics = false/' "$UMBRIEL_CONFIG"
"$UMBRIEL" msg config-reload > /dev/null
spawn off.log
read -r x y w h id < <(jq -r '"\(.x) \(.y) \(.w) \(.h) \(.id)"' <<< "$window")
"$UMBRIEL" clock-freeze
resize_right $((x + w - 10)) $((y + h / 2))
new_w=$((w + RESIZE_DW))
await_width eq "$new_w"
if ! "$UMBRIEL" settle > /dev/null 2>&1; then
  echo "physics = false left an animation running while the resize is held"
  exit 1
fi
grim "$IMAGE"
mid_y=$((y + h / 2 - 20))
if (($(green_count "20x40+$((x + new_w - 25))+${mid_y}") != 800)); then
  echo "physics = false did not draw immediately to the resized right edge"
  exit 1
fi
if (($(outside_green "$x" "$y" "$new_w" "$h") > 0)); then
  echo "physics = false deformed the resized window past its box"
  exit 1
fi
pointer_release
if ! "$UMBRIEL" settle > /dev/null 2>&1; then
  echo "physics = false left an animation running after release"
  exit 1
fi
"$UMBRIEL" clock-resume

echo "resize physics trailed the growing right edge, kept the anchored edge pinned, cancelled cleanly on interruption, cleared on reload, relaxed on release, and stayed rigid with physics off"
