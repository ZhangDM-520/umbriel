#!/usr/bin/env bash
# harness: outputs=2
# When a window rule moves the focused window a scratchpad shows on its own into another scratchpad that is showing a
# different window on the other output, the moved window is not shown there, so it must not keep keyboard focus. The
# pad it leaves is empty and still on screen, and its backdrop must stop taking pointer input from the window below.
set -euo pipefail

readonly CLIENT="${UMBRIEL_UNMAP_CLIENT:-./build-debug/tests/unmap-client}"
readonly POINTER="${UMBRIEL_POINTER_CLIENT:-./build-debug/tests/pointer-client}"
readonly CONTROL="$UMBRIEL_RUNTIME_DIR/transfer-outputs-control"
readonly FRAME="$UMBRIEL_RUNTIME_DIR/show-step-transfer-outputs.png"
readonly RED_LOG="$UMBRIEL_RUNTIME_DIR/transfer-red.log"
readonly UNDER_LOG="$UMBRIEL_RUNTIME_DIR/under-pad.log"
readonly OTHER_LOG="$UMBRIEL_RUNTIME_DIR/other-pad.log"
readonly PRESS_LOG="$UMBRIEL_RUNTIME_DIR/press-pad.log"

cat >> "$UMBRIEL_CONFIG" <<'EOF'

[animation]
enabled = false

[animation.scratchpad]
dim = 0.5
blur = false

[appearance]
border_width = 0
outer_border_width = 0
corner_radius = 0

[appearance.shadow]
enabled = false

[output.HEADLESS-1]
mode = "1280x720"
position = [0, 0]

[output.HEADLESS-2]
mode = "1280x720"
position = [1280, 0]

[[scratchpad]]
name = "a"

[[scratchpad]]
name = "b"

[[window_rule]]
match.title = "^transfer-"
default_floating = true
default_floating_size_px = { width = 300, height = 200 }

[[window_rule]]
match.title = "^moved-out$"
default_scratchpad = "b"
EOF
"$UMBRIEL" msg config-reload > /dev/null

windows() { "$UMBRIEL" windows --json; }
window_of() { windows | jq -c --arg title "$1" '.[] | select(.title == $title)'; }

wait_for_window() {
  for _ in $(seq 80); do
    [[ -n "$(window_of "$1")" ]] && return 0
    sleep 0.05
  done
  echo "window '$1' never appeared: $(windows)"
  return 1
}

# Which of the two colours are on screen across both outputs.
shown() {
  "$UMBRIEL" settle
  grim "$FRAME"
  local visible=() w h
  read -r _ _ w h < <("$UMBRIEL_PIXEL_PROBE" "$FRAME" bbox 'r > 0.9 && g < 0.1 && b < 0.1')
  ((w > 0 && h > 0)) && visible+=(red)
  read -r _ _ w h < <("$UMBRIEL_PIXEL_PROBE" "$FRAME" bbox 'g > 0.9 && r < 0.1 && b < 0.1')
  ((w > 0 && h > 0)) && visible+=(green)
  echo "${visible[*]}"
}

# Scratchpad b shows its green window on its own on the right output.
"$POINTER" 2560 720 move 1920 360
FILL_COLOR=0xFF00FF00 "$CLIENT" transfer-green 300 200 > "$UMBRIEL_RUNTIME_DIR/transfer-green.log" 2>&1 &
wait_for_window transfer-green
"$UMBRIEL" msg window-move-to-scratchpad b > /dev/null
"$UMBRIEL" msg scratchpad-window-show-next b > /dev/null

# Two workspace windows on the left output sit under the pads, for the emptied pad to draw over. They tile side by
# side, so a press that the backdrop takes instead of the window under it lands on the other one.
"$POINTER" 2560 720 move 640 360
FILL_COLOR=0xFF0000FF "$CLIENT" under-pad 300 200 > "$UNDER_LOG" 2>&1 &
wait_for_window under-pad
FILL_COLOR=0xFF00FFFF "$CLIENT" other-pad 300 200 > "$OTHER_LOG" 2>&1 &
wait_for_window other-pad
FILL_COLOR=0xFFFFFF00 "$CLIENT" press-pad 300 200 > "$PRESS_LOG" 2>&1 &
wait_for_window press-pad

# Scratchpad a shows its red window on its own, focused, on the left output.
mkfifo "$CONTROL"
exec {control_fd}<> "$CONTROL"
FILL_COLOR=0xFFFF0000 TITLE_AFTER_MAP=moved-out "$CLIENT" transfer-red 300 200 \
  < "$CONTROL" > "$RED_LOG" 2>&1 &
wait_for_window transfer-red
"$UMBRIEL" msg window-move-to-scratchpad a > /dev/null
"$UMBRIEL" msg scratchpad-window-show-next a > /dev/null
before=$(shown)
if [[ $before != "red green" ]]; then
  echo "both scratchpads did not show their window: [$before]: $(windows)"
  exit 1
fi
if [[ $(window_of transfer-red | jq -r .active) != true ]]; then
  echo "the red window did not have focus before moving: $(windows)"
  exit 1
fi

# The new title moves the red window into b, which keeps showing green on its own.
printf 't\n' >&"$control_fd"
for _ in $(seq 80); do
  [[ $(window_of moved-out | jq -r .scratchpad) == b ]] && break
  sleep 0.05
done
if [[ $(window_of moved-out | jq -r .scratchpad) != b ]]; then
  echo "the window rule did not move the red window into scratchpad b: $(windows)"
  exit 1
fi
after=$(shown)
if [[ $after == *red* ]]; then
  echo "the moved window is shown although b shows another window on its own: [$after]: $(windows)"
  exit 1
fi

# The pad the red window left is empty and still on screen: its backdrop passes the press through to the workspace
# window under the pointer. Focusing the other window first tells a direct hit from the backdrop's own refocus, which
# would land on that other window instead.
"$UMBRIEL" msg window-focus "$(window_of other-pad | jq -r .id)" > /dev/null
for _ in $(seq 40); do
  [[ $(window_of under-pad | jq -r .active) == false ]] && break
  sleep 0.025
done
if [[ $(window_of under-pad | jq -r .active) != false ]]; then
  echo "the workspace window below the pad kept focus: $(windows)"
  exit 1
fi
read -r under_x under_y <<< "$(window_of under-pad | jq -r '"\((.x + .w / 2) | floor) \((.y + .h / 2) | floor)"')"
"$POINTER" 2560 720 move "$under_x" "$under_y" click 272
for _ in $(seq 40); do
  [[ $(window_of under-pad | jq -r .active) == true ]] && break
  sleep 0.025
done
if [[ $(window_of under-pad | jq -r .active) != true ]]; then
  echo "the emptied pad swallowed the press meant for the window below it: $(windows)"
  exit 1
fi

# Closing a pad's last member empties it the same way, and with animation disabled no fade ticks the backdrop, so the
# empty pad must drop its input on the close itself.
"$UMBRIEL" msg window-focus "$(window_of under-pad | jq -r .id)" > /dev/null
"$UMBRIEL" msg window-move-to-scratchpad a > /dev/null
for _ in $(seq 80); do
  [[ $(window_of under-pad | jq -r .scratchpad) == a ]] && break
  sleep 0.025
done
if [[ $(window_of under-pad | jq -r .scratchpad) != a ]]; then
  echo "the window did not join the emptied pad: $(windows)"
  exit 1
fi
"$UMBRIEL" msg window-focus "$(window_of other-pad | jq -r .id)" > /dev/null
kill "$(window_of under-pad | jq -r .pid)"
for _ in $(seq 80); do
  [[ -z $(window_of under-pad) ]] && break
  sleep 0.025
done
if [[ -n $(window_of under-pad) ]]; then
  echo "the pad member did not close: $(windows)"
  exit 1
fi
read -r press_x press_y <<< "$(window_of press-pad | jq -r '"\((.x + .w / 2) | floor) \((.y + .h / 2) | floor)"')"
"$POINTER" 2560 720 move "$press_x" "$press_y" click 272
for _ in $(seq 40); do
  [[ $(window_of press-pad | jq -r .active) == true ]] && break
  sleep 0.025
done
if [[ $(window_of press-pad | jq -r .active) != true ]]; then
  echo "the emptied pad swallowed the press after a close: $(windows)"
  exit 1
fi

# A key typed now must not reach the window nobody can see.
"$POINTER" 1 1 keyboard-only tap 30 > /dev/null
"$UMBRIEL" settle
if grep -q '^key 30 ' "$RED_LOG"; then
  echo "a key typed after the move reached the hidden window: $(grep -E '^keyboard-|^key ' "$RED_LOG" | tr '\n' ' ')"
  exit 1
fi

echo "a window moved into a scratchpad showing another window gave up keyboard focus, and a pad emptied by that move"
echo "or by a close let the next press through to the window below"
