#!/usr/bin/env bash
# Renders the status line against fixture payloads so changes can be eyeballed.
# Usage: tests/samples.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../statusline-pace.sh"
now=$(date +%s)

render() {
  local desc=$1 payload=$2
  printf '%-34s ' "$desc"
  printf '%s' "$payload" | bash "$script"
  printf '\n'
}

payload() {
  # $1 5h used, $2 5h seconds until reset, $3 7d used, $4 7d seconds until reset
  printf '{"model":{"display_name":"Opus 5"},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' \
    "$1" "$((now + $2))" "$3" "$((now + $4))"
}

echo
echo "  description                        rendered status line"
echo "  ------------------------------------------------------------------------"
render "under pace (green)"        "$(payload 3.2 7200 24 180000)"
render "at pace (green)"           "$(payload 60 7200 70 181440)"
render "just ahead of pace (orange)" "$(payload 45 9000 55 302400)"
render "well ahead of pace (red)"  "$(payload 90 14400 60 500000)"
render "window just reset"         "$(payload 0 17999 1 604700)"
render "window about to reset"     "$(payload 96 60 88 3600)"
render "no rate limits reported" \
  '{"model":{"display_name":"Sonnet 5"}}'
render "rate limits, no model" \
  "$(payload 50 7200 50 302400 | jq 'del(.model)')"
echo
echo "  thresholds: PACE_WARN=${PACE_WARN:-0} PACE_ALERT=${PACE_ALERT:-10}"
echo
