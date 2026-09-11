#!/usr/bin/env bash
# Installs claude-pace-statusline as your Claude Code status line.
#
#   ./install.sh              install (refuses to replace a different status line)
#   ./install.sh --force      install, replacing whatever status line is configured
#   ./install.sh --uninstall  remove the status line setting and the installed script
#
# Your settings.json is backed up before any change.
set -euo pipefail

CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
SETTINGS="$CLAUDE_DIR/settings.json"
TARGET="$CLAUDE_DIR/statusline-pace.sh"
SOURCE="$(cd "$(dirname "$0")" && pwd)/statusline-pace.sh"
COMMAND="bash $TARGET"

force=0
uninstall=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --uninstall) uninstall=1 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "error: jq is required (brew install jq)" >&2; exit 1; }

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
  existing=$(jq -r '.statusLine.command // empty' "$SETTINGS")
  if [ -n "$existing" ] && [ "$existing" != "$COMMAND" ] && [ "$force" != 1 ]; then
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
