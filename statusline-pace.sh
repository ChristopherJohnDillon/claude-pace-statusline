#!/usr/bin/env bash
# claude-pace-statusline — a Claude Code status line that shows usage against the clock.
#
# Claude Code reports quota as "24% used". On its own that number means nothing: 24%
# is alarming three hours into a week and excellent six days in. This prints how far
# through each window you are next to it, so the pair reads as a pace:
#
#   5h 12%/40% (3h0m) │ 7d 24%/70% (2d2h) │ Opus 5
#      │   │     └ time until this window resets
#      │   └ percent of the window elapsed
#      └ percent of the quota spent
#
# Colors compare the two: green at or under pace, orange ahead, red well ahead.
#
# Config (environment):
#   PACE_WARN    points over pace before the number turns orange   (default 0)
#   PACE_ALERT   points over pace before it turns red              (default 10)
#   PACE_FLOOR   usage below this percent always reads green        (default 5)
#   NO_COLOR     set to any value to disable color entirely
#
# License: MIT

set -uo pipefail

input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  printf 'statusline-pace: jq not found'
  exit 0
fi

PACE_WARN=${PACE_WARN:-0}
PACE_ALERT=${PACE_ALERT:-10}
PACE_FLOOR=${PACE_FLOOR:-5}

model=$(jq -r '.model.display_name // empty' <<<"$input")

five_used=$(jq -r '.rate_limits.five_hour.used_percentage // empty' <<<"$input")
five_resets=$(jq -r '.rate_limits.five_hour.resets_at // empty' <<<"$input")
week_used=$(jq -r '.rate_limits.seven_day.used_percentage // empty' <<<"$input")
week_resets=$(jq -r '.rate_limits.seven_day.resets_at // empty' <<<"$input")

now=$(date +%s)

# Window lengths, matching the field names Claude Code reports
FIVE_WINDOW=18000
WEEK_WINDOW=604800

if [ -n "${NO_COLOR:-}" ]; then
  RESET=""; GRAY=""; ORANGE=""; RED=""; GREEN=""
else
  RESET="\033[0m"
  GRAY="\033[90m"
  ORANGE="\033[38;2;255;79;0m"
  RED="\033[38;2;225;60;60m"
  GREEN="\033[38;2;120;200;120m"
fi

SEP="${GRAY} │ ${RESET}"

# Seconds remaining until an epoch timestamp, floored at zero
secs_until() {
  local target=$1
  local left=$((target - now))
  if [ "$left" -lt 0 ]; then left=0; fi
  printf '%s' "$left"
}

# Percent of a window already elapsed, from the seconds still left in it
pace_pct() {
  local left=$1 window=$2
  local elapsed=$((window - left))
  if [ "$elapsed" -lt 0 ]; then elapsed=0; fi
  if [ "$elapsed" -gt "$window" ]; then elapsed=$window; fi
  printf '%s' $((elapsed * 100 / window))
}

# Green at or under pace, orange ahead of it, red well ahead
pace_color() {
  local used=$1 pace=$2
  # Minutes into a window everything is "ahead of pace"; below the floor that is noise
  if [ "$used" -lt "$PACE_FLOOR" ]; then
    printf '%s' "$GREEN"
  elif [ "$used" -gt $((pace + PACE_ALERT)) ]; then
    printf '%s' "$RED"
  elif [ "$used" -gt $((pace + PACE_WARN)) ]; then
    printf '%s' "$ORANGE"
  else
    printf '%s' "$GREEN"
  fi
}

# Compact duration: hours+minutes under a day, days+hours above
fmt_short() {
  local left=$1
  local hrs=$((left / 3600)) mins=$(((left % 3600) / 60))
  if [ "$hrs" -gt 0 ]; then printf '%sh%sm' "$hrs" "$mins"; else printf '%sm' "$mins"; fi
}

fmt_long() {
  local left=$1
  local days=$((left / 86400)) hrs=$(((left % 86400) / 3600))
  if [ "$days" -gt 0 ]; then printf '%sd%sh' "$days" "$hrs"; else printf '%sh' "$hrs"; fi
}

# One window's segment: label, used%/pace%, and time to reset
segment() {
  local label=$1 used=$2 resets=$3 window=$4 fmt=$5
  local left pace color used_int
  left=$(secs_until "$resets")
  pace=$(pace_pct "$left" "$window")
  used_int=$(printf '%.0f' "$used")
  color=$(pace_color "$used_int" "$pace")
  printf '%s%s%s %s%s%%%s%s/%s%% (%s)%s' \
    "$GRAY" "$label" "$RESET" \
    "$color" "$used_int" "$RESET" \
    "$GRAY" "$pace" "$($fmt "$left")" "$RESET"
}

# Only windows the payload actually reported get a segment, so API-key and
# Bedrock users (who have no rate_limits at all) see the model alone
parts=()
if [ -n "$five_used" ] && [ -n "$five_resets" ]; then
  parts+=("$(segment 5h "$five_used" "$five_resets" "$FIVE_WINDOW" fmt_short)")
fi
if [ -n "$week_used" ] && [ -n "$week_resets" ]; then
  parts+=("$(segment 7d "$week_used" "$week_resets" "$WEEK_WINDOW" fmt_long)")
fi
if [ -n "$model" ]; then
  parts+=("${GRAY}${model}${RESET}")
fi

line=""
for part in ${parts+"${parts[@]}"}; do
  if [ -n "$line" ]; then line="${line}${SEP}"; fi
  line="${line}${part}"
done

printf '%b' "$line"
