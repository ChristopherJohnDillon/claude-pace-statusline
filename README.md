# claude-pace-statusline

A [Claude Code](https://code.claude.com/docs) status line that shows your usage **against the clock**.

![The status line in Claude Code](assets/statusline.png)

## Why

Claude Code can tell you "24% used". On its own that number means nothing — 24% is
alarming three hours into a week and excellent six days in. What you actually want to
know is whether you're spending faster than time is passing.

So this prints both:

```
5h 20%/45% (2h44m) │ 7d 25%/21% (5d12h) │ Opus 5
   │   │     └ time until this window resets
   │   └ percent of the window elapsed
   └ percent of the quota spent
```

Read the pair as a pace. `20%/45%` means a fifth of the five-hour quota is gone and
nearly half the window has passed — comfortable. `25%/21%` means you're spending
slightly faster than the week is elapsing.

The usage number is colored by that comparison, so you don't have to do the arithmetic:

| Color | Meaning |
|-------|---------|
| green | at or below pace |
| orange | ahead of pace |
| red | more than 10 points ahead — on track to run out early |

## Install

Requires `bash` and [`jq`](https://jqlang.github.io/jq/).

```bash
git clone https://github.com/ChristopherJohnDillon/claude-pace-statusline.git
cd claude-pace-statusline
./install.sh
```

The installer copies the script to `~/.claude/statusline-pace.sh`, backs up
`~/.claude/settings.json`, and points `statusLine` at it. Restart Claude Code to see it.

If you already have a status line configured, the installer stops and shows you what's
there rather than overwriting it. Pass `--force` to replace it anyway (you still get a
backup).

### Manual install

Copy `statusline-pace.sh` anywhere you like and add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash /path/to/statusline-pace.sh"
  }
}
```

### Uninstall

```bash
./install.sh --uninstall
```

## Configuration

Set these in the `command` itself (e.g. `PACE_ALERT=5 bash ~/.claude/statusline-pace.sh`):

| Variable | Default | Effect |
|----------|---------|--------|
| `PACE_WARN` | `0` | Points over pace before the number turns orange |
| `PACE_ALERT` | `10` | Points over pace before it turns red |
| `PACE_FLOOR` | `5` | Usage below this percent always reads green — in the first minutes of a window everything is technically "ahead of pace", and that's noise |
| `NO_COLOR` | unset | Set to anything to disable color |

## How it works

Claude Code pipes a JSON payload to the status line command on stdin. This script reads
`.rate_limits.five_hour` and `.rate_limits.seven_day`, each of which carries a
`used_percentage` and a `resets_at` timestamp. The elapsed percentage is derived from
`resets_at` minus the window length — 5 hours (18000s) and 7 days (604800s) respectively.

If the payload reports no rate limits — as with API-key, Bedrock, and Vertex usage —
those segments are simply omitted and you get the model name alone.

## Development

`tests/samples.sh` renders the status line against fixture payloads (under pace, ahead of
pace, window just reset, no rate limits, and so on) so you can see the effect of a change:

```bash
./tests/samples.sh
```

## License

MIT
