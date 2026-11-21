#!/usr/bin/env bash
# The scratchpad backdrop blur honours animation.scratchpad.blur_strength. A bottom-layer square gives one sharp
# vertical edge at x=200; a strength blur pulls the green/blue boundary inward, and strength 0.0 leaves it clean.
set -euo pipefail
source "$UMBRIEL_HARNESS_LIB"

readonly IMAGE="$UMBRIEL_RUNTIME_DIR/backdrop-blur-strength.png"
readonly LAYER_LOG="$UMBRIEL_RUNTIME_DIR/backdrop-blur-strength-layer.log"
# Inside the 200 px green square, close enough to its right edge that any blur reaches it.
readonly STRIP='8x40+186+80'
# Blue above this in the strip means the background bled across the square's edge.
readonly BLUE_THRESHOLD=12

cat >> "$UMBRIEL_CONFIG" <<'CONFIG'

[animation]
enabled = false

[animation.scratchpad]
dim = 0.0
blur = true
blur_strength = 1.0

[appearance]
border_width = 0
corner_radius = 0

[appearance.blur]
enabled = true
optimized = false
passes = 2
radius = 8
noise = 0.0
brightness = 1.0
contrast = 1.0
saturation = 1.0
CONFIG
"$UMBRIEL" msg config-reload > /dev/null

# The background layer fills the output in 0xFF5577AA; the bottom-layer square is 0xFF00FF00 in the top-left corner.
"$UMBRIEL_LAYER_CLIENT" HEADLESS-1 0 > "$UMBRIEL_RUNTIME_DIR/backdrop-blur-strength-wallpaper.log" 2>&1 &
await_events "$UMBRIEL_RUNTIME_DIR/backdrop-blur-strength-wallpaper.log" ready 1 "the wallpaper"
"$UMBRIEL_LAYER_CLIENT" HEADLESS-1 0 bottom-layer > "$LAYER_LOG" 2>&1 &
await_events "$LAYER_LOG" ready 1 "the square"

# Reprint the backdrop from the current config, then report the strip's blue level.
strip_blue() {
  "$UMBRIEL" msg config-reload > /dev/null
  # The backdrop values are read on each retarget, so hide and show the pad to pick them up.
  "$UMBRIEL" msg scratchpad-toggle > /dev/null
  "$UMBRIEL" msg scratchpad-toggle > /dev/null
  "$UMBRIEL" settle
  grim "$IMAGE"
  local r _ b
  read -r r _ b < <("$UMBRIEL_PIXEL_PROBE" "$IMAGE" mean "$STRIP")
  printf '%s\n' "$b"
}

assert_blurred() {
  local blue
  blue=$(strip_blue)
  if ! awk -v b="$blue" -v t="$BLUE_THRESHOLD" 'BEGIN { exit !(b > t) }'; then
    echo "$1: edge was sharp (blue $blue <= $BLUE_THRESHOLD)"
    return 1
  fi
  echo "$1: blue $blue"
}

assert_sharp() {
  local blue
  blue=$(strip_blue)
  if ! awk -v b="$blue" -v t="$BLUE_THRESHOLD" 'BEGIN { exit !(b < t) }'; then
    echo "$1: edge was blurred (blue $blue >= $BLUE_THRESHOLD)"
    return 1
  fi
  echo "$1: blue $blue"
}

# Even an empty scratchpad shows its backdrop, which is all this check needs.
"$UMBRIEL" msg scratchpad-toggle > /dev/null

assert_blurred "blur_strength 1.0"

sed -i 's/^blur_strength = 1.0$/blur_strength = 0.0/' "$UMBRIEL_CONFIG"
assert_sharp "blur_strength 0.0"

# Only the appearance gate may sharpen the edge here: strength goes back to 1.0, so a check that inherited 0.0 would
# pass vacuously.
sed -i 's/^blur_strength = 0.0$/blur_strength = 1.0/' "$UMBRIEL_CONFIG"
sed -i '/^\[appearance\.blur\]$/,/^saturation = /s/^enabled = true$/enabled = false/' "$UMBRIEL_CONFIG"
assert_sharp "appearance blur disabled at strength 1.0"

echo "scratchpad backdrop blur scales with blur_strength and stays inert without appearance blur"
