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
# Three files, because deduplicating and rendering want different shapes.
# .tsv  one line per transcript: how far into it we have read
# .idx  one line per unique message id: what that message cost
# .sum  a single line of totals, which is all the status line ever reads
PACE_IDX="${PACE_CACHE%.tsv}.idx"
PACE_SUM="${PACE_CACHE%.tsv}.sum"
CACHE_VERSION="#v2"

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

# Read one transcript from byte $2 onward, appending a record per assistant
# message to $3 as: id, input, output, 5m-write, 1h-write, read. Prints how many
# bytes were consumed.
#
# A transcript is appended to while Claude Code is running, so the tail may be a
# half-written line. Only whole lines are read, and the byte offset advances only
# over those, which leaves the fragment to be picked up once it is complete.
scan_transcript() {
  local f=$1 off=$2 out=$3 chunk sz cut
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
    printf 0
    return 0
  fi
  # Read as raw lines and parse each one on its own: a single corrupt line in a
  # transcript would otherwise fail the whole invocation, and since the byte
  # offset only advances on success, that file would never be read again
  head -c "$cut" "$chunk" | jq -n -R -r '
    inputs
    | (fromjson? // empty)
    | select((.message | type) == "object" and (.message.usage | type) == "object")
    | .message.usage as $u
    | ($u.cache_creation // null) as $cc
    # Older records carry only a flat cache_creation_input_tokens; bill those at
    # the 5-minute rate, which is the default TTL they were written under
    | [ (.message.id // ""),
        ($u.input_tokens // 0),
        ($u.output_tokens // 0),
        (if $cc then ($cc.ephemeral_5m_input_tokens // 0)
         else ($u.cache_creation_input_tokens // 0) end),
        (if $cc then ($cc.ephemeral_1h_input_tokens // 0) else 0 end),
        ($u.cache_read_input_tokens // 0) ]
    | @tsv' >>"$out" 2>/dev/null || { rm -f "$chunk"; return 1; }
  rm -f "$chunk"
  printf '%s' "$cut"
}

# Rebuild the odometer, reading only bytes that are new since last time.
# Runs detached from the status line, so its cost is never on the prompt's path.
#
# Deduplication is the whole reason this is not a simple per-file sum. Resuming a
# session copies the earlier conversation into the new transcript, so one
# assistant message can sit in a dozen files; counting files would count it a
# dozen times. Messages are therefore banked by id, and an id already known is
# skipped however many times it reappears.
refresh_cache() {
  [ -d "$PACE_TOKENS_DIR" ] || return 0
  local cache=$PACE_CACHE lock="${PACE_CACHE}.lock" listing plan keep records idx sum holder
  mkdir -p "$(dirname "$cache")" 2>/dev/null || return 0
  # Whoever holds the lock records their pid in it. A refresh that is killed
  # before its trap runs — a terminal closing on the first, slow scan is the
  # usual way — would otherwise leave a directory that blocks every later
  # refresh, so the holder is checked for being alive rather than merely recent.
  if ! mkdir "$lock" 2>/dev/null; then
    holder=$(cat "$lock/pid" 2>/dev/null)
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      return 0
    fi
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || return 0
  fi
  echo $$ >"$lock/pid" 2>/dev/null
  listing=$(mktemp "${TMPDIR:-/tmp}/pace-list.XXXXXX")
  plan=$(mktemp "${TMPDIR:-/tmp}/pace-plan.XXXXXX")
  keep=$(mktemp "${TMPDIR:-/tmp}/pace-keep.XXXXXX")
  records=$(mktemp "${TMPDIR:-/tmp}/pace-rec.XXXXXX")
  idx=$(mktemp "${TMPDIR:-/tmp}/pace-idx.XXXXXX")
  sum=$(mktemp "${TMPDIR:-/tmp}/pace-sum.XXXXXX")
  # Expanded now, not at exit: these names are local and are gone by the time
  # the trap fires
  trap "rm -f '$listing' '$plan' '$keep' '$records' '$idx' '$sum'; rm -rf '$lock'" EXIT

  # A cache written by an older version stored per-file sums and cannot be
  # migrated, since it never recorded which messages it had counted. Start over.
  if [ ! -f "$cache" ] || [ "$(head -n 1 "$cache" 2>/dev/null)" != "$CACHE_VERSION" ]; then
    printf '%s\n' "$CACHE_VERSION" >"$cache"
    : >"$PACE_IDX"
  fi
  [ -f "$PACE_IDX" ] || : >"$PACE_IDX"

  list_sizes "$PACE_TOKENS_DIR" >"$listing"
  [ -s "$listing" ] || return 0

  # Split the transcripts into those already read to the end and those with
  # bytes to read. A file shorter than its offset was truncated or replaced, so
  # it starts over at zero.
  printf '%s\n' "$CACHE_VERSION" >"$keep"
  awk -F'\t' -v OFS='\t' -v plan="$plan" -v keep="$keep" -v cachefile="$cache" '
    # Keyed on the filename rather than NR==FNR, which would misread the first
    # listing record as a cache record whenever the cache is empty
    FILENAME == cachefile { if (NF >= 3) off[$1] = $2; next }
    {
      sp = index($0, " ")
      if (sp == 0) next
      size = substr($0, 1, sp - 1) + 0
      rest = substr($0, sp + 1)
      sp2 = index(rest, " ")
      if (sp2 == 0) next
      mtime = substr(rest, 1, sp2 - 1) + 0
      path = substr(rest, sp2 + 1)
      if (path in off && off[path] == size) print path, off[path], mtime >>keep
      else if (path in off && off[path] < size) print path, off[path], mtime >plan
      else print path, 0, mtime >plan
    }' "$cache" "$listing" 2>/dev/null

  while IFS=$'\t' read -r path off mtime; do
    consumed=$(scan_transcript "$path" "$off" "$records") || continue
    printf '%s\t%s\t%s\n' "$path" "$((off + consumed))" "$mtime" >>"$keep"
  done <"$plan"

  # Bank the messages we have not seen before, then total the whole index. An id
  # is banked once and never revised, so a message counts exactly once no matter
  # how many transcripts ended up holding a copy of it.
  awk -F'\t' -v OFS='\t' -v idxfile="$PACE_IDX" '
    FILENAME == idxfile { seen[$1] = 1; print; next }
    {
      # A record without an id cannot be deduplicated, so it is always counted
      if ($1 != "" && ($1 in seen)) next
      if ($1 != "") seen[$1] = 1
      print
    }' "$PACE_IDX" "$records" >"$idx" 2>/dev/null

  awk -F'\t' '{ i += $2; o += $3; w5 += $4; w1 += $5; r += $6 }
    END { printf "%d\t%d\t%d\t%d\t%d\n", i, o, w5, w1, r }' "$idx" >"$sum" 2>/dev/null

  # The span the odometer covers. This cannot be read off the transcripts, because
  # Claude Code deletes them after cleanupPeriodDays (30 by default) while banked
  # message ids stay in the index forever. Taking the oldest file on disk would
  # pin the span at 30 days while the totals kept growing, inflating the monthly
  # rate without bound. So the earliest date ever observed is recorded once and
  # only ever moves backwards.
  local seen_before=0
  [ -r "$PACE_SUM" ] && seen_before=$(awk 'NR == 2 { print $1 + 0 }' "$PACE_SUM" 2>/dev/null)
  awk -F'\t' -v prev="${seen_before:-0}" '
    NR > 1 && $3 + 0 > 0 { m = $3 + 0; if (oldest == 0 || m < oldest) oldest = m }
    END {
      if (prev > 0 && (oldest == 0 || prev < oldest)) oldest = prev
      print oldest + 0
    }' "$keep" >>"$sum" 2>/dev/null

  # Swapped in whole, so a reader never sees a half-written cache
  mv "$idx" "$PACE_IDX" 2>/dev/null && chmod 644 "$PACE_IDX" 2>/dev/null
  mv "$sum" "$PACE_SUM" 2>/dev/null && chmod 644 "$PACE_SUM" 2>/dev/null
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

# The odometer, read from whatever the last background refresh left behind. Two
# lines of arithmetic regardless of how much history has accumulated — no
# transcript, and no message index, is opened on the prompt's path.
tokens_segment() {
  [ "$PACE_TOKENS" != 0 ] || return 0
  [ -r "$PACE_SUM" ] || return 0
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
    # Two lines: the totals, then the oldest transcript timestamp
    NR == 1 { i = $1; o = $2; w5 = $3; w1 = $4; r = $5 }
    NR == 2 { oldest = $1 + 0 }
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
    }' "$PACE_SUM" 2>/dev/null
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
