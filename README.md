# Claude Code Skills

A collection of custom skills for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Each skill adds a slash command that extends Claude's capabilities in your terminal.

## Quick Install

Run this from the root of any project where you want to use a skill:

```bash
curl -fsSL https://raw.githubusercontent.com/AngelMaldonado/skills/main/install.sh | bash -s -- <skill-name>
```

That's it. The skill is ready to use as `/<skill-name>` in Claude Code.

## Installer Options

```
./install.sh <skill-name>             # Install to current project (.claude/skills/)
./install.sh <skill-name> --global    # Install to ~/.claude/skills/ (all projects)
./install.sh <skill-name> --force     # Overwrite without prompting
./install.sh --list                   # List available skills
./install.sh --help                   # Show help
```

### Prerequisites

- `curl`
- `node` (v18+)

## Available Skills

### log-debugger

Real-time log file watcher with pattern matching. Tails a log file and stops when a target string is found or a timeout expires.

**Install:**

```bash
curl -fsSL https://raw.githubusercontent.com/AngelMaldonado/skills/main/install.sh | bash -s -- log-debugger
```

**Use in Claude Code:**

```
/log-debugger /var/log/app.log ERROR
```

Or just describe what you need — Claude will figure out the flags:

- *"watch the server log for any 5xx status codes"*
- *"tail deploy.log until it says 'ready', wait up to 2 minutes"*
- *"find the last 3 warnings in app.log with context"*

**Features:**

| Feature | Description |
|---------|-------------|
| Pattern matching | Literal strings or full regex (`--regex`) |
| Multiple patterns | Watch for several patterns at once (`--multi-match`) |
| Context lines | Show lines before/after matches, like `grep -C` |
| Timeout | Auto-exit after N seconds (default: 30s) |
| Match count | Stop after N matches or run unlimited |
| JSON output | Structured results for programmatic use |
| Case insensitive | Optional case-insensitive matching |
| Log rotation | Handles file truncation automatically |
| Highlighting | Highlight matched text in output |
| Timestamps | Prefix lines with wall-clock time |
| Stats | Summary of lines scanned, bytes read, elapsed time |

**Standalone usage** (without Claude Code):

```bash
# Watch for ERROR with 3 lines of context, 60s timeout
node .claude/skills/log-debugger/log-watcher.js \
  -f /var/log/app.log -m "ERROR" -C 3 -t 60

# Regex: catch 4xx/5xx HTTP status codes, case insensitive
node .claude/skills/log-debugger/log-watcher.js \
  -f server.log -m "status:\s*(4\d{2}|5\d{2})" -r -i --json

# Watch for multiple error patterns
node .claude/skills/log-debugger/log-watcher.js \
  -f app.log --multi-match "ERROR,FATAL,panic" -t 120

# Find 5 occurrences from start of file with highlights
node .claude/skills/log-debugger/log-watcher.js \
  -f debug.log -m "timeout" --from-start -n 5 --highlight
```

**Exit codes:** `0` match found, `1` timeout, `2` error.

## Project vs Global Install

| Flag | Location | Scope |
|------|----------|-------|
| *(default)* | `.claude/skills/<name>/` | Current project only |
| `--global` | `~/.claude/skills/<name>/` | All projects on your machine |

Project installs are ideal when you want the skill checked into version control so your team gets it too. Global installs are for personal utilities you want everywhere.

## Uninstall

Remove the skill directory:

```bash
# Project
rm -rf .claude/skills/<skill-name>

# Global
rm -rf ~/.claude/skills/<skill-name>
```

## Contributing

Each skill is a directory at the repo root containing:

```
<skill-name>/
├── SKILL.md          # Skill definition (required)
└── ...               # Supporting scripts, configs, etc.
```

`SKILL.md` uses YAML frontmatter for metadata and markdown for instructions. See the [Claude Code skills docs](https://docs.anthropic.com/en/docs/claude-code/skills) for the full spec.

## License

MIT
