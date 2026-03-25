---
name: log-debugger-refactor
type: design
---

## Architecture

The refactored skill is organized around a discovery-then-capture pipeline. The developer selects a target process; the skill attaches to it via the appropriate backend; captured output is written to a rolling JSON buffer; and Claude reads that buffer through an analysis formatter.

```
SKILL.md (updated)
  ├── process-discovery.sh    — discovers iTerm2 sessions, tmux panes, Docker containers
  ├── iterm-capture.py        — NEW: iTerm2 Python API session streamer (primary path)
  ├── tmux-capture.sh         — NEW: tmux pipe-pane capture (fallback path)
  ├── docker-capture.sh       — NEW: docker logs -f capture (Docker path)
  ├── iterm-pane.sh           — RENAMED from iterm-tail.sh; generalized to open any command
  ├── log-watcher.js          — UNCHANGED; hidden fallback for --file mode only
  └── analyze-capture.js      — NEW: formats capture JSON into Claude diagnostic report
```

**Data flow:**

1. Claude invokes `process-discovery.sh` → receives a JSON list of running targets
2. Developer picks a target (by number, name, or port)
3. Claude invokes the appropriate capture script against the target
4. Capture script writes lines to a rolling buffer at `/tmp/cx-capture-<name>-<ts>.json`
5. Simultaneously, `iterm-pane.sh` opens a split pane showing the live stream
6. On SIGINT, pattern match, or timeout, the capture script finalizes the JSON file
7. Claude passes the capture file to `analyze-capture.js` → receives a structured diagnostic report
8. Claude presents root cause analysis, error patterns, and suggested next steps

## Technical Decisions

### Process Discovery

`process-discovery.sh` runs three parallel probes and merges results into a single JSON array:

**iTerm2 sessions** (via Python API):
```python
import iterm2
async with iterm2.connect(connection) as conn:
    app = await iterm2.async_get_app(conn)
    for window in app.windows:
        for tab in window.tabs:
            for session in tab.sessions:
                # fields: session_id, title, current_command, working_directory
```

**tmux panes:**
```bash
tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command} #{pane_current_path}'
```

**Docker containers:**
```bash
docker ps --format '{{.ID}}\t{{.Names}}\t{{.Ports}}\t{{.Status}}'
```

Each probe is skipped gracefully if the backend is unavailable (`docker` not on PATH, `tmux` has no sessions, iTerm2 API not reachable). The merged output includes a `type` field (`iterm2` | `tmux` | `docker`) so the capture step knows which script to invoke.

### iTerm2 Capture (Primary Path)

`iterm-capture.py` uses the `iterm2` Python package:

- **Target selection**: accepts `--session-id <id>` or `--session-index <n>`
- **Streaming**: subscribes via `ScreenStreamer` for continuous output events; falls back to polling `Session.async_get_screen_contents()` for an immediate snapshot if streaming is unavailable
- **Rolling buffer**: keeps last 500 lines in memory (configurable via `--buffer-size`)
- **Snapshot mode**: `--snapshot` flag captures the current visible buffer and exits immediately — useful for "what does the screen show right now?"
- **Pattern stop**: `--match <pattern>` causes early exit when the pattern appears; the capture JSON records the matching line
- **Output**: writes `/tmp/cx-capture-<session>-<timestamp>.json` on SIGINT, pattern match, or timeout
- **API guard**: on startup, detects if the iTerm2 Python API is not enabled and prints: `Enable Python API at: Preferences → General → Magic → Enable Python API`; exits with a non-zero code so the discovery step can fall back to tmux

**Dependency**: the `iterm2` Python package. If missing, the script prints `pip3 install iterm2` and exits. iTerm2's API daemon installs this package automatically when the API is first enabled.

### tmux Capture (Fallback Path)

`tmux-capture.sh` attaches to a pane without restarting using a two-phase approach:

1. **Snapshot**: `tmux capture-pane -p -t <target> -S -1000` to retrieve the last 1000 lines of scrollback and seed the capture buffer
2. **Live stream**: `tmux pipe-pane -o -t <target> 'cat >> /tmp/cx-tmux-<target>.log'` — the `-o` flag disables any existing pipe before enabling a new one to prevent double-piping
3. **Existing pipe guard**: before step 2, inspect pane flags; if a pipe is already active, warn the developer and skip (do not override)
4. **Tail loop**: monitors `/tmp/cx-tmux-<target>.log` and appends new lines to the rolling buffer
5. **Cleanup**: on SIGINT, runs `tmux pipe-pane -t <target>` (no command argument) to stop piping, then writes the final capture JSON

**Target format**: pane targets follow `session:window.pane` notation (e.g., `main:1.0`) as returned by `tmux list-panes`.

### Docker Capture

`docker-capture.sh`:

1. `docker logs --tail 100 <container>` for recent history to seed the buffer
2. `docker logs -f <container>` piped into the rolling buffer for live streaming
3. Writes the same `/tmp/cx-capture-<name>-<ts>.json` format on SIGINT or pattern match
4. For `docker-compose` projects, accepts `--cwd <path>` to locate the compose file; if not provided, walks up from `$PWD` to find the nearest `docker-compose.yml` or `compose.yml`

### iTerm2 Pane Display

`iterm-pane.sh` (renamed from `iterm-tail.sh`) is generalized:

- Replaces the hardcoded `node log-watcher.js` command with an arbitrary `--cmd <command-string>` argument
- Retains all AppleScript pane/tab/window split logic unchanged
- The capture scripts pass their tail command (e.g., `tail -f /tmp/cx-capture-...`) as the display command; this keeps the pane in sync with the capture buffer without requiring the capture script to also manage AppleScript

### Capture JSON Schema

All three capture backends write the same JSON format so `analyze-capture.js` has a single input contract:

```json
{
  "source": "iterm2 | tmux | docker",
  "target": "<session-id | pane-target | container-name>",
  "startedAt": "<ISO timestamp>",
  "endedAt": "<ISO timestamp>",
  "exitReason": "sigint | pattern_match | timeout | source_gone",
  "matchedPattern": "<string or null>",
  "lines": [
    { "ts": "<ISO>", "text": "<line content>" }
  ],
  "matchedLines": [
    { "lineIndex": 0, "text": "<matched line>" }
  ]
}
```

### Claude Analysis

`analyze-capture.js` consumes the capture JSON and outputs a compact, Claude-readable report:

- **Error detection**: scans all lines for common error patterns (stack traces, `Error:`, `FATAL`, `panic`, HTTP 5xx, OOM indicators)
- **Pattern clustering**: groups repeated messages to surface retry loops, connection floods, etc.
- **Stack trace extraction**: identifies stack frames and maps them to file + line number
- **Exit context**: includes how the session ended and whether the target process is still running
- **Output format**: plain text report, ~50–100 lines maximum, suitable for Claude to read inline

Claude then uses this report to:
1. Identify the root cause of errors
2. Highlight repeated patterns (retries, OOM, connection failures)
3. Note stack trace origins (file + line number)
4. Suggest a fix or next debugging step

### File Fallback

`log-watcher.js` is triggered only when the developer explicitly passes `--file <path>`. The `SKILL.md` trigger conditions are ordered so file mode is checked last; if `--file` is present, the skill skips discovery entirely and invokes `log-watcher.js` directly (same flow as today).

### Capture File Cleanup

At the start of each run, `process-discovery.sh` deletes any `/tmp/cx-capture-*.json` and `/tmp/cx-tmux-*.log` files older than 24 hours. This prevents accumulation on long-running development machines.

## Implementation Notes

### File Inventory

| File | Action | Notes |
|------|--------|-------|
| `SKILL.md` | Full rewrite | New triggers, discovery steps, three capture modes, file fallback documented |
| `iterm-tail.sh` → `iterm-pane.sh` | Rename + generalize | Replace hardcoded `node log-watcher.js` with `--cmd` arg; keep all AppleScript logic |
| `log-watcher.js` | No change | Preserved as file fallback mode |
| `process-discovery.sh` | New file | iTerm2 + tmux + Docker probes; outputs merged JSON; cleans up stale /tmp files |
| `iterm-capture.py` | New file | iTerm2 Python API streamer with ScreenStreamer; writes capture JSON |
| `tmux-capture.sh` | New file | capture-pane snapshot + pipe-pane live stream; writes capture JSON |
| `docker-capture.sh` | New file | docker logs -f; writes capture JSON; docker-compose cwd detection |
| `analyze-capture.js` | New file | Formats capture JSON into plain-text diagnostic report for Claude |

### SKILL.md Redesign

**Updated description/argument-hint:**
```
description: Attach to a running process and analyze its live output — dev servers, Docker containers, tmux panes, or log files. Identifies errors, stack traces, and root causes without restarting the process.
argument-hint: [process-name-or-number] [--file <path>] [--match <pattern>]
```

**Trigger conditions (in priority order):**
1. Developer asks to debug, watch, or monitor a running process
2. Developer wants to see what a dev server, worker, or container is outputting
3. Developer asks to "attach to", "tail", or "watch" without specifying a file
4. Developer says "what's going wrong with X", "show me X's output", "watch X for errors"
5. Developer provides `--file <path>` explicitly → file fallback mode (skip discovery)

**Step flow:**
1. If `--file` is provided → skip to file fallback (invoke `log-watcher.js`)
2. Run `process-discovery.sh` → receive numbered list of running targets
3. Present list to developer; ask them to pick by number, name, or port
4. Based on target `type` field, invoke `iterm-capture.py` (iterm2), `tmux-capture.sh` (tmux), or `docker-capture.sh` (docker)
5. Simultaneously invoke `iterm-pane.sh --cmd "tail -f <capture-file>"` to open display pane
6. When capture ends, run `node analyze-capture.js <capture-file>` → read diagnostic report
7. Present analysis: root cause, error patterns, stack trace origins, suggested fix

**Options reference (updated):**
```
--file <path>       Skip discovery; watch a log file directly (uses log-watcher.js)
--match <pattern>   Stop capture when this pattern appears (all modes)
--buffer-size <N>   Rolling buffer line count (default: 500)
--snapshot          Capture current screen buffer and exit immediately (iTerm2 only)
--split <dir>       iTerm2 pane split direction: horizontal (default) or vertical
--tab / --window    Open display in new tab or window instead of split pane
--no-pane           Do not open an iTerm2 display pane
--cwd <path>        Working directory for docker-compose lookup
```

### Open Questions Carried Forward

- **ScreenStreamer vs polling**: `ScreenStreamer` is the correct API surface for continuous streaming but behavior may vary by iTerm2 version. The implementation should try `ScreenStreamer` first and fall back to a polling loop using `async_get_screen_contents()` on connection error.
- **tmux existing pipe**: the `-o` toggle and the pre-flight pipe check need careful testing to avoid disrupting developer-managed `pipe-pane` setups.
- **docker-compose cwd**: the `--cwd` flag resolves the compose file lookup ambiguity; the script walks up from `$PWD` if `--cwd` is not supplied.

### Constraints

- macOS only — the iTerm2 Python API and AppleScript pane management are macOS-specific. This constraint is intentional.
- The `iterm2` Python package requires Python 3 and the iTerm2 API to be enabled in preferences.
- No process is ever restarted. Capture scripts must attach to already-running processes.
- `log-watcher.js` is not modified; the file fallback path must remain fully backward-compatible.
