---
name: log-debugger
type: spec
---

## Overview

The log-debugger skill attaches to already-running processes and analyzes their live output without restarting them. It discovers available targets automatically and supports three capture backends: iTerm2 sessions (primary), tmux panes (fallback), and Docker containers. A file-based fallback mode is available for explicit log file watching.

## Trigger Conditions

Trigger conditions are evaluated in priority order:

1. Developer asks to debug, watch, or monitor a running process
2. Developer wants to see what a dev server, worker, or container is outputting
3. Developer asks to "attach to", "tail", or "watch" without specifying a file
4. Developer says "what's going wrong with X", "show me X's output", "watch X for errors"
5. Developer provides `--file <path>` explicitly — file fallback mode (skip discovery)

## Step Flow

1. If `--file` is provided, skip to file fallback mode: invoke `log-watcher.js` directly without running discovery
2. Run `process-discovery.sh` to receive a numbered JSON list of running targets across all available backends
3. Present the list to the developer; ask them to pick a target by number, name, or port
4. Based on the target's `type` field, invoke the matching capture script: `iterm-capture.py` (iterm2), `tmux-capture.sh` (tmux), or `docker-capture.sh` (docker)
5. Simultaneously invoke `iterm-pane.sh --cmd "tail -f <capture-file>"` to open a live display pane
6. When the capture session ends, run `node analyze-capture.js <capture-file>` to produce a diagnostic report
7. Present the analysis: root cause, error patterns, stack trace origins, and suggested next step

## Requirements

### Process Discovery

- The skill MUST enumerate running processes across three backends before requiring the developer to specify a target: iTerm2 sessions (via Python API), tmux panes (via `tmux list-panes`), and Docker containers (via `docker ps`)
- Discovery results MUST be presented as a numbered list including: target type, name/title, running command, and working directory or exposed ports
- The developer MUST be able to select a target by number, name, or port
- Each unavailable backend (docker not on PATH, no tmux sessions, iTerm2 API not reachable) MUST be skipped gracefully without failing discovery

### iTerm2 Capture (Primary Path)

- The skill MUST support attaching to an iTerm2 session and streaming its output without restarting the session
- `iterm-capture.py` MUST use the `iterm2` Python package's `ScreenStreamer` for continuous output subscription
- The script MUST detect when the iTerm2 Python API is not enabled and print actionable setup instructions (`Preferences → General → Magic → Enable Python API`)
- The script MUST detect when the `iterm2` package is not installed and print `pip3 install iterm2`
- A `--snapshot` flag MUST capture the current visible buffer and exit immediately without streaming

### tmux Capture (Fallback Path)

- The skill MUST support attaching to a tmux pane and capturing live output without stopping the process
- `tmux-capture.sh` MUST take an initial scrollback snapshot (`tmux capture-pane -p -S -1000`) before starting live streaming
- Live streaming MUST use `tmux pipe-pane` to redirect pane output to a temp file
- The script MUST check for an existing `pipe-pane` on the target and warn the developer rather than silently overriding it

### Docker Capture

- `docker-capture.sh` MUST seed the capture buffer with recent history (`docker logs --tail 100`) before streaming
- Live streaming MUST use `docker logs -f`
- For docker-compose projects, the script MUST accept `--cwd <path>` and, if not supplied, walk up from `$PWD` to locate `docker-compose.yml` or `compose.yml`

### Capture JSON Format

- All three capture backends MUST write output in the same JSON schema: `source`, `target`, `startedAt`, `endedAt`, `exitReason`, `matchedPattern`, `lines[]`, `matchedLines[]`
- `exitReason` MUST be one of: `sigint`, `pattern_match`, `timeout`, `source_gone`
- The rolling buffer MUST default to 500 lines and be configurable via `--buffer-size`

### Claude Analysis

- After any capture session ends, `analyze-capture.js` MUST produce a Claude-readable diagnostic report
- The report MUST include: detected errors and stack traces, repeated pattern clusters, stack frame origins (file + line), exit context, and whether the target process is still running
- The report MUST be bounded to approximately 50–100 lines

### iTerm2 Pane Display

- `iterm-pane.sh` MUST accept an arbitrary `--cmd <command-string>` to run in the pane; all capture scripts pass a `tail -f <capture-file>` command via this flag
- All split/tab/window/title options are preserved; when `--cmd` is supplied without `--title`, the first word of the command is used as the pane title
- When `--cmd` is not supplied, `iterm-pane.sh` falls back to running `node log-watcher.js` for backward compatibility

### File Fallback Mode

- When `--file <path>` is provided, the skill MUST skip discovery entirely and invoke `log-watcher.js` directly
- `log-watcher.js` is not modified; the file fallback path must remain fully backward-compatible with existing usage
- `--match <pattern>` is supported in file fallback mode and passed through to `log-watcher.js`

### Capture File Cleanup

- At the start of each invocation, stale capture files (`/tmp/cx-capture-*.json`, `/tmp/cx-tmux-*.log`) older than 24 hours MUST be deleted

## Options Reference

| Flag | Description |
|------|-------------|
| `--file <path>` | Skip discovery; watch a log file directly (uses log-watcher.js) |
| `--match <pattern>` | Stop capture when this pattern appears (all modes) |
| `--buffer-size <N>` | Rolling buffer line count (default: 500) |
| `--snapshot` | Capture current screen buffer and exit immediately (iTerm2 only) |
| `--split <dir>` | iTerm2 pane split direction: horizontal (default) or vertical |
| `--tab` | Open display in a new iTerm2 tab instead of split pane |
| `--window` | Open display in a new iTerm2 window instead of split pane |
| `--no-pane` | Do not open an iTerm2 display pane |
| `--cwd <path>` | Working directory for docker-compose file lookup |

## Constraints

- macOS only — the iTerm2 Python API and AppleScript pane management are macOS-specific; this constraint is intentional
- The `iterm2` Python package requires Python 3 and the iTerm2 API to be enabled in preferences
- No process is ever restarted; all capture backends attach to already-running processes
- `log-watcher.js` is not modified; it is solely invoked as the file fallback implementation
