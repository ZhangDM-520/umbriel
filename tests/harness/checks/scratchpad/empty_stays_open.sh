#!/usr/bin/env bash
# harness: outputs=1
# A pad whose last window leaves keeps showing its backdrop; hide_when_empty and scratchpad-toggle are the ways to hide
# an empty pad. Its backdrop is therefore still over the restored window afterwards, and a pad that stays open never
# fades that backdrop out under a window that is still arriving. While the pad is empty that backdrop is passive: it
# dims the output without taking pointer input, so a press reaches the window underneath; a shown pad with a member
# keeps it.
set -euo pipefail
source "$UMBRIEL_HARNESS_LIB"

readonly CLIENT="${UMBRIEL_UNMAP_CLIENT:-./build-debug/tests/unmap-client}"
readonly OBSERVER="${UMBRIEL_SEAT_LOG_CLIENT:-./build-debug/tests/seat-log-client}"
readonly POINTER="${UMBRIEL_POINTER_CLIENT:-./build-debug/tests/pointer-client}"
readonly TITLE=empty-pad-window
readonly FLOOR=empty-pad-floor
readonly DOOMED=empty-pad-doomed
readonly PARKED=empty-pad-parked
readonly FLOOR_LOG="$UMBRIEL_RUNTIME_DIR/empty-pad-floor.log"
CLICKED=

field_of() {
  window_by_title "$1" | jq -r --arg key "$2" 'if .[$key] == null then "" else .[$key] end'
}

field() { field_of "$TITLE" "$1"; }

wait_field() {
  local actual=
  for _ in $(seq 80); do
    actual=$(field_of "$1" "$2")
    [[ $actual == "$3" ]] && return 0
    sleep 0.025
  done
  echo "expected $1 $2=$3, got $actual: $("$UMBRIEL" windows --json)"
  exit 1
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

# Buttons the seat-log window received. A press the backdrop takes never reaches it, which is what tells a direct hit
# from the pad's own refocus: both leave the window focused, only one delivers the press.
presses() { events "$FLOOR_LOG" 'pointer-button'; }

wait_for_press() {
  local before=$1 label=$2
  for _ in $(seq 80); do
    (($(presses) > before)) && return 0
    sleep 0.025
  done
  echo "the press never reached the window under the pad $label, at $CLICKED: $("$UMBRIEL" windows --json | jq -c '.[] | {title,x,y,w,h,active,visible,scratchpad}')"
  exit 1
}

# The centre of the pad's under-window, which a member floating near its old tile does not cover.
click_floor() {
  local x y
  read -r x y <<< "$(window_by_title "$FLOOR" | jq -r '(.x + .w / 2 | floor), (.y + .h / 2 | floor)' | paste -sd ' ')"
  CLICKED="$x,$y"
  "$POINTER" 1280 720 move "$x" "$y" click 272
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

[[scratchpad]]
name = "main"

[[scratchpad]]
name = "parked"
EOF
"$UMBRIEL" msg config-reload > /dev/null

"$CLIENT" "$TITLE" > "$UMBRIEL_RUNTIME_DIR/empty-pad-client.log" 2>&1 &
CLIENT_PID=$!
await_window "$TITLE"
"$CLIENT" "$DOOMED" > "$UMBRIEL_RUNTIME_DIR/empty-pad-doomed.log" 2>&1 &
DOOMED_PID=$!
await_window "$DOOMED"
"$CLIENT" "$PARKED" > "$UMBRIEL_RUNTIME_DIR/empty-pad-parked.log" 2>&1 &
PARKED_PID=$!
await_window "$PARKED"
"$OBSERVER" "$FLOOR" > "$FLOOR_LOG" 2>&1 &
OBSERVER_PID=$!
await_window "$FLOOR"

"$UMBRIEL" clock-freeze
assert_clear left 20

title_id=$(field id)
"$UMBRIEL" msg window-focus "$title_id" > /dev/null
wait_field "$TITLE" active true
"$UMBRIEL" msg window-move-to-scratchpad main > /dev/null
"$UMBRIEL" clock-advance 1200
"$UMBRIEL" msg scratchpad-toggle main > /dev/null
"$UMBRIEL" clock-advance 1200
if [[ $(field scratchpad) != main ]]; then
  echo "the window did not join the pad: $("$UMBRIEL" windows --json)"
  exit 1
fi
assert_dim left 20

# The last member leaves: the pad itself stays open, backdrop included.
"$UMBRIEL" msg window-restore-from-scratchpad main > /dev/null
"$UMBRIEL" clock-advance 1200
if [[ $(field scratchpad) != "" || $(field workspace) == "" ]]; then
  echo "the window did not return to its workspace: $("$UMBRIEL" windows --json)"
  exit 1
fi
assert_dim left 20

# The standing pad is passive: the press passes through the backdrop to the window behind it, which keeps the pad open.
taken=$(presses)
click_floor
wait_for_press "$taken" "after a restore"
if [[ $(field scratchpad) != "" || $(field workspace) == "" ]]; then
  echo "the press closed the empty pad: $("$UMBRIEL" windows --json)"
  exit 1
fi
assert_dim left 20

# A member parked in a hidden pad does not make this empty pad's backdrop take the press.
"$UMBRIEL" msg window-focus "$(window_by_title "$PARKED" | jq -r .id)" > /dev/null
"$UMBRIEL" msg window-move-to-scratchpad parked > /dev/null
"$UMBRIEL" clock-advance 1200
wait_field "$PARKED" visible false
wait_field "$PARKED" scratchpad parked
taken=$(presses)
click_floor
wait_for_press "$taken" "with a member parked in another pad"
assert_dim left 20

# A pad with a member still takes the press: the window behind receives nothing.
"$UMBRIEL" msg window-focus "$title_id" > /dev/null
"$UMBRIEL" msg window-move-to-scratchpad main > /dev/null
"$UMBRIEL" clock-advance 1200
wait_field "$TITLE" scratchpad main
wait_field "$TITLE" visible true
taken=$(presses)
click_floor
for _ in $(seq 20); do
  sleep 0.025
done
if (($(presses) != taken)); then
  echo "a populated pad let the press through to the window behind it: $("$UMBRIEL" windows --json)"
  exit 1
fi
"$UMBRIEL" msg window-focus "$title_id" > /dev/null
"$UMBRIEL" msg window-restore-from-scratchpad main > /dev/null
"$UMBRIEL" clock-advance 1200

# Closing the last member empties the pad the same way a restore does, so the pass-through follows that route too.
"$UMBRIEL" msg window-focus "$(window_by_title "$DOOMED" | jq -r .id)" > /dev/null
"$UMBRIEL" msg window-move-to-scratchpad main > /dev/null
"$UMBRIEL" clock-advance 1200
wait_field "$DOOMED" scratchpad main
wait_field "$DOOMED" visible true
kill "$DOOMED_PID" 2>/dev/null || true
await_window_closed "$DOOMED"
"$UMBRIEL" clock-advance 1200
assert_dim left 20
taken=$(presses)
click_floor
wait_for_press "$taken" "after a close"
if [[ $(field scratchpad) != "" ]]; then
  echo "the press closed the empty pad: $("$UMBRIEL" windows --json)"
  exit 1
fi
assert_dim left 20

"$UMBRIEL" msg scratchpad-toggle main > /dev/null
"$UMBRIEL" clock-advance 1200
assert_clear left 20

# hide_when_empty hides however the pad empties: a restore and a close both take it off screen.
cat >> "$UMBRIEL_CONFIG" <<'EOF'

[[scratchpad]]
name = "term"
hide_when_empty = true
EOF
"$UMBRIEL" msg config-reload > /dev/null
"$UMBRIEL" msg window-focus "$title_id" > /dev/null
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
kill "$PARKED_PID" 2>/dev/null || true
kill "$OBSERVER_PID" 2>/dev/null || true
await_window_closed "$TITLE"
await_window_closed "$PARKED"
await_window_closed "$FLOOR"
"$UMBRIEL" clock-advance 1200
assert_clear left 20

echo "an empty pad kept its backdrop after its last window restored or closed, and let a press reach the window"
echo "behind it, while a populated pad still took it; hide_when_empty closed the emptied pad"
