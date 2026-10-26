#!/usr/bin/env bash
# harness: outputs=1
# appearance.downsample picks how the scene samples a minified source. A client
# alternating per-texel columns, shrunk 3:1, makes the methods distinguishable
# by pixel: box averages the fragment's whole texel footprint and preserves the
# pattern's 2:1 coverage ratio per output pixel, while bilinear point-samples
# and invents an even 50/50 mix. The method is a scene policy, so flipping it
# on a reload must re-render.
set -euo pipefail
source "$UMBRIEL_HARNESS_LIB"

readonly CLIENT="${UMBRIEL_FRACTIONAL_CLIENT:-./build-debug/tests/fractional-client}"
readonly CLIENT_LOG="$UMBRIEL_RUNTIME_DIR/downsample-box-client.log"

cat >> "$UMBRIEL_CONFIG" <<'CONFIG'
[animation]
enabled = false
[appearance]
border_width = 0
outer_border_width = 0
corner_radius = 0
downsample = "box"
[appearance.blur]
enabled = false
[appearance.shadow]
enabled = false
[output.HEADLESS-1]
scale = 1.0
render_scale = 3.0

[[window_rule]]
match.title = "^downsample-box$"
default_floating = true
default_floating_size_px = { width = 400, height = 300 }
default_position = { x = 40, y = 40, anchor = "top_left" }
CONFIG
"$UMBRIEL" msg config-reload > /dev/null

"$CLIENT" downsample-box 400 300 > "$CLIENT_LOG" 2>&1 &
await_lines "$CLIENT_LOG" 'mapped ' 1
presented=$(grep '^mapped ' "$CLIENT_LOG" | tail -1)
if [[ $presented != *"buffer 1200x900"* || $presented != *"scale 360/120"* ]]; then
  echo "the client did not render at render_scale 3.0 ($presented)"
  exit 1
fi

readonly IMAGE="$UMBRIEL_RUNTIME_DIR/downsample-box.png"

pixel() {
  local px=$1 py=$2 red green blue
  read -r red green blue < <("$UMBRIEL_PIXEL_PROBE" "$IMAGE" pixel "$px" "$py")
  echo "$red $green $blue"
}

probe_matches() {
  local px=$1 py=$2 er=$3 eg=$4 eb=$5 red green blue
  read -r red green blue < <("$UMBRIEL_PIXEL_PROBE" "$IMAGE" pixel "$px" "$py")
  [[ $red =~ ^[0-9]+$ ]] || return 1
  ((red >= er - 2 && red <= er + 2 && green >= eg - 2 && green <= eg + 2 && blue >= eb - 2 && blue <= eb + 2))
}

# The window occupies output x 40..439, three buffer texels per output pixel.
# Output px 41 covers texels 3..5 (green, blue, green) and px 42 texels 6..8
# (blue, green, blue). Poll for the pair, then fail with what rendered: each
# argument list is g/b for px 41 then px 42 (red is 0).
expect_pair() {
  local description=$1 g1=$2 b1=$3 g2=$4 b2=$5
  for _ in $(seq 30); do
    grim -o HEADLESS-1 "$IMAGE"
    if probe_matches 41 190 0 "$g1" "$b1" && probe_matches 42 190 0 "$g2" "$b2"; then
      return 0
    fi
    sleep 0.1
  done
  echo "$description: got $(pixel 41 190) and $(pixel 42 190), expected 0 $g1 $b1 and 0 $g2 $b2"
  exit 1
}

# Box: output px 41 covers two green texels and one blue (0,170,85), px 42 the
# mirror (0,85,170) in the sRGB screenshot.
expect_pair "box downsample" 170 85 85 170

sed -i 's/downsample = "box"/downsample = "bilinear"/' "$UMBRIEL_CONFIG"
"$UMBRIEL" msg config-reload > /dev/null
"$UMBRIEL" settle > /dev/null
# Bilinear: one point sample per output pixel lands on a texel center and
# reports that texel pure, dropping the other two (aliasing).
expect_pair "bilinear downsample" 0 255 255 0 0

sed -i 's/downsample = "bilinear"/downsample = "box"/' "$UMBRIEL_CONFIG"
"$UMBRIEL" msg config-reload > /dev/null
"$UMBRIEL" settle > /dev/null
expect_pair "box restored on reload" 170 85 85 170

echo "downsample method controls minified sampling and reload re-renders"

# Cap: at 5:1 the four-tap grid must step ratio/K texels so it still spans the
# whole footprint (a one-texel step would average only 4 of the 5 texels and
# report an even mix). The window's logical position (40,40) lands at output
# (32,32) under scale 0.8; px 41 and 42 cover whole 5-texel trios.
mapped_before=$(grep -c '^mapped ' "$CLIENT_LOG")
sed -i 's/scale = 1.0/scale = 0.8/; s/render_scale = 3.0/render_scale = 4.0/' "$UMBRIEL_CONFIG"
"$UMBRIEL" msg config-reload > /dev/null
await_lines "$CLIENT_LOG" 'mapped ' "$((mapped_before + 1))" 0.05
presented=$(grep '^mapped ' "$CLIENT_LOG" | tail -1)
if [[ $presented != *"buffer 1600x1200"* ]]; then
  echo "the client did not render at render_scale 4.0 ($presented)"
  exit 1
fi
"$UMBRIEL" settle > /dev/null
expect_pair "capped box spans the footprint" 139 115 127 127

echo "capped box grid spans the full minification footprint"
