#!/usr/bin/env bash
# claude-pace-statusline — a Claude Code status line that shows usage against the clock.
#
# Claude Code reports quota as "24% used". On its own that number means nothing: 24%
# is alarming three hours into a week and excellent six days in. This prints how far
# through each window you are next to it, so the pair reads as a pace:
#
#   5h 12%/40% (3h0m) │ 7d 24%/70% (2d2h) │ ⚡ 15.5B ≈ $11.7k │ Opus 5
#      │   │     └ time until this window resets
#      │   └ percent of the window elapsed
#      └ percent of the quota spent
#
# Colors compare the two: green at or under pace, orange ahead, red well ahead.
#
# The ⚡ segment is an odometer: every token in every transcript under
# ~/.claude/projects, and what that would have cost at standard (non-batch)
# Opus API rates. It is read from a cache and refreshed in the background, so
# it never delays the prompt, and it costs no tokens of its own to display.
#
# Config (environment):
#   PACE_WARN    points over pace before the number turns orange   (default 0)
#   PACE_ALERT   points over pace before it turns red              (default 10)
#   PACE_FLOOR   usage below this percent always reads green        (default 5)
#   PACE_TOKENS  set to 0 to hide the token odometer               (default 1)
#   PACE_COST    set to 0 to show tokens without the dollar figure (default 1)
#   PACE_TOKENS_DIR   where transcripts live   (default ~/.claude/projects)
#   PACE_CACHE   odometer cache file      (default ~/.claude/.cache/pace-tokens.tsv)
#   NO_COLOR     set to any value to disable color entirely
#
# License: MIT

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  printf 'statusline-pace: jq not found'
  exit 0
fi

PACE_WARN=${PACE_WARN:-0}
PACE_ALERT=${PACE_ALERT:-10}
PACE_FLOOR=${PACE_FLOOR:-5}
PACE_TOKENS=${PACE_TOKENS:-1}
PACE_COST=${PACE_COST:-1}
PACE_TOKENS_DIR=${PACE_TOKENS_DIR:-$HOME/.claude/projects}
PACE_CACHE=${PACE_CACHE:-$HOME/.claude/.cache/pace-tokens.tsv}

# Standard-tier Opus rates, dollars per million tokens. Cache writes are 1.25x
# input at the 5-minute TTL and 2x at the one-hour TTL; cache reads are 0.1x.
# These are list prices for a non-batch API call — the odometer is a "what if",
# not a bill.
PACE_RATE_IN=${PACE_RATE_IN:-5}
PACE_RATE_OUT=${PACE_RATE_OUT:-25}
PACE_RATE_W5=${PACE_RATE_W5:-6.25}
PACE_RATE_W1=${PACE_RATE_W1:-10}
PACE_RATE_READ=${PACE_RATE_READ:-0.5}

# What the subscription costs per month. The odometer divides the API-equivalent
# spend over the span the transcripts actually cover to get a monthly rate, then
# compares. Set to 0 to drop the multiple.
PACE_PLAN=${PACE_PLAN:-200}

self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
PACE_SELF="${self_dir:-.}/$(basename "${BASH_SOURCE[0]}")"

# Portable file size: BSD stat on macOS, GNU stat elsewhere
if stat -f%z . >/dev/null 2>&1; then
  file_size() { stat -f%z "$1" 2>/dev/null; }
  list_sizes() { find "$1" -type f -name '*.jsonl' -print0 | xargs -0 stat -f '%z %m %N' 2>/dev/null; }
else
  file_size() { stat -c%s "$1" 2>/dev/null; }
  list_sizes() { find "$1" -type f -name '*.jsonl' -print0 | xargs -0 stat -c '%s %Y %n' 2>/dev/null; }
fi

# Sum the usage records in one transcript from byte $2 onward. Prints
# consumed-bytes and the five token counts, tab separated.
#
# A transcript is appended to while Claude Code is running, so the tail may be a
# half-written line. Only whole lines are counted, and the byte offset advances
# only over those, which leaves the fragment to be read once it is complete.
scan_transcript() {
  local f=$1 off=$2 chunk sz cut sums
  chunk=$(mktemp "${TMPDIR:-/tmp}/pace-chunk.XXXXXX") || return 1
  if [ "$off" -gt 0 ]; then
    tail -c "+$((off + 1))" "$f" >"$chunk" 2>/dev/null
  else
    cat "$f" >"$chunk" 2>/dev/null
  fi
  sz=$(file_size "$chunk")
  sz=${sz:-0}
  if [ "$sz" -gt 0 ] && [ -n "$(tail -c 1 "$chunk")" ]; then
    cut=$((sz - $(tail -n 1 "$chunk" | wc -c | tr -d ' ')))
  else
    cut=$sz
  fi
  if [ "$cut" -le 0 ]; then
    rm -f "$chunk"
    printf '0\t0\t0\t0\t0\t0'
    return 0
  fi
  sums=$(head -c "$cut" "$chunk" | jq -n -r '
    reduce (inputs | .message.usage? // empty) as $u ([0,0,0,0,0];
      ($u.cache_creation // null) as $cc
      # Older records carry only a flat cache_creation_input_tokens; bill those
      # at the 5-minute rate, which is the default TTL they were written under
      | (if $cc then ($cc.ephemeral_5m_input_tokens // 0)
         else ($u.cache_creation_input_tokens // 0) end) as $c5
      | (if $cc then ($cc.ephemeral_1h_input_tokens // 0) else 0 end) as $c1
      | [ .[0] + ($u.input_tokens // 0),
          .[1] + ($u.output_tokens // 0),
          .[2] + $c5,
          .[3] + $c1,
          .[4] + ($u.cache_read_input_tokens // 0) ])
    | @tsv') || { rm -f "$chunk"; return 1; }
  rm -f "$chunk"
  [ -n "$sums" ] || return 1
  printf '%s\t%s' "$cut" "$sums"
}

# Rebuild the odometer cache, reading only bytes that are new since last time.
# Runs detached from the status line, so its cost is never on the prompt's path.
refresh_cache() {
  [ -d "$PACE_TOKENS_DIR" ] || return 0
  local cache=$PACE_CACHE lock="${PACE_CACHE}.lock" listing plan keep
  mkdir -p "$(dirname "$cache")" 2>/dev/null || return 0
  # A lock younger than ten minutes means a refresh is genuinely in flight; an
  # older one was left by a process that died, and is cleared rather than obeyed
  if [ -d "$lock" ] && [ -z "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    return 0
  fi
  rmdir "$lock" 2>/dev/null
  mkdir "$lock" 2>/dev/null || return 0
  listing=$(mktemp "${TMPDIR:-/tmp}/pace-list.XXXXXX")
  plan=$(mktemp "${TMPDIR:-/tmp}/pace-plan.XXXXXX")
  keep=$(mktemp "${TMPDIR:-/tmp}/pace-keep.XXXXXX")
  # Expanded now, not at exit: these names are local and are gone by the time
  # the trap fires
  trap "rm -f '$listing' '$plan' '$keep'; rmdir '$lock' 2>/dev/null" EXIT
  # awk refuses to run at all if an input file is missing, and on the very first
  # refresh there is no cache yet
  [ -f "$cache" ] || : >"$cache"
  list_sizes "$PACE_TOKENS_DIR" >"$listing"
  [ -s "$listing" ] || return 0
  # Split the transcripts into those whose cached entry still stands and those
  # with bytes to read. A file shorter than its offset was truncated or replaced,
  # so it starts over at zero.
  awk -F'\t' -v OFS='\t' -v plan="$plan" -v keep="$keep" -v cachefile="$cache" '
    # Keyed on the filename rather than NR==FNR, which would misread the first
    # listing record as a cache record whenever the cache is empty
    FILENAME == cachefile {
      if (NF >= 7) { off[$1] = $2; i[$1] = $3; o[$1] = $4; w5[$1] = $5; w1[$1] = $6; r[$1] = $7 }
      next
    }
    {
      sp = index($0, " ")
      if (sp == 0) next
      size = substr($0, 1, sp - 1) + 0
      rest = substr($0, sp + 1)
      sp2 = index(rest, " ")
      if (sp2 == 0) next
      mtime = substr(rest, 1, sp2 - 1) + 0
      path = substr(rest, sp2 + 1)
      if (path in off && off[path] == size)
        print path, off[path], i[path], o[path], w5[path], w1[path], r[path], mtime >keep
      else if (path in off && off[path] < size)
        print path, off[path], i[path], o[path], w5[path], w1[path], r[path], mtime >plan
      else
        print path, 0, 0, 0, 0, 0, 0, mtime >plan
    }' "$cache" "$listing" 2>/dev/null
  while IFS=$'\t' read -r path off ti to tw5 tw1 tr mtime; do
    delta=$(scan_transcript "$path" "$off") || continue
    IFS=$'\t' read -r dc di do_ dw5 dw1 dr <<<"$delta"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$path" "$((off + dc))" \
      "$((ti + di))" "$((to + do_))" "$((tw5 + dw5))" "$((tw1 + dw1))" "$((tr + dr))" "$mtime" >>"$keep"
  done <"$plan"
  # Swapped in whole, so a reader never sees a half-written cache
  mv "$keep" "$cache" 2>/dev/null && chmod 644 "$cache" 2>/dev/null
  return 0
}

if [ "${1:-}" = "--refresh" ]; then
  refresh_cache
  exit 0
fi

input=$(cat)

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
  RESET=""; GRAY=""; ORANGE=""; RED=""; GREEN=""; AMBER=""
else
  RESET="\033[0m"
  GRAY="\033[90m"
  ORANGE="\033[38;2;255;79;0m"
  RED="\033[38;2;225;60;60m"
  GREEN="\033[38;2;120;200;120m"
  AMBER="\033[38;2;220;180;90m"
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

# The odometer, read from whatever the last background refresh left behind. No
# transcript is opened here — the whole point is that the prompt never waits.
tokens_segment() {
  [ "$PACE_TOKENS" != 0 ] || return 0
  [ -r "$PACE_CACHE" ] || return 0
  awk -F'\t' \
    -v rin="$PACE_RATE_IN" -v rout="$PACE_RATE_OUT" -v rw5="$PACE_RATE_W5" \
    -v rw1="$PACE_RATE_W1" -v rr="$PACE_RATE_READ" \
    -v showcost="$PACE_COST" -v plan="$PACE_PLAN" -v now="$now" \
    -v amber="$AMBER" -v gray="$GRAY" -v reset="$RESET" \
    -v bolt='⚡' -v approx='≈' -v dot='·' -v mult='×' '
    # Three significant figures, so the number stays the same width as it grows
    function sig(x) {
      if (x >= 100) return sprintf("%d", x + 0.5)
      if (x >= 10) return sprintf("%.1f", x)
      return sprintf("%.2f", x)
    }
    function hnum(n) {
      if (n >= 1e12) return sig(n / 1e12) "T"
      if (n >= 1e9) return sig(n / 1e9) "B"
      if (n >= 1e6) return sig(n / 1e6) "M"
      if (n >= 1e3) return sig(n / 1e3) "K"
      return sprintf("%d", n)
    }
    function money(d) {
      if (d >= 1e6) return "$" sig(d / 1e6) "M"
      if (d >= 1e3) return "$" sig(d / 1e3) "k"
      if (d >= 10) return sprintf("$%d", d + 0.5)
      return sprintf("$%.2f", d)
    }
    {
      i += $3; o += $4; w5 += $5; w1 += $6; r += $7
      m = $8 + 0
      if (m > 0 && (oldest == 0 || m < oldest)) oldest = m
    }
    END {
      total = i + o + w5 + w1 + r
      if (total <= 0) exit 1
      out = amber bolt " " hnum(total) reset
      if (showcost != 0) {
        dollars = (i * rin + o * rout + w5 * rw5 + w1 * rw1 + r * rr) / 1000000
        out = out gray " " approx " " money(dollars) reset
        # A multiple is only meaningful once there is enough history to divide by;
        # under a day of transcripts it would read as a wild extrapolation
        if (plan > 0 && oldest > 0) {
          days = (now - oldest) / 86400
          if (days >= 1) {
            monthly = dollars / (days / 30.44)
            if (monthly / plan >= 1.5) out = out gray " " dot " " sig(monthly / plan) mult " plan" reset
          }
        }
      }
      print out
    }' "$PACE_CACHE" 2>/dev/null
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
odometer=$(tokens_segment)
if [ -n "$odometer" ]; then
  parts+=("$odometer")
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

# The line is already on screen; the rescan happens behind it and lands in the
# cache for the next prompt to pick up
if [ "$PACE_TOKENS" != 0 ] && [ -d "$PACE_TOKENS_DIR" ]; then
  ("$PACE_SELF" --refresh >/dev/null 2>&1 </dev/null &) >/dev/null 2>&1
fi
