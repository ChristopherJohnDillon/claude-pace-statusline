#!/usr/bin/env bash
# Installs claude-pace-statusline as your Claude Code status line.
#
#   ./install.sh              install (refuses to replace a different status line)
#   ./install.sh --force      install, replacing whatever status line is configured
#   ./install.sh --uninstall  remove the status line setting and the installed script
#
# On a terminal it asks two questions, defaulting to your current settings. To
# skip them — piping from curl does so automatically — pass answers instead:
#
#   ./install.sh --yes            accept the defaults without asking
#   ./install.sh --plan 100       monthly plan cost for the "× plan" comparison
#   ./install.sh --no-tokens      install without the token odometer
#
# Your settings.json is backed up before any change.
set -euo pipefail

CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
SETTINGS="$CLAUDE_DIR/settings.json"
TARGET="$CLAUDE_DIR/statusline-pace.sh"
SOURCE="$(cd "$(dirname "$0")" && pwd)/statusline-pace.sh"
force=0
uninstall=0
assume_yes=0
plan=""
tokens=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) force=1 ;;
    --uninstall) uninstall=1 ;;
    --yes|-y) assume_yes=1 ;;
    --no-tokens) tokens=0 ;;
    --tokens) tokens=1 ;;
    --plan) shift; plan=${1:-}; [ -n "$plan" ] || { echo "--plan needs a number" >&2; exit 2; } ;;
    --plan=*) plan=${1#*=} ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "error: jq is required (brew install jq)" >&2; exit 1; }

# Whatever is configured now, so re-running the installer offers your current
# answers rather than resetting them
current=""
[ -f "$SETTINGS" ] && current=$(jq -r '.statusLine.command // empty' "$SETTINGS")
ours=0
case "$current" in *"$TARGET"*) ours=1 ;; esac

default_plan=200
default_tokens=1
if [ "$ours" = 1 ]; then
  case "$current" in
    *PACE_TOKENS=0*) default_tokens=0 ;;
  esac
  case "$current" in
    *PACE_PLAN=*) default_plan=$(printf '%s' "$current" | sed -n 's/.*PACE_PLAN=\([0-9.]*\).*/\1/p') ;;
  esac
  [ -n "$default_plan" ] || default_plan=200
fi

# Questions are for people at a terminal. Piped from curl, or run from a script,
# the defaults stand and nothing blocks.
interactive=0
[ -t 0 ] && [ "$assume_yes" != 1 ] && [ "$uninstall" != 1 ] && interactive=1

ask_yes_no() {
  local prompt=$1 default=$2 reply
  if [ "$default" = 1 ]; then prompt="$prompt [Y/n] "; else prompt="$prompt [y/N] "; fi
  read -r -p "$prompt" reply || return 0
  case "$reply" in
    [Yy]*) printf 1 ;;
    [Nn]*) printf 0 ;;
    *) printf '%s' "$default" ;;
  esac
}

ask_value() {
  local prompt=$1 default=$2 reply
  read -r -p "$prompt [$default] " reply || return 0
  # Anything that is not a plain number falls back rather than corrupting the command
  case "$reply" in
    "") printf '%s' "$default" ;;
    *[!0-9.]*) printf '%s' "$default" ;;
    *) printf '%s' "$reply" ;;
  esac
}

if [ "$interactive" = 1 ]; then
  echo
  [ -n "$tokens" ] || tokens=$(ask_yes_no "show the token odometer (⚡ 15.6B ≈ \$11.8k)?" "$default_tokens")
  if [ "$tokens" = 1 ] && [ -z "$plan" ]; then
    plan=$(ask_value "monthly plan cost, for the × plan comparison?" "$default_plan")
  fi
  echo
fi
[ -n "$tokens" ] || tokens=$default_tokens
[ -n "$plan" ] || plan=$default_plan

# Answers ride along as an environment prefix, so there is no second config file
# to keep in step with settings.json
# Both are recorded independently, so switching the odometer off and back on
# does not forget what you said the plan costs
prefix=""
[ "$tokens" = 0 ] && prefix="PACE_TOKENS=0 "
[ "$plan" != 200 ] && prefix="${prefix}PACE_PLAN=$plan "
COMMAND="${prefix}bash $TARGET"

backup() {
  if [ -f "$SETTINGS" ]; then
    local stamp
    stamp=$(date +%Y%m%d-%H%M%S)
    cp "$SETTINGS" "$SETTINGS.bak-$stamp"
    echo "backed up $SETTINGS -> $SETTINGS.bak-$stamp"
  fi
}

# Rewrites settings.json through jq, creating it if absent. All arguments are
# passed to jq, so callers can use --arg alongside the filter.
write_settings() {
  local tmp
  tmp=$(mktemp)
  if [ -f "$SETTINGS" ]; then
    jq "$@" "$SETTINGS" > "$tmp"
  else
    echo '{}' | jq "$@" > "$tmp"
  fi
  mv "$tmp" "$SETTINGS"
}

mkdir -p "$CLAUDE_DIR"

if [ "$uninstall" = 1 ]; then
  backup
  write_settings 'del(.statusLine)'
  rm -f "$TARGET"
  echo "removed the status line setting and $TARGET"
  echo "restart Claude Code (or run /statusline) to see the change"
  exit 0
fi

# Never clobber somebody else's status line without being told to
if [ -f "$SETTINGS" ]; then
  existing=$current
  if [ -n "$existing" ] && [ "$ours" != 1 ] && [ "$force" != 1 ]; then
    echo "a different status line is already configured:" >&2
    echo "    $existing" >&2
    echo "re-run with --force to replace it (a backup is still written)" >&2
    exit 1
  fi
fi

install -m 0755 "$SOURCE" "$TARGET"
echo "installed $TARGET"
backup
write_settings --arg cmd "$COMMAND" '.statusLine = {type: "command", command: $cmd}'
echo "set .statusLine in $SETTINGS"

# The odometer's first scan reads every transcript, which takes seconds. Doing it
# now, detached, means the first prompt after a restart already has a number.
if [ -d "$CLAUDE_DIR/projects" ]; then
  echo "warming the token odometer cache in the background"
  ("$TARGET" --refresh >/dev/null 2>&1 </dev/null &) >/dev/null 2>&1
fi

now=$(date +%s)
sample=$(printf '{"model":{"display_name":"Opus 5"},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":%s},"seven_day":{"used_percentage":24,"resets_at":%s}}}' \
  "$((now + 10800))" "$((now + 181440))")
echo
echo "sample render:"
printf '    '
printf '%s' "$sample" | bash "$TARGET"
echo
echo
echo "reads as: quota spent / window elapsed (time to reset)"
echo "restart Claude Code to pick it up"
