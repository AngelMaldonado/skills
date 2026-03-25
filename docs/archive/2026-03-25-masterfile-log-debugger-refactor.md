---
name: log-debugger-refactor
type: masterfile
---

## Problem

The log-debugger skill only works with log files — it polls a file path for new content. This means:

- The developer must know the log file path in advance
- Processes that write to stdout/stderr (not a file) are invisible to it
- There is no auto-discovery of what is actually running in the project
- Output is only displayed, never analyzed; Claude is passive rather than diagnostic
- Dev servers, Docker containers, and background workers are not supported without manual log file setup

## Context

The skill today consists of three files:

- **SKILL.md** — the instruction document for Claude; requires `--file <path>` and `--match <pattern>` as mandatory inputs
- **log-watcher.js** — a zero-dependency Node.js script that polls a file by byte-offset, handles log rotation (truncation), applies regex matching, and outputs JSON or human-readable results. It is solid and well-written.
- **iterm-tail.sh** — a bash script that uses AppleScript to open an iTerm2 split pane and run `log-watcher.js` inside it with human-friendly flags. It wraps the command to keep the pane open after exit.

The skill is macOS-only in practice, which is an acceptable constraint to keep. The developer uses a mix of iTerm2 and tmux.

### Previous approach (rejected)

An earlier version of this plan proposed a **wrapper/re-run model**: spawning the process under a capture script so stdout/stderr could be piped. This was rejected because it requires restarting already-running processes, which disrupts the developer's workflow.

### Why process attachment is feasible here

The developer's environment provides two first-class capture paths that do NOT require restarting a process:

1. **iTerm2 Python API** — iTerm2 ships a Python scripting API (`iterm2` Python package) that lets scripts tap into the output stream of an existing session. The API supports `Session.async_get_screen_contents()` for snapshots and `ScreenStreamer` for continuous streaming. It requires the iTerm2 Python API to be enabled in iTerm2 preferences (Preferences → General → Magic → Enable Python API). This is the primary capture path.

2. **tmux pipe-pane** — For processes running in a tmux pane, `tmux pipe-pane -t <pane> 'cat >> /tmp/output.log'` redirects a pane's output to a file without restarting the process. Combined with `tmux capture-pane -p` for snapshots and `tmux list-panes -a -F '#{pane_id} #{pane_current_command}'` for discovery, this provides a clean attach-without-restart path.

3. **Docker logs** — `docker logs -f <container>` streams from the container's log driver. Already in the original plan and unchanged.

## Direction

Replace the log-file-tailing paradigm with a **live session debugger** that attaches to already-running processes without restarting them:

1. **Auto-discover what is running** — enumerate iTerm2 sessions (via Python API), tmux panes (via `tmux list-panes`), and Docker containers (via `docker ps`). Present a numbered list showing what command each is running. Let the developer pick by number, name, or port.

2. **Three capture modes** (no process restart in any of them):
   - **iTerm2 session capture** (primary): Use the iTerm2 Python API to stream output from a chosen session. The script subscribes to output events and writes a rolling buffer to a capture file.
   - **tmux pane capture** (fallback): Use `tmux pipe-pane` to redirect pane output to a temp file; tail the temp file for analysis. Use `tmux capture-pane -p` for an initial snapshot of the scrollback.
   - **Docker container** (dedicated path): Use `docker logs -f <container>` piped to a capture script.

3. **Keep `log-watcher.js` as a hidden fallback** — only used when the developer explicitly provides `--file <path>`. Not surfaced in the main discovery flow.

4. **Display in iTerm pane** — keep `iterm-tail.sh` (generalized to `iterm-pane.sh`) to open a pane showing the live capture stream while Claude continues working.

5. **Claude analysis** — the capture script writes a rolling buffer to `/tmp/cx-capture-<name>-<ts>.json`. After the session ends or a pattern matches, Claude reads this and performs structured analysis: errors, stack traces, repeated patterns, root cause hypotheses.

### Architecture

```
SKILL.md (updated)
  ├── process-discovery.sh    — discovers iTerm2 sessions, tmux panes, Docker containers
  ├── iterm-capture.py        — NEW: iTerm2 Python API session streamer (primary path)
  ├── tmux-capture.sh         — NEW: tmux pipe-pane capture (fallback path)
  ├── docker-capture.sh       — NEW: docker logs -f capture (Docker path)
  ├── iterm-pane.sh           — RENAMED from iterm-tail.sh, generalized to open any command in pane
  ├── log-watcher.js          — KEPT unchanged; hidden fallback for --file mode
  └── analyze-capture.js      — NEW: reads capture JSON, produces structured analysis for Claude
```

## Process Discovery

The discovery step runs three parallel probes and merges the results:

### iTerm2 sessions
Use the `iterm2` Python package to list all sessions across all windows and tabs:
```python
import iterm2
async with iterm2.connect(connection) as conn:
    app = await iterm2.async_get_app(conn)
    for window in app.windows:
        for tab in window.tabs:
            for session in tab.sessions:
                # get session name, current command, PID
```
Each result includes: session ID, title/name, current command, working directory.

### tmux panes
```bash
tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command} #{pane_current_path}'
```
Each result includes: pane target (e.g., `main:1.0`), running command, working directory.

### Docker containers
```bash
docker ps --format '{{.ID}}\t{{.Names}}\t{{.Ports}}\t{{.Status}}'
```
Each result includes: container ID, name, exposed ports, status.

`process-discovery.sh` runs all three probes (skipping any that are unavailable), merges results into a JSON list, and outputs it for Claude to present as a numbered menu.

## Output Capture

### iTerm2 session capture (primary)

`iterm-capture.py` is a Python script using the `iterm2` package:

- Accepts `--session-id <id>` or `--session-index <n>` to identify the target
- Uses `ScreenStreamer` or subscribes to `screen_update` notifications to receive output as it arrives
- Writes lines to a rolling buffer (last 500 lines, configurable)
- Writes a capture snapshot to `/tmp/cx-capture-<session>-<timestamp>.json` on SIGINT or pattern match
- Supports `--match` pattern to stop early when a pattern appears
- On exit, emits a JSON summary: all captured lines, matched lines, detected errors/stack traces, exit info

The iTerm2 Python API also supports `Session.async_get_screen_contents()` for an immediate snapshot of the current visible buffer — useful for a "capture what's on screen now" mode.

**API requirement**: The iTerm2 Python API must be enabled in preferences. If not enabled, the script detects this and informs the developer to enable it at Preferences → General → Magic → Enable Python API.

### tmux pane capture (fallback)

`tmux-capture.sh` attaches to a pane without restarting:

1. **Snapshot**: `tmux capture-pane -p -t <target> -S -1000` to get the last 1000 lines of scrollback
2. **Live stream**: `tmux pipe-pane -o -t <target> 'cat >> /tmp/cx-tmux-<target>.log'` to start piping new output to a file (the `-o` flag toggles off any existing pipe, then toggles on, avoiding double-piping)
3. **Watch the file**: tail `/tmp/cx-tmux-<target>.log` and write to the capture JSON rolling buffer
4. **Stop**: on SIGINT, run `tmux pipe-pane -t <target>` (no command = disable pipe), then write the final capture JSON

### Docker container capture

`docker-capture.sh`:
1. `docker logs --tail 100 <container>` for recent history
2. `docker logs -f <container>` piped to the rolling buffer
3. Writes capture JSON in same format as other capture modes

### File fallback (hidden)

`log-watcher.js` is unchanged and surfaced only when the developer passes `--file <path>` explicitly.

## Claude Analysis

After any capture session ends, Claude receives the JSON capture file via `analyze-capture.js`:

- All captured lines (last N, configurable)
- Lines matching the watch pattern
- Detected error lines and stack traces
- Exit context (how the session ended: SIGINT, pattern match, timeout)

Claude then:
1. Identifies root cause of errors
2. Highlights repeated patterns (retries, OOM indicators, connection failures)
3. Notes stack trace origins (file + line number)
4. Suggests a fix or next debugging step

`analyze-capture.js` formats the raw capture JSON into a compact, Claude-readable report.

## Files to Modify

| File | Change |
|------|--------|
| `SKILL.md` | Full rewrite: new trigger descriptions, updated steps for process discovery and three capture modes, updated options reference and examples. `--file` mode documented as explicit fallback. |
| `iterm-tail.sh` → `iterm-pane.sh` | Rename and generalize: accept any command string instead of always running `node log-watcher.js`; keep all iTerm2 AppleScript pane/tab/window logic |
| `log-watcher.js` | No changes — kept as file fallback mode |
| `process-discovery.sh` | New file: probes iTerm2 sessions (via Python API), tmux panes, and Docker containers; outputs merged JSON list |
| `iterm-capture.py` | New file: iTerm2 Python API session streamer; subscribes to screen output, writes capture JSON |
| `tmux-capture.sh` | New file: uses tmux capture-pane (snapshot) and pipe-pane (live stream) to capture without restarting |
| `docker-capture.sh` | New file: uses docker logs -f to capture container output |
| `analyze-capture.js` | New file: formats any capture JSON into a Claude-readable analysis report |

## Open Questions

1. **ScreenStreamer vs screen_update subscription**: The iTerm2 Python API has more than one way to receive output. `ScreenStreamer` is designed for continuous streaming; `async_get_screen_contents()` is a polling snapshot. Need to confirm which API surface works best for streaming (ScreenStreamer is likely correct but behavior depends on iTerm2 version). This is a low-risk question — both approaches produce the same output data and the code is small.

2. **tmux pipe-pane and existing pipes**: If a developer already has `tmux pipe-pane` set up for another purpose, the `-o` toggle could interfere. The script should check for an existing pipe before attaching (`tmux show-options -t <target> @pipe-pane` or inspect pane flags). Mitigation: warn the developer and skip if a pipe is already active.

3. **Capture file cleanup**: `/tmp/cx-capture-*.json` and `/tmp/cx-tmux-*.log` files accumulate. Auto-clean files older than 24h at the start of each run.

## Resolved (formerly Open Questions)

- **Restart vs attach**: Developer explicitly rejected the restart/wrap approach. All capture paths now attach to running processes without restarting. Resolved in this revision.
- **Cross-platform requirement**: Dropped. macOS + iTerm2 only is the explicit constraint. Resolved.
- **docker-compose context**: Still needs the project directory for `docker-compose ps`. Claude should pass `--cwd` or infer from `.git` location. Kept as minor implementation detail.

## Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| iTerm2 Python API not enabled in preferences | Medium | Script detects this immediately on startup and prints instructions to enable it; falls back to tmux if available |
| iTerm2 not the active terminal (process in tmux) | Medium — developer uses both | tmux fallback handles this case; discovery lists both iTerm2 and tmux processes |
| `iterm2` Python package not installed | Low-Medium | Script checks for the package and prints `pip3 install iterm2` if missing; iTerm2's API daemon should install it automatically |
| tmux pipe-pane interferes with existing pipe | Low | Script checks for existing pipe before attaching; warns and skips if already piped |
| Docker not installed | Low | Graceful skip: Docker discovery and capture are skipped if `docker` is not on PATH |
| Capture JSON grows too large for very verbose processes | Low | Cap rolling buffer at 500 lines; configurable via `--buffer-size` |
| Process exits while capture is running | Low | All capture scripts handle the source-gone case: write final JSON and exit cleanly |

## Testing

1. **iTerm2 capture**: Open a dev server in an iTerm2 pane, run `process-discovery.sh`, confirm the session appears. Run `iterm-capture.py` against that session, confirm output is streamed to capture JSON without restarting the server.
2. **tmux capture**: Open a process in a tmux pane, run discovery, pick the pane, run `tmux-capture.sh`. Verify `tmux pipe-pane` attaches, output accumulates in the log file, and the JSON is written on SIGINT without killing the process.
3. **Docker capture**: Start a `docker-compose` project, run `docker-capture.sh`, verify `docker logs -f` output is captured and `analyze-capture.js` produces a readable report.
4. **File fallback**: Confirm `--file <path>` still routes to `log-watcher.js` with no change in behavior.
5. **iTerm pane display**: Run `iterm-pane.sh` with a command string, verify a split pane opens and stays open after exit.
6. **Pattern match stop**: Verify `--match "ERROR"` causes any capture mode to stop after the first match and write the capture JSON.
7. **API not enabled**: Disable iTerm2 Python API, confirm `iterm-capture.py` prints a clear setup message and does not crash.
8. **analyze-capture.js**: Feed a sample capture JSON with known errors and stack traces; verify the output report correctly identifies them.

## References

- Current skill: `.claude/skills/log-debugger/`
- iTerm2 Python API docs: https://iterm2.com/python-api/
- iTerm2 ScreenStreamer: `iterm2.ScreenStreamer` — subscribes to screen updates for a session
- tmux pipe-pane man page: `man tmux` — `pipe-pane [-IoO] [-t target-pane] [shell-command]`
- tmux capture-pane: `tmux capture-pane -p -t <target> -S -<lines>` for scrollback
- Docker log streaming: `docker logs -f <container>`
- AppleScript iTerm2 API for split panes (used in existing `iterm-tail.sh`)
