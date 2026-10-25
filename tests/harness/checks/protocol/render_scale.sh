#!/usr/bin/env bash
# harness: outputs=1
# render_scale supersedes the logical scale in the client scale hints alone: a
# fractional client must be asked to render at render_scale (its buffer grows to
# floor(logical x render_scale)) while the output keeps presenting the logical
# scale. Dropping the key on a reload must re-notify the client back to the
# logical scale.
set -euo pipefail

readonly CLIENT="${UMBRIEL_FRACTIONAL_CLIENT:-./build-debug/tests/fractional-client}"
readonly CLIENT_LOG="$UMBRIEL_RUNTIME_DIR/render-scale-client.log"

cat >> "$UMBRIEL_CONFIG" <<'EOF'

[[window_rule]]
match.title = "^render-scale$"
default_floating = true
default_floating_size_px = { width = 400, height = 300 }
default_position = { x = 40, y = 40, anchor = "top_left" }

[output."HEADLESS-1"]
scale = 1.25
render_scale = 2.0
EOF
"$UMBRIEL" msg config-reload > /dev/null

"$CLIENT" render-scale 400 300 > "$CLIENT_LOG" 2>&1 &
for _ in $(seq 60); do
  grep -q '^mapped ' "$CLIENT_LOG" && break
  sleep 0.05
done

presented=$(grep '^mapped ' "$CLIENT_LOG" | tail -1)
echo "presented at render_scale: $presented"
if [[ $presented != *"buffer 800x600"* || $presented != *"scale 240/120"* ]]; then
  echo "the client was not asked to render at render_scale 2.0"
  exit 1
fi

scale_shown=$("$UMBRIEL" outputs | awk '/Scale:/ { print $2; exit }')
render_shown=$("$UMBRIEL" outputs | awk '/Render scale:/ { print $3; exit }')
echo "outputs: Scale=$scale_shown Render scale=$render_shown"
awk -v a="$scale_shown" 'BEGIN { exit !(a + 0 == 1.25) }' || {
  echo "the output stopped presenting the logical scale"
  exit 1
}
awk -v a="$render_shown" 'BEGIN { exit !(a + 0 == 2.0) }' || {
  echo "umbriel outputs does not report the render scale"
  exit 1
}

before=$(grep -c '^mapped ' "$CLIENT_LOG")
sed -i '/render_scale/d' "$UMBRIEL_CONFIG"
"$UMBRIEL" msg config-reload > /dev/null
for _ in $(seq 60); do
  [[ $(grep -c '^mapped ' "$CLIENT_LOG") -gt $before ]] && break
  sleep 0.05
done

presented=$(grep '^mapped ' "$CLIENT_LOG" | tail -1)
echo "presented after reload: $presented"
if [[ $presented != *"buffer 500x375"* || $presented != *"scale 150/120"* ]]; then
  echo "dropping render_scale did not re-notify the client back to the logical scale"
  exit 1
fi
echo "render_scale drives the client hints and falls back to the logical scale on reload"
