#!/usr/bin/env bash
# harness: outputs=1
# harness: resize-trace=true
# A pointer resize must keep the drawn window edges aligned with the pointer at compositor frame cadence, even when the
# client is slow or stops redrawing, while still throttling in-flight floating configures and unlocking on a bufferless
# Wayland ack (such as cell-snapped terminals across sub-cell pointer moves).
#
# Five checks, one compositor:
#   instant      0 ms redraw delay: drawn and target lag stay at most 2 px, and settled commits appear in trace.
#   slow         40 ms redraw delay: drawn and target lag still stay at most 2 px, while configures are throttled.
#   no-redraw    never redraws after map: trace lag stays at most 2 px and held pixels match the dragged width.
#   stepped      RESIZE_STEP=50 client: bufferless ack on sub-step motion unlocks the next size configure while held, plus
#                pointer-resizing a floatingMaximized RESIZE_STEP=100 window drops maximize and settles to its snapped commit.
#   tiled_pinned two non-redrawing dwindle tiles plus a settling floating peer: growing tile fills its new slot with
#                zero uncovered backdrop gap, tiled trace steps match target, commits appear in trace, and the floating
#                peer adopts its 300px stepped commit rather than staying pinned at 320px by the held workspace drag.
set -euo pipefail
source "$UMBRIEL_HARNESS_LIB"

readonly TITLE=resize-lag
readonly PEER_TITLE=float-peer
readonly BTN_RIGHT=273
readonly OUTPUT_W=1280
readonly OUTPUT_H=720
readonly TRACE=${UMBRIEL_RESIZE_TRACE:?the harness must export UMBRIEL_RESIZE_TRACE}

readonly START_W=600
readonly START_H=400
readonly START_X=300
readonly START_Y=160
readonly EDGE_X=$((START_X + START_W))
readonly EDGE_Y=$((START_Y + START_H / 2))

# One step every 8 ms approximates a 120 Hz pointer; a burst would finish before any client could answer, and then
# every latency would configure identically.
readonly STEP_MS=8
readonly STEPS=12
readonly STEP_PX=10

write_config() {
  cat >> "$UMBRIEL_CONFIG" <<'EOF'

[colors]
backdrop = "#000000FF"

[layout]
mode = "dwindle"
gap = 0

[animation]
enabled = false

[appearance]
border_width = 0
outer_border_width = 0
corner_radius = 0

[appearance.title_bar]
mode = "off"

[appearance.shadow]
enabled = false

[[window_rule]]
match.title = "^resize-lag$"
default_floating = true
default_floating_size_px = { width = 600, height = 400 }
default_position = { x = 300, y = 160, anchor = "top_left" }

[[window_rule]]
match.title = "^float-peer$"
default_floating = true
default_floating_size_px = { width = 200, height = 100 }
default_position = { x = 40, y = 40, anchor = "top_left" }
EOF
  "$UMBRIEL" msg config-reload > /dev/null
}

await_mapped() {
  local actual=
  for _ in $(seq 100); do
    actual=$("$UMBRIEL" windows --json \
      | jq -r --arg title "$TITLE" '.[] | select(.title == $title) | "\(.w)x\(.h)+\(.x)+\(.y)"')
    [[ $actual == "${START_W}x${START_H}+${START_X}+${START_Y}" ]] && return 0
    sleep 0.05
  done
  echo "client never mapped at the expected box: got '$actual'"
  return 1
}

lines() { wc -l < "$TRACE" | tr -d ' '; }

# Worst absolute lag on either axis, over the steps recorded since line $1. `field` is drawn_lag or target_lag.
worst_lag() {
  jq -s --argjson from "$1" --arg field "$2" \
    '[.[$from:][] | select(.[$field] != null) | (.[$field][0] | fabs), (.[$field][1] | fabs)] | max // 0' "$TRACE"
}

steps_since() { jq -s --argjson from "$1" '[.[$from:][] | select(.drawn_lag != null)] | length' "$TRACE"; }

# Drives one resize of STEPS steps at STEP_MS pace, then reports the worst lags and trace event counts.
sweep() {
  local label=$1 redraw=$2 delay=$3 from drawn target steps configures commits pid
  local client_log="$UMBRIEL_RUNTIME_DIR/client-$label.log"
  local want_w=$((START_W + STEPS * STEP_PX))
  local pinned_fifo=
  local pinned_fd=
  if [[ $redraw == none ]]; then
    pinned_fifo="$UMBRIEL_RUNTIME_DIR/$label.fifo"
    mkfifo "$pinned_fifo"
    exec {pinned_fd}<>"$pinned_fifo"
    FILL_COLOR=0xFFFF0000 FOLLOW_CONFIGURES=1 RESIZE_ON_STDIN=1 \
      "$UMBRIEL_UNMAP_CLIENT" "$TITLE" "$START_W" "$START_H" <&"$pinned_fd" > "$client_log" 2>&1 &
  else
    FILL_COLOR=0xFFFF0000 FOLLOW_CONFIGURES=1 RESIZE_DELAY_MS="$delay" \
      "$UMBRIEL_UNMAP_CLIENT" "$TITLE" "$START_W" "$START_H" > "$client_log" 2>&1 &
  fi
  pid=$!
  await_mapped
  # A client that never answers leaves a configure outstanding, so `settle` would never return; the box wait above is
  # the only synchronisation those runs get.
  if [[ $redraw != none ]]; then
    "$UMBRIEL" settle > /dev/null
  fi
  from=$(lines)
  local -a moves=()
  for ((i = 1; i <= STEPS; i++)); do
    moves+=(pause "$STEP_MS" move $((EDGE_X + i * STEP_PX)) "$EDGE_Y")
  done
  pointer_hold "$OUTPUT_W" "$OUTPUT_H" move "$EDGE_X" "$EDGE_Y" mod logo press "$BTN_RIGHT" \
    "${moves[@]}" -- release "$BTN_RIGHT" mod none
  if [[ $redraw == none ]]; then
    local held_shot="$UMBRIEL_RUNTIME_DIR/pinned-held.png"
    local held_x=0 held_w=0
    for _ in $(seq 40); do
      grim "$held_shot"
      read -r held_x _ held_w _ < <("$UMBRIEL_PIXEL_PROBE" "$held_shot" bbox 'r > 0.8 && g < 0.2 && b < 0.2')
      if ((held_x >= START_X - 2 && held_x <= START_X + 2 && held_w >= want_w - 2 && held_w <= want_w + 2)); then
        break
      fi
      sleep 0.025
    done
    if ((held_x < START_X - 2 || held_x > START_X + 2 || held_w < want_w - 2 || held_w > want_w + 2)); then
      echo "pinned held frame was ${held_w}px at x=${held_x}, expected ${want_w}px at x=${START_X}" >&2
      exit 1
    fi
  fi
  pointer_release
  if [[ $redraw != none ]]; then
    "$UMBRIEL" settle > /dev/null
  else
    await_lines "$client_log" "resize-pending ${want_w}x${START_H}" 1 0.025
  fi
  steps=$(steps_since "$from")
  drawn=$(worst_lag "$from" drawn_lag)
  target=$(worst_lag "$from" target_lag)
  configures=$(jq -s --argjson from "$from" '[.[$from:][] | select(.event == "configure")] | length' "$TRACE")
  commits=$(jq -s --argjson from "$from" '[.[$from:][] | select(.event == "commit")] | length' "$TRACE")
  echo "${label} ${drawn} ${target} ${steps} ${configures} ${commits}"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if [[ -n $pinned_fd ]]; then
    exec {pinned_fd}<&-
  fi
  await_window_closed "$TITLE"
}

write_config

sweep_out=$(sweep instant "" 0)
read -r instant drawn_instant target_instant steps configures_instant commits_instant <<< "$sweep_out"
sweep_out=$(sweep slow "" 40)
read -r slow drawn_slow target_slow _ configures_slow commits_slow <<< "$sweep_out"
sweep_out=$(sweep pinned none 0)
read -r pinned drawn_none target_none steps_none configures_none _ <<< "$sweep_out"

# Both target and drawn boxes must track the pointer in every run, regardless of client redraw latency.
for pair in \
  "instant:target:$target_instant" "instant:drawn:$drawn_instant" \
  "slow:target:$target_slow" "slow:drawn:$drawn_slow" \
  "pinned:target:$target_none" "pinned:drawn:$drawn_none"; do
  run=${pair%%:*}
  rest=${pair#*:}
  kind=${rest%%:*}
  lag=${rest#*:}
  if awk -v lag="$lag" 'BEGIN { exit !(lag > 2) }'; then
    echo "$run: the compositor's ${kind} edge lagged the pointer by ${lag}px"
    exit 1
  fi
done

if ((steps < STEPS - 2)) || ((steps_none < STEPS - 2)); then
  echo "recorded $steps instant and $steps_none pinned resize steps of $STEPS; the trace is not wired to the pointer"
  exit 1
fi

# The floating grab still throttles in-flight configures so slow clients are not flooded.
if ((configures_instant + 3 < steps)) || ((configures_slow * 2 > steps)) || ((configures_none > 3)); then
  echo "configure throttle: ${configures_instant} instant, ${configures_slow} slow, ${configures_none} pinned over ${steps} steps"
  exit 1
fi

if ((commits_instant < 1)) || ((commits_slow < 1)); then
  echo "resize trace omitted client commit events: instant=${commits_instant} slow=${commits_slow}"
  exit 1
fi

# A sub-step move on a cell-snapped client commits an ack_configure without attaching a new buffer. That ack must still
# release the active-drag throttle so the next step crossing a cell boundary reaches the client before release.
readonly STEP_LOG="$UMBRIEL_RUNTIME_DIR/client-stepped.log"
FILL_COLOR=0xFFFF0000 FOLLOW_CONFIGURES=1 RESIZE_STEP=50 LOG_RESIZES=1 \
  "$UMBRIEL_UNMAP_CLIENT" "$TITLE" "$START_W" "$START_H" > "$STEP_LOG" 2>&1 &
step_pid=$!
await_mapped
"$UMBRIEL" settle > /dev/null
pointer_hold "$OUTPUT_W" "$OUTPUT_H" move "$EDGE_X" "$EDGE_Y" mod logo press "$BTN_RIGHT" \
  pause 10 move $((EDGE_X + 10)) "$EDGE_Y" \
  -- pause 10 move $((EDGE_X + 60)) "$EDGE_Y" mark stepped_grown hold release "$BTN_RIGHT" mod none
await_lines "$STEP_LOG" 'ack-same 600x400' 1 0.025
pointer_step stepped_grown
await_lines "$STEP_LOG" 'resized 650x400' 1 0.025
pointer_release
kill "$step_pid" 2>/dev/null || true
wait "$step_pid" 2>/dev/null || true
await_window_closed "$TITLE"

# Pointer-resizing a floatingMaximized window must clear maximize state so a client snapping its configure still retires
# pendingSize and drops the stretched crop after release.
readonly MAX_LOG="$UMBRIEL_RUNTIME_DIR/client-maximized.log"
FILL_COLOR=0xFFFF0000 FOLLOW_CONFIGURES=1 RESIZE_STEP=100 \
  "$UMBRIEL_UNMAP_CLIENT" "$TITLE" "$START_W" "$START_H" > "$MAX_LOG" 2>&1 &
max_pid=$!
await_mapped
"$UMBRIEL" settle > /dev/null
"$UMBRIEL" msg window-toggle-maximize > /dev/null
"$UMBRIEL" settle > /dev/null
read -r mx my mw mh max_before < <("$UMBRIEL" windows --json \
  | jq -r --arg title "$TITLE" '.[] | select(.title == $title) | "\(.x) \(.y) \(.w) \(.h) \(.maximized)"')
if [[ $max_before != true ]] || ((mw <= START_W)); then
  echo "maximize setup failed: box=${mw}x${mh}+${mx}+${my} maximized=${max_before}"
  exit 1
fi
max_before_shot="$UMBRIEL_RUNTIME_DIR/max-before.png"
grim "$max_before_shot"
read -r _ _ max_drawn_w _ < <("$UMBRIEL_PIXEL_PROBE" "$max_before_shot" bbox 'r > 0.8 && g < 0.2 && b < 0.2')
want_max_w=$(((max_drawn_w - 160) / 100 * 100))
"$UMBRIEL_POINTER_CLIENT" "$OUTPUT_W" "$OUTPUT_H" \
  move $((mx + mw - 10)) $((my + mh / 2)) mod logo press "$BTN_RIGHT" \
  move $((mx + mw - 170)) $((my + mh / 2)) release "$BTN_RIGHT" mod none
"$UMBRIEL" settle > /dev/null
max_shot="$UMBRIEL_RUNTIME_DIR/max-resized.png"
grim "$max_shot"
read -r _ _ max_w _ < <("$UMBRIEL_PIXEL_PROBE" "$max_shot" bbox 'r > 0.8 && g < 0.2 && b < 0.2')
max_after=$("$UMBRIEL" windows --json | jq -r --arg title "$TITLE" '.[] | select(.title == $title) | .maximized')
if ((max_w < want_max_w - 2 || max_w > want_max_w + 2)) || [[ $max_after != false ]]; then
  echo "floatingMaximized pointer resize stranded at ${max_w}px (want ${want_max_w}px), maximized=${max_after}"
  exit 1
fi
kill "$max_pid" 2>/dev/null || true
wait "$max_pid" 2>/dev/null || true
await_window_closed "$TITLE"

# Tiled non-redrawing drag + unrelated settling floating peer + post-arrange tiled trace + settled commit trace.
"$UMBRIEL" msg workspace-switch 2 > /dev/null
"$UMBRIEL" settle > /dev/null
readonly LEFT_LOG="$UMBRIEL_RUNTIME_DIR/tiled-left.log"
readonly RIGHT_LOG="$UMBRIEL_RUNTIME_DIR/tiled-right.log"
readonly PEER_LOG="$UMBRIEL_RUNTIME_DIR/float-peer.log"
left_fifo="$UMBRIEL_RUNTIME_DIR/tiled-left.fifo"
right_fifo="$UMBRIEL_RUNTIME_DIR/tiled-right.fifo"
peer_fifo="$UMBRIEL_RUNTIME_DIR/float-peer.fifo"
mkfifo "$left_fifo" "$right_fifo" "$peer_fifo"
exec {left_fd}<>"$left_fifo"
exec {right_fd}<>"$right_fifo"
exec {peer_fd}<>"$peer_fifo"
FILL_COLOR=0xFF00FF00 RESIZE_FILL_COLOR=0xFF00FF00 FOLLOW_CONFIGURES=1 RESIZE_ON_STDIN=1 \
  "$UMBRIEL_UNMAP_CLIENT" tiled-left 640 720 <&"$left_fd" > "$LEFT_LOG" 2>&1 &
left_pid=$!
await_window tiled-left
FILL_COLOR=0xFF0000FF RESIZE_FILL_COLOR=0xFF0000FF FOLLOW_CONFIGURES=1 RESIZE_ON_STDIN=1 \
  "$UMBRIEL_UNMAP_CLIENT" tiled-right 640 720 <&"$right_fd" > "$RIGHT_LOG" 2>&1 &
right_pid=$!
await_window tiled-right
await_lines "$LEFT_LOG" 'resize-pending 640x720' 1 0.025
echo r >&"$left_fd"
await_lines "$LEFT_LOG" 'resized 640x720' 1 0.025

# Launch a floating peer with an outstanding snapped configure (`320x100` -> `300x100`) before starting the tiled grab.
FILL_COLOR=0xFFFF00FF FOLLOW_CONFIGURES=1 RESIZE_ON_STDIN=1 RESIZE_STEP=50 \
  "$UMBRIEL_UNMAP_CLIENT" "$PEER_TITLE" 200 100 <&"$peer_fd" > "$PEER_LOG" 2>&1 &
peer_pid=$!
await_window "$PEER_TITLE"
"$UMBRIEL" settle > /dev/null
"$UMBRIEL" msg window-set-primary-extent 0.25 > /dev/null
await_lines "$PEER_LOG" 'resize-pending 320x100' 1 0.025

tiled_from=$(lines)
tiled_moves=()
for ((i = 1; i <= STEPS; i++)); do
  tiled_moves+=(pause "$STEP_MS" move $((620 + i * STEP_PX)) 360)
done
pointer_hold "$OUTPUT_W" "$OUTPUT_H" move 620 360 mod logo press "$BTN_RIGHT" \
  "${tiled_moves[@]}" -- release "$BTN_RIGHT" mod none

tiled_shot="$UMBRIEL_RUNTIME_DIR/tiled-held.png"
tiled_black=1
tiled_green_w=0
tiled_blue_x=0
for _ in $(seq 40); do
  grim "$tiled_shot"
  tiled_black=$("$UMBRIEL_PIXEL_PROBE" "$tiled_shot" count 'r < 0.05 && g < 0.05 && b < 0.05' 100x200+650+260)
  read -r _ _ tiled_green_w _ < <("$UMBRIEL_PIXEL_PROBE" "$tiled_shot" bbox 'g > 0.8 && r < 0.2 && b < 0.2')
  read -r tiled_blue_x _ _ _ < <("$UMBRIEL_PIXEL_PROBE" "$tiled_shot" bbox 'b > 0.8 && r < 0.2 && g < 0.2')
  if ((tiled_black == 0 && tiled_green_w >= 758 && tiled_green_w <= 762 && tiled_blue_x >= 758 && tiled_blue_x <= 762)); then
    break
  fi
  sleep 0.025
done
if ((tiled_black != 0 || tiled_green_w < 758 || tiled_green_w > 762 || tiled_blue_x < 758 || tiled_blue_x > 762)); then
  pointer_release
  echo "tiled non-redrawing resize lagged/gapped while held: black_gap=$tiled_black green_w=$tiled_green_w blue_x=$tiled_blue_x"
  exit 1
fi

# Answer the floating peer while the tiled workspace drag is still held: it must settle its own pending size rather than
# staying pinned at 320px by `isResizingWorkspace`.
echo r >&"$peer_fd"
await_lines "$PEER_LOG" 'resized 300x100' 1 0.025
pointer_release

await_lines "$LEFT_LOG" 'resize-pending 760x720' 1 0.025
await_lines "$RIGHT_LOG" 'resize-pending 520x720' 1 0.025
echo r >&"$left_fd"
echo r >&"$right_fd"
await_lines "$LEFT_LOG" 'resized 760x720' 1 0.025
await_lines "$RIGHT_LOG" 'resized 520x720' 1 0.025
"$UMBRIEL" settle > /dev/null

peer_shot="$UMBRIEL_RUNTIME_DIR/peer-settled.png"
grim "$peer_shot"
read -r _ _ peer_w _ < <("$UMBRIEL_PIXEL_PROBE" "$peer_shot" bbox 'r > 0.8 && g < 0.2 && b > 0.8')
if ((peer_w < 298 || peer_w > 302)); then
  echo "floating peer stayed at ${peer_w}px after committing 300x100 during a held tiled drag"
  exit 1
fi

tiled_steps=$(jq -s --argjson from "$tiled_from" '[.[$from:][] | select(.kind == "tiled" and .drawn_lag != null)] | length' "$TRACE")
tiled_mismatches=$(jq -s --argjson from "$tiled_from" \
  '[.[$from:][] | select(.kind == "tiled" and .drawn != null and (.drawn != .target or ((.drawn_lag[0] - 20) | fabs) > 2 or ((.target_lag[0] - 20) | fabs) > 2))] | length' "$TRACE")
tiled_max_w=$(jq -s --argjson from "$tiled_from" \
  '[.[$from:][] | select(.kind == "tiled" and .drawn != null) | .drawn[2]] | max // 0' "$TRACE")
if ((tiled_steps < 1)) || ((tiled_mismatches != 0)) || ((tiled_max_w < 758 || tiled_max_w > 762)); then
  echo "tiled resize trace failed post-arrange alignment: steps=${tiled_steps} mismatches=${tiled_mismatches} max_w=${tiled_max_w}"
  exit 1
fi

peer_commits=$(jq -s --argjson from "$tiled_from" \
  '[.[$from:][] | select(.event == "commit" and .committed == [300, 100])] | length' "$TRACE")
tiled_commits=$(jq -s --argjson from "$tiled_from" \
  '[.[$from:][] | select(.event == "commit" and .committed == [760, 720])] | length' "$TRACE")
if ((peer_commits < 1)) || ((tiled_commits < 1)); then
  echo "settled commits omitted from trace: peer=${peer_commits} tiled=${tiled_commits}"
  exit 1
fi

kill "$left_pid" "$right_pid" "$peer_pid" 2>/dev/null || true
wait "$left_pid" "$right_pid" "$peer_pid" 2>/dev/null || true
exec {left_fd}<&-
exec {right_fd}<&-
exec {peer_fd}<&-

echo "lag px (drawn/target): instant ${drawn_instant}/${target_instant}, slow ${drawn_slow}/${target_slow}, pinned ${drawn_none}/${target_none}; configures ${configures_instant}/${configures_slow}/${configures_none} over ${steps} steps; stepped ok; tiled ${tiled_steps} steps green_w=${tiled_green_w} blue_x=${tiled_blue_x} peer_w=${peer_w}"
