#!/usr/bin/env bash
# A window leaving a scratchpad for its workspace fades in there, the second half of the fade that hid it. A window
# whose saved state is a tile fades the same way, so a tiled restore is not a pop once the arrange has caught up.
set -euo pipefail

readonly CLIENT="${UMBRIEL_POPUP_CLIENT:-./build-debug/tests/popup-client}"
readonly TILED_CLIENT="${UMBRIEL_UNMAP_CLIENT:-./build-debug/tests/unmap-client}"
readonly CLIENT_LOG="$UMBRIEL_RUNTIME_DIR/scratchpad-restore-client.log"
readonly TILED_LOG="$UMBRIEL_RUNTIME_DIR/scratchpad-restore-tiled.log"
readonly FLOAT_TITLE=popup-focus-regression
readonly TILED_TITLE=tiled-restore

# The float sample sits at the output centre, where the popup client's window lands on its workspace.
float_blue() {
  "$UMBRIEL_PIXEL_PROBE" "$UMBRIEL_RUNTIME_DIR/$1.png" mean 20x20+630+350 | awk '{ print $3 }'
}

# The tiled sample sits inside the narrow left column the layout gives that window.
tiled_blue() {
  "$UMBRIEL_PIXEL_PROBE" "$UMBRIEL_RUNTIME_DIR/$1.png" mean 20x200+$2+200 | awk '{ printf "%.0f", $3 }'
}

field() {
  "$UMBRIEL" windows --json | jq -r --arg title "$1" --arg key "$2" '.[] | select(.title == $title) | .[$key] // ""'
}

# A pad stays open once it is empty, so an earlier leg leaves it on screen; show it only when the window is hidden.
show_pad() {
  "$UMBRIEL" msg window-move-to-scratchpad > /dev/null
  "$UMBRIEL" clock-advance 2000
  if [[ $(field "$1" scratchpad) == "" ]]; then
    echo "$1 did not enter the pad: $("$UMBRIEL" windows --json)"
    exit 1
  fi
  if [[ $(field "$1" visible) != true ]]; then
    "$UMBRIEL" msg scratchpad-toggle > /dev/null
    "$UMBRIEL" clock-advance 2000
  fi
}

cat >> "$UMBRIEL_CONFIG" <<'EOF'

[output.HEADLESS-1]
workspaces = ["ONE", "TWO"]

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
CLIENT_PID=$!
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

show_pad "$FLOAT_TITLE"
grim "$UMBRIEL_RUNTIME_DIR/before.png"
before=$(float_blue before)
if (( before < 80 )); then
  echo "scratchpad window was not visible before the restore: blue=$before"
  exit 1
fi

"$UMBRIEL" msg window-restore-from-scratchpad > /dev/null
grim "$UMBRIEL_RUNTIME_DIR/at-once.png"
at_once=$(float_blue at-once)
if (( at_once >= 10 )); then
  echo "restored window was drawn at full opacity instead of starting its fade: blue=$at_once"
  exit 1
fi

"$UMBRIEL" clock-advance 600
grim "$UMBRIEL_RUNTIME_DIR/mid.png"
mid=$(float_blue mid)
if (( mid <= 20 || mid >= 100 )); then
  echo "restore did not fade through a partial opacity: at_once=$at_once mid=$mid"
  exit 1
fi

"$UMBRIEL" clock-advance 2000
grim "$UMBRIEL_RUNTIME_DIR/after.png"
after=$(float_blue after)
if (( after < 80 )); then
  echo "restored window never reached full opacity: mid=$mid after=$after"
  exit 1
fi
if [[ $(field "$FLOAT_TITLE" scratchpad) != "" || $(field "$FLOAT_TITLE" workspace) == "" ]]; then
  echo "restored window kept its scratchpad membership: $("$UMBRIEL" windows --json)"
  exit 1
fi

# A workspace move that follows the window activates the destination, so it fades in the same way.
show_pad "$FLOAT_TITLE"
"$UMBRIEL" msg window-move-to-workspace TWO > /dev/null
move_x=$(field "$FLOAT_TITLE" x)
move_y=$(field "$FLOAT_TITLE" y)
"$UMBRIEL" clock-advance 600
grim "$UMBRIEL_RUNTIME_DIR/move-mid.png"
move_mid=$("$UMBRIEL_PIXEL_PROBE" "$UMBRIEL_RUNTIME_DIR/move-mid.png" mean 20x20+$((move_x + 20))+$((move_y + 20)) |
  awk '{ printf "%.0f", $3 }')
"$UMBRIEL" clock-advance 2000
grim "$UMBRIEL_RUNTIME_DIR/move-after.png"
move_after=$("$UMBRIEL_PIXEL_PROBE" "$UMBRIEL_RUNTIME_DIR/move-after.png" mean 20x20+$((move_x + 20))+$((move_y + 20)) |
  awk '{ printf "%.0f", $3 }')
if (( move_mid <= 20 || move_mid >= 100 )); then
  echo "a workspace move out of the pad did not fade: mid=$move_mid"
  exit 1
fi
if (( move_after < 80 )); then
  echo "a window moved out of the pad never reached full opacity: mid=$move_mid after=$move_after"
  exit 1
fi

# Control: the restore fade is the scratchpad transition, so disabling it lands the window in one frame.
sed -i 's/^enabled = true # SCRATCHPAD_ANIMATION$/enabled = false # SCRATCHPAD_ANIMATION/' "$UMBRIEL_CONFIG"
"$UMBRIEL" msg config-reload > /dev/null
show_pad "$FLOAT_TITLE"
"$UMBRIEL" msg window-restore-from-scratchpad > /dev/null
grim "$UMBRIEL_RUNTIME_DIR/at-once-disabled.png"
at_once_disabled=$(float_blue at-once-disabled)
if (( at_once_disabled < 80 )); then
  echo "restore still faded with the scratchpad animation disabled: blue=$at_once_disabled"
  exit 1
fi

# A window whose saved state is a tile returns to the layout instead of a remembered float, so this leg covers the
# same fade reaching a destination that only exists once the arrange has run.
kill "$CLIENT_PID" 2>/dev/null || true
for _ in $(seq 80); do
  [[ -z $(field "$FLOAT_TITLE" id) ]] && break
  sleep 0.05
done
sed -i 's/^enabled = false # SCRATCHPAD_ANIMATION$/enabled = true # SCRATCHPAD_ANIMATION/' "$UMBRIEL_CONFIG"
"$UMBRIEL" msg config-reload > /dev/null

FOLLOW_CONFIGURES=1 FILL_COLOR=0xFF0000FF "$TILED_CLIENT" "$TILED_TITLE" > "$TILED_LOG" 2>&1 &
for _ in $(seq 80); do
  [[ -n $(field "$TILED_TITLE" id) ]] && break
  sleep 0.05
done
if [[ -z $(field "$TILED_TITLE" id) ]]; then
  echo "tiled restore client never mapped: $(cat "$TILED_LOG")"
  exit 1
fi

show_pad "$TILED_TITLE"
"$UMBRIEL" msg window-restore-from-scratchpad > /dev/null
tile_x=$(field "$TILED_TITLE" x)
tx=$((tile_x + 10))
grim "$UMBRIEL_RUNTIME_DIR/tiled-at-once.png"
tiled_at_once=$(tiled_blue tiled-at-once "$tx")
"$UMBRIEL" clock-advance 600
grim "$UMBRIEL_RUNTIME_DIR/tiled-mid.png"
tiled_mid=$(tiled_blue tiled-mid "$tx")
"$UMBRIEL" clock-advance 2000
grim "$UMBRIEL_RUNTIME_DIR/tiled-after.png"
tiled_after=$(tiled_blue tiled-after "$tx")
if (( tiled_mid <= 20 || tiled_mid >= 100 )); then
  echo "the tiled restore did not fade through a partial opacity: at_once=$tiled_at_once mid=$tiled_mid"
  exit 1
fi
if (( tiled_after < 80 )); then
  echo "the tiled restore never reached full opacity: mid=$tiled_mid after=$tiled_after"
  exit 1
fi

echo "scratchpad restore faded in on its workspace: float $at_once -> $mid -> $after, tiled $tiled_at_once -> $tiled_mid -> $tiled_after, moved $move_mid at 600 ms -> $move_after, snapped at $at_once_disabled when disabled"
