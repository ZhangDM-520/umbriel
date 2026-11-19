#!/usr/bin/env bash
# harness: outputs=1
# harness: resize-trace=true
# The compositor must decide a pointer resize's box on the motion event, not wait for the client to redraw. This check
# drives paced floating sweeps against clients with different redraw latency and reads the compositor's own target box
# from the resize trace, so it pins the target half of the lag while the trace itself is exercised end to end.
#
# Three runs, one compositor:
#   instant   0 ms redraw delay: every step reaches a target within 2 px of the pointer.
#   slow      40 ms redraw delay: the target still tracks the pointer while configures are throttled.
#   no-redraw never redraws after map: the target still tracks the pointer.
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
  "instant:$target_instant" \
  "slow:$target_slow" \
  "pinned:$target_none"; do
  run=${pair%%:*}
  lag=${pair#*:}
  if awk -v lag="$lag" 'BEGIN { exit !(lag > 2) }'; then
    echo "$run: the compositor's target edge lagged the pointer by ${lag}px"
    exit 1
  fi
done

if ((steps < STEPS - 2)) || ((steps_none < STEPS - 2)); then
  echo "recorded $steps instant and $steps_none pinned resize steps of $STEPS; the trace is not wired to the pointer"
  exit 1
fi

# The floating grab throttles in-flight configures so a slow client is not flooded.
if ((configures_instant + 3 < steps)) || ((configures_slow * 2 > steps)) || ((configures_none > 3)); then
  echo "configure throttle: ${configures_instant} instant, ${configures_slow} slow, ${configures_none} pinned over ${steps} steps"
  exit 1
fi

echo "target lag px: instant ${target_instant}, slow ${target_slow}, pinned ${target_none}; configures ${configures_instant}/${configures_slow}/${configures_none} over ${steps} steps"
