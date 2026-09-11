#!/usr/bin/env bash
# Renders the status line against fixture payloads so changes can be eyeballed.
# Usage: tests/samples.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../statusline-pace.sh"
now=$(date +%s)

fixture=$(mktemp -d "${TMPDIR:-/tmp}/pace-fixture.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
transcripts="$fixture/projects/demo"
cache="$fixture/cache.tsv"
mkdir -p "$transcripts"

# Deterministic stand-in for ~/.claude/projects. The counts are round so the
# rendered figures can be checked by hand: 10.8B tokens, and at the standard
# Opus rates (5 / 25 / 6.25 / 10 / 0.5 per MTok) exactly $14,000.
usage() {
  printf '{"message":{"usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation":{"ephemeral_5m_input_tokens":%s,"ephemeral_1h_input_tokens":%s},"cache_read_input_tokens":%s}}}\n' "$@"
}
{
  usage 100000000 200000000 400000000 100000000 10000000000
  usage 0 0 0 0 0
  # A half-written final line, as a live session always has. It must be ignored
  # rather than counted or crashed on, and must not advance the byte offset.
  printf '{"message":{"usage":{"input_tokens":999999999,"outp'
} > "$transcripts/session.jsonl"

# A month ago, so the plan multiple has a span to divide by
touch -t "$(date -v-31d '+%Y%m%d%H%M' 2>/dev/null || date -d '31 days ago' '+%Y%m%d%H%M')" \
  "$transcripts/session.jsonl" 2>/dev/null
PACE_TOKENS_DIR="$fixture/projects" PACE_CACHE="$cache" bash "$script" --refresh

# The pace samples are about the rate-limit segments, so the odometer is off for
# those; it gets its own section below.
render() {
  local desc=$1 payload=$2
  shift 2
  printf '%-34s ' "$desc"
  printf '%s' "$payload" | env PACE_TOKENS=0 PACE_TOKENS_DIR=/nonexistent "$@" bash "$script"
  printf '\n'
}

render_tokens() {
  local desc=$1
  shift
  printf '%-34s ' "$desc"
  printf '%s' "$(payload 20 9840 25 475200)" \
    | env PACE_TOKENS_DIR="$fixture/projects" PACE_CACHE="$cache" "$@" bash "$script"
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
echo "  odometer (fixture: 10.8B tokens = \$14,000 over ~1 month)"
echo "  ------------------------------------------------------------------------"
render_tokens "default"                  X=1
render_tokens "PACE_COST=0"              PACE_COST=0
render_tokens "PACE_PLAN=0"              PACE_PLAN=0
render_tokens "PACE_PLAN=500"            PACE_PLAN=500
render_tokens "PACE_TOKENS=0"            PACE_TOKENS=0
render_tokens "no color"                 NO_COLOR=1
printf '%-34s ' "cache absent (cold start)"
printf '%s' "$(payload 20 9840 25 475200)" \
  | env PACE_CACHE="$fixture/missing.tsv" PACE_TOKENS_DIR=/nonexistent bash "$script"
printf '\n'
echo
echo "  thresholds: PACE_WARN=${PACE_WARN:-0} PACE_ALERT=${PACE_ALERT:-10}"
echo
