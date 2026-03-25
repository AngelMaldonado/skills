---
name: log-debugger-refactor
type: proposal
---

## Problem

The log-debugger skill is limited to watching log files. It requires the developer to supply a log file path explicitly, which means:

- Processes writing only to stdout/stderr (dev servers, background workers) are invisible to it
- There is no discovery of what is actually running — the developer must know the path in advance
- Processes cannot be attached to without restarting them, disrupting the workflow
- Claude is passive: it displays output but performs no analysis, never identifying root causes or patterns
- Docker containers and tmux panes are unsupported without manual log-file setup

The net result is that the most common debugging need — "what is my running process outputting right now?" — requires out-of-band setup before the skill can help.

## Approach

Replace the file-tailing paradigm with a **live session debugger** that attaches to already-running processes without restarting them:

1. **Auto-discover running processes** — enumerate iTerm2 sessions (via Python API), tmux panes (via `tmux list-panes`), and Docker containers (via `docker ps`). Present a numbered menu so the developer can pick a target by number, name, or port.

2. **Attach and capture via three paths** (no process restart required in any):
   - **iTerm2 Python API** (primary): Subscribe to screen output events for a chosen session using `ScreenStreamer`; stream into a rolling capture buffer.
   - **tmux pipe-pane** (fallback): Redirect a pane's output to a temp file with `tmux pipe-pane` without stopping the process; tail that file.
   - **Docker logs** (dedicated): Stream container output via `docker logs -f`.

3. **Claude analysis** — after capture, `analyze-capture.js` formats the capture JSON into a structured report (errors, stack traces, repeated patterns, root cause hypotheses) for Claude to diagnose.

4. **Hidden file fallback** — `log-watcher.js` remains intact and is invoked only when the developer explicitly passes `--file <path>`, preserving backward compatibility.

## Scope

**In scope:**
- Three capture backends: iTerm2 Python API, tmux pipe-pane, Docker logs
- `process-discovery.sh` — unified discovery across all three backends
- `iterm-capture.py` — iTerm2 Python API streamer (primary path)
- `tmux-capture.sh` — tmux pipe-pane capture (fallback path)
- `docker-capture.sh` — docker logs -f capture
- `analyze-capture.js` — formats capture JSON into a Claude-readable diagnostic report
- `iterm-pane.sh` — rename and generalization of `iterm-tail.sh` to open any command in an iTerm2 pane
- Full rewrite of `SKILL.md` with new triggers, discovery steps, and capture mode documentation
- Graceful degradation when a backend is unavailable (e.g., no Docker, no tmux, iTerm2 API not enabled)
- Capture file cleanup for `/tmp/cx-capture-*` and `/tmp/cx-tmux-*` files older than 24h

**Out of scope:**
- Cross-platform (Linux, Windows) support — macOS + iTerm2 only constraint is intentional
- Restarting or wrapping processes to capture their output (explicitly rejected approach)
- GUI or web-based log viewer
- Persistent log storage beyond the rolling `/tmp` capture buffer
- Changes to `log-watcher.js` — it is kept unchanged

## Affected Specs

- `log-debugger` — this change replaces the core behavior of the skill; a new spec area covering process discovery, capture modes, and analysis will be created
