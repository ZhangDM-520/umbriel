#!/usr/bin/env bash
# harness: outputs=1
# A window the pointer is carrying is outside every pad until it is released. The scratchpad window actions refuse it
# with an error instead of moving it out from under the grab, and the release then decides: over a visible pad it stays
# a member, and a member whose pad was closed under the drag leaves the pad and lands on the workspace. Opening or
# closing the pad itself stays allowed, which is what keeps the two directions symmetric.
set -euo pipefail
source "$UMBRIEL_HARNESS_LIB"

readonly CLIENT="${UMBRIEL_UNMAP_CLIENT:-./build-debug/tests/unmap-client}"
readonly BTN_LEFT=272
readonly MEMBER=drag-actions-member
readonly TILE=drag-actions-tile
readonly SOLO=drag-actions-solo
readonly CLOSE_REASON="error: the window is being dragged"

cat >> "$UMBRIEL_CONFIG" <<'EOF'

[animation]
enabled = false

[animation.scratchpad]
dim = 0.5
blur = false

[colors]
backdrop = "#FFFFFFFF"

[appearance]
border_width = 0
outer_border_width = 0
corner_radius = 0

[[scratchpad]]
name = "pad"

[[scratchpad]]
name = "other"
EOF
"$UMBRIEL" msg config-reload > /dev/null

field() {
  window_by_title "$1" | jq -r --arg key "$2" 'if .[$key] == null then "" else (.[$key] | tostring) end'
}

box() { window_by_title "$1" | jq -r '"\(.x) \(.y)"'; }

centre() {
  window_by_title "$1" | jq -r '"\((.x + .w / 2) | floor) \((.y + .h / 2) | floor)"'
}

require() {
  local actual
  actual=$(field "$1" "$2")
  if [[ $actual != "$3" ]]; then
    echo "$1: expected $2=$3, got '$actual': $("$UMBRIEL" windows --json)"
    exit 1
  fi
}

# The window actions a drag has to refuse. `msg` prints the handler's message and exits nonzero on refusal.
refused() {
  local output
  if output=$("$UMBRIEL" msg $1 2>&1); then
    echo "$1 was accepted while its window was being dragged: $output"
    exit 1
  fi
  if [[ $output != "$CLOSE_REASON" ]]; then
    echo "$1 failed for the wrong reason: $output"
    exit 1
  fi
}

spawn_window() {
  FILL_COLOR=0xFF00FF00 "$CLIENT" "$1" 300 200 > "$UMBRIEL_RUNTIME_DIR/$1.log" 2>&1 &
  await_window "$1"
  "$UMBRIEL" settle
}

# The pad takes the pointer while it is on screen, so the drag starts first and the pad opens or closes under it.
# The settle lets the compositor take the motion that turns the press into a drag, which is what makes the window
# carried.
start_drag() {
  pointer_hold 1280 720 mod logo move "$1" "$2" press "$BTN_LEFT" move "$3" "$4" -- release "$BTN_LEFT" mod none
  "$UMBRIEL" settle
}

# The drop point, computed from the pointer's travel and the grab offset the drag started with.
expect_at_drop() {
  local actual
  actual=$(box "$1")
  if [[ $actual != "$2" ]]; then
    echo "$1: expected the drop point $2, got $actual: $("$UMBRIEL" windows --json)"
    exit 1
  fi
}

# Outside a drag the same action must still work, so every refusal below is about the drag and not about the action.
spawn_window "$MEMBER"
"$UMBRIEL" msg window-focus "$(field "$MEMBER" id)" > /dev/null
"$UMBRIEL" msg window-move-to-scratchpad pad > /dev/null
"$UMBRIEL" msg scratchpad-toggle pad > /dev/null
"$UMBRIEL" settle
require "$MEMBER" scratchpad pad
"$UMBRIEL" msg window-restore-from-scratchpad pad > /dev/null
require "$MEMBER" scratchpad ""
require "$MEMBER" visible true

# Carry the member, then ask each window action to move it. None may touch it, and the release leaves it where it is.
# The pad the control left on screen is still showing, so the member returns to it without another toggle.
"$UMBRIEL" msg window-focus "$(field "$MEMBER" id)" > /dev/null
"$UMBRIEL" msg window-move-to-scratchpad pad > /dev/null
"$UMBRIEL" settle
require "$MEMBER" scratchpad pad
require "$MEMBER" visible true

read -r cx cy <<< "$(centre "$MEMBER")"
start_drag "$cx" "$cy" $((cx + 80)) $((cy + 60))
before=$(box "$MEMBER")
for action in "window-restore-from-scratchpad pad" "window-toggle-scratchpad pad" "window-move-to-scratchpad pad" \
  "window-restore-from-scratchpad other" "window-toggle-scratchpad other" "window-move-to-scratchpad other" \
  "window-move-to-workspace 2"; do
  refused "$action"
  require "$MEMBER" scratchpad pad
  if [[ $(box "$MEMBER") != "$before" ]]; then
    echo "$action moved the dragged window: $before -> $(box "$MEMBER")"
    exit 1
  fi
done
# Pad-level actions stay available while a window is carried; only the window moves are refused.
"$UMBRIEL" msg scratchpad-focus-next pad > /dev/null
require "$MEMBER" scratchpad pad
pointer_release
"$UMBRIEL" settle
require "$MEMBER" scratchpad pad
expect_at_drop "$MEMBER" "$before"

# The same refusal for a window on the workspace: it must not be reparented into the pad under the grab, which would
# leave it hidden in a pad that is not showing. A visible pad takes the pointer itself, so hide it first.
"$UMBRIEL" msg scratchpad-toggle pad > /dev/null
"$UMBRIEL" settle
spawn_window "$TILE"
read -r tx ty <<< "$(centre "$TILE")"
tile_workspace=$(field "$TILE" workspace)
start_drag "$tx" "$ty" $((tx + 80)) $((ty + 60))
refused "window-move-to-scratchpad pad"
require "$TILE" scratchpad ""
pointer_release
"$UMBRIEL" settle
require "$TILE" scratchpad ""
require "$TILE" workspace "$tile_workspace"
require "$TILE" visible true

# Closing the pad under a drag is allowed, and the member the pointer carries leaves with it instead of vanishing.
"$UMBRIEL" msg scratchpad-toggle pad > /dev/null
"$UMBRIEL" settle
require "$MEMBER" visible true
read -r cx cy <<< "$(centre "$MEMBER")"
start_drag "$cx" "$cy" $((cx + 80)) $((cy + 60))
"$UMBRIEL" msg scratchpad-toggle pad > /dev/null
# The hidden pad has no focused member left to name, so the carried window is still the target the actions must refuse.
refused "window-restore-from-scratchpad pad"
refused "window-toggle-scratchpad pad"
before=$(box "$MEMBER")
require "$MEMBER" scratchpad pad
require "$MEMBER" visible true
pointer_release
"$UMBRIEL" settle
require "$MEMBER" scratchpad ""
require "$MEMBER" visible true
if [[ $(field "$MEMBER" workspace) == "" ]]; then
  echo "the member left its pad without a workspace: $("$UMBRIEL" windows --json)"
  exit 1
fi
expect_at_drop "$MEMBER" "$before"

# The mirror direction: opening the pad under a drag adopts the window on release, so closing could not simply refuse.
read -r tx ty <<< "$(centre "$TILE")"
start_drag "$tx" "$ty" $((tx + 80)) $((ty + 60))
"$UMBRIEL" msg scratchpad-toggle pad > /dev/null
pointer_release
"$UMBRIEL" settle
require "$TILE" scratchpad pad
require "$TILE" visible true

# A pad showing one window at a time shows the window dropped onto it, instead of leaving its new member hidden.
"$UMBRIEL" msg window-focus "$(field "$MEMBER" id)" > /dev/null
"$UMBRIEL" msg window-move-to-scratchpad pad > /dev/null
"$UMBRIEL" settle
require "$MEMBER" scratchpad pad
"$UMBRIEL" msg scratchpad-toggle pad > /dev/null
"$UMBRIEL" settle
spawn_window "$SOLO"
read -r sx sy <<< "$(centre "$SOLO")"
start_drag "$sx" "$sy" $((sx + 80)) $((sy + 60))
"$UMBRIEL" msg scratchpad-toggle pad > /dev/null
"$UMBRIEL" msg scratchpad-window-show-next pad > /dev/null
pointer_release
"$UMBRIEL" settle
require "$SOLO" scratchpad pad
require "$SOLO" visible true

echo "a dragged window refused the scratchpad window actions, stayed put until release, and the pad's own close and"
echo "open decided its membership symmetrically; a dropped window became the one its solo pad shows"
