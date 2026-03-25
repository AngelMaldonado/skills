# Delta Spec: log-debugger

Change: log-debugger-refactor

## ADDED Requirements

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
- `iterm-pane.sh` (renamed from `iterm-tail.sh`) MUST accept an arbitrary `--cmd <command-string>` to run in the pane, replacing the hardcoded `node log-watcher.js` invocation
- All existing split/tab/window/title options from `iterm-tail.sh` MUST be preserved

### Capture File Cleanup
- At the start of each invocation, stale capture files (`/tmp/cx-capture-*.json`, `/tmp/cx-tmux-*.log`) older than 24 hours MUST be deleted

## MODIFIED Requirements

### Trigger Conditions
- PREVIOUS: The skill required `--file <path>` and `--match <pattern>` as mandatory inputs before it could run
- NEW: The skill defaults to auto-discovery mode; `--file <path>` is now an explicit opt-in to file fallback mode, making file and match parameters optional at the top level

### Step Flow
- PREVIOUS: Step 1 was to validate the log file path; the file was the primary input
- NEW: Step 1 checks for `--file` flag; if absent, runs process discovery and presents a target menu; file mode is a skip-discovery bypass

### `iterm-tail.sh` Behavior
- PREVIOUS: Hardcoded to run `node log-watcher.js` in the iTerm2 pane
- NEW: Renamed to `iterm-pane.sh`; accepts `--cmd <string>` for any command; used by capture scripts to display a `tail -f` of the capture buffer

## REMOVED Requirements

- The skill no longer treats `--file` and `--match` as required arguments for all invocations
- The skill no longer fails or prompts for a file path when no file is supplied — it runs discovery instead
