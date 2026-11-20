#!/usr/bin/env bash
# harness: outputs=1
# A pad whose last window leaves keeps showing its backdrop; hide_when_empty and scratchpad-toggle are the ways to hide
# an empty pad. Its backdrop is therefore still over the restored window afterwards, and a pad that stays open never
# fades that backdrop out under a window that is still arriving.
set -euo pipefail
source "$UMBRIEL_HARNESS_LIB"

readonly CLIENT="${UMBRIEL_UNMAP_CLIENT:-./build-debug/tests/unmap-client}"
readonly TITLE=empty-pad-window
readonly CLIENT_LOG="$UMBRIEL_RUNTIME_DIR/empty-pad-client.log"

field() {
  window_by_title "$TITLE" | jq -r --arg key "$1" '.[$key] // ""'
}

# Mean red at the top-left of one output: the white backdrop, dark while a pad dims that output.
corner() {
  grim "$UMBRIEL_RUNTIME_DIR/$1.png"
  "$UMBRIEL_PIXEL_PROBE" "$UMBRIEL_RUNTIME_DIR/$1.png" mean 40x40+$2+600 | awk '{ printf "%.0f", $1 }'
}

assert_dim() {
  local value
  value=$(corner "$1" "$2")
  if (( value < 100 || value > 160 )); then
    echo "expected a pad over $1, corner=$value"
    exit 1
  fi
}

assert_clear() {
  local value
  value=$(corner "$1" "$2")
  if (( value < 200 )); then
    echo "expected $1 undimmed, corner=$value"
    exit 1
  fi
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
EOF
"$UMBRIEL" msg config-reload > /dev/null

FILL_COLOR=0xFFFF0000 "$CLIENT" "$TITLE" > "$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!
await_window "$TITLE"

"$UMBRIEL" clock-freeze
assert_clear left 20

"$UMBRIEL" msg window-move-to-scratchpad > /dev/null
"$UMBRIEL" clock-advance 1200
"$UMBRIEL" msg scratchpad-toggle > /dev/null
"$UMBRIEL" clock-advance 1200
if [[ $(field scratchpad) != default ]]; then
  echo "the window did not join the pad: $("$UMBRIEL" windows --json)"
  exit 1
fi
assert_dim left 20

# The last member leaves: the pad itself stays open, backdrop included.
"$UMBRIEL" msg window-restore-from-scratchpad > /dev/null
"$UMBRIEL" clock-advance 1200
if [[ $(field scratchpad) != "" || $(field workspace) == "" ]]; then
  echo "the window did not return to its workspace: $("$UMBRIEL" windows --json)"
  exit 1
fi
assert_dim left 20

"$UMBRIEL" msg scratchpad-toggle > /dev/null
"$UMBRIEL" clock-advance 1200
assert_clear left 20

# hide_when_empty hides however the pad empties: a restore and a close both take it off screen.
cat >> "$UMBRIEL_CONFIG" <<'EOF'

[[scratchpad]]
name = "term"
hide_when_empty = true
EOF
"$UMBRIEL" msg config-reload > /dev/null
"$UMBRIEL" msg window-move-to-scratchpad term > /dev/null
"$UMBRIEL" clock-advance 1200
"$UMBRIEL" msg scratchpad-toggle term > /dev/null
"$UMBRIEL" clock-advance 1200
if [[ $(field scratchpad) != term ]]; then
  echo "the hide_when_empty pad did not take the window: $("$UMBRIEL" windows --json)"
  exit 1
fi
assert_dim left 20

"$UMBRIEL" msg window-restore-from-scratchpad term > /dev/null
"$UMBRIEL" clock-advance 1200
if [[ $(field scratchpad) != "" ]]; then
  echo "the window did not leave the hide_when_empty pad: $("$UMBRIEL" windows --json)"
  exit 1
fi
assert_clear left 20

"$UMBRIEL" msg window-move-to-scratchpad term > /dev/null
"$UMBRIEL" msg scratchpad-toggle term > /dev/null
"$UMBRIEL" clock-advance 1200
assert_dim left 20
kill "$CLIENT_PID" 2>/dev/null || true
await_window_closed "$TITLE"
"$UMBRIEL" clock-advance 1200
assert_clear left 20

echo "an empty pad kept its backdrop after its last window was restored; hide_when_empty closed it on restore and close"
