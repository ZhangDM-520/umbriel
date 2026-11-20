#!/usr/bin/env bash
# A window leaving a scratchpad for its workspace fades in there, the second half of the fade that hid it.
set -euo pipefail

readonly CLIENT="${UMBRIEL_POPUP_CLIENT:-./build-debug/tests/popup-client}"
readonly CLIENT_LOG="$UMBRIEL_RUNTIME_DIR/scratchpad-restore-client.log"

sample_blue() {
  "$UMBRIEL_PIXEL_PROBE" "$UMBRIEL_RUNTIME_DIR/$1.png" mean 20x20+630+350 | awk '{ print $3 }'
}

sample() {
  grim "$UMBRIEL_RUNTIME_DIR/$1.png"
  sample_blue "$1"
}

window_field() {
  "$UMBRIEL" windows --json | jq -r --arg key "$1" '.[0] | .[$key] // ""'
}

cat >> "$UMBRIEL_CONFIG" <<'EOF'

[animation]
duration_ms = 1000

[animation.windows_in]
enabled = false

[animation.scratchpad]
enabled = true # SCRATCHPAD_ANIMATION
duration_ms = 2000
curve = "linear"
dim = 0.0
blur = false

[colors]
backdrop = "#000000FF"

[appearance]
border_width = 0
outer_border_width = 0
corner_radius = 0
EOF
"$UMBRIEL" msg config-reload > /dev/null

"$CLIENT" > "$CLIENT_LOG" 2>&1 &
for _ in $(seq 60); do
  grep -q '^ready$' "$CLIENT_LOG" && break
  sleep 0.1
done
if ! grep -q '^ready$' "$CLIENT_LOG"; then
  echo "scratchpad restore client never became ready: $(cat "$CLIENT_LOG")"
  exit 1
fi

# Frozen animation time makes every sample land on an exact point of the fade.
"$UMBRIEL" clock-freeze

enter_pad() {
  "$UMBRIEL" msg window-move-to-scratchpad > /dev/null
  "$UMBRIEL" clock-advance 2000
  "$UMBRIEL" msg scratchpad-toggle > /dev/null
  "$UMBRIEL" clock-advance 2000
  local shown
  shown=$(sample "$1")
  if (( $(awk -v blue="$shown" 'BEGIN { print blue < 80 }') )); then
    echo "scratchpad window was not visible before the restore: blue=$shown"
    exit 1
  fi
}

enter_pad before
"$UMBRIEL" msg window-restore-from-scratchpad > /dev/null
at_once=$(sample at-once)
if (( $(awk -v blue="$at_once" 'BEGIN { print blue >= 10 }') )); then
  echo "restored window was drawn at full opacity instead of starting its fade: blue=$at_once"
  exit 1
fi

"$UMBRIEL" clock-advance 600
mid=$(sample mid)
if (( $(awk -v blue="$mid" 'BEGIN { print blue <= 20 || blue >= 100 }') )); then
  echo "restore did not fade through a partial opacity: at_once=$at_once mid=$mid"
  exit 1
fi

"$UMBRIEL" clock-advance 2000
after=$(sample after)
if (( $(awk -v blue="$after" 'BEGIN { print blue < 80 }') )); then
  echo "restored window never reached full opacity: mid=$mid after=$after"
  exit 1
fi
if [[ $(window_field scratchpad) != "" || $(window_field workspace) == "" ]]; then
  echo "restored window kept its scratchpad membership: $("$UMBRIEL" windows --json)"
  exit 1
fi

# Control: the restore fade is the scratchpad transition, so disabling it lands the window in one frame.
sed -i 's/^enabled = true # SCRATCHPAD_ANIMATION$/enabled = false # SCRATCHPAD_ANIMATION/' "$UMBRIEL_CONFIG"
"$UMBRIEL" msg config-reload > /dev/null
enter_pad before-disabled
"$UMBRIEL" msg window-restore-from-scratchpad > /dev/null
at_once_disabled=$(sample at-once-disabled)
if (( $(awk -v blue="$at_once_disabled" 'BEGIN { print blue < 80 }') )); then
  echo "restore still faded with the scratchpad animation disabled: blue=$at_once_disabled"
  exit 1
fi

echo "scratchpad restore faded in on its workspace: blue $at_once -> $mid -> $after, snapped at $at_once_disabled when disabled"
