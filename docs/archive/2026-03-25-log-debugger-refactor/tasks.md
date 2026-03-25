---
name: log-debugger-refactor
type: tasks
---

## Implementation Notes

Tasks are ordered by dependency. Tasks 1–4 are independent of each other and can be worked in parallel — they share the capture JSON schema, which is fully specified in design.md. Task 5 (analysis engine) depends on the schema being stable, not on tasks 2–4 completing; a hand-crafted fixture file is sufficient for end-to-end testing. Task 6 (iterm-pane.sh) is independent of all other tasks. Task 7 (SKILL.md rewrite) must be done last so it can reference all completed scripts with accurate CLI interfaces.

The capture JSON schema is the shared contract between tasks 2–4 and task 5. All capture scripts must write output conforming to the schema defined in design.md.

---

## Task 1 — Process Discovery Script

**Description:**
Create `process-discovery.sh` in `.claude/skills/log-debugger/`. This script runs three parallel probes (iTerm2 Python API, tmux, Docker) and merges results into a single JSON array. Each entry includes a `type` field (`iterm2` | `tmux` | `docker`) so the downstream capture step knows which script to invoke. At startup the script also deletes `/tmp/cx-capture-*.json` and `/tmp/cx-tmux-*.log` files older than 24 hours.

**Dependencies:** None

**Assigned agent:** general-purpose

**Input:**
- `docs/changes/log-debugger-refactor/design.md` — Process Discovery section, iTerm2/tmux/Docker probe details, graceful degradation rules, cleanup behavior
- `docs/changes/log-debugger-refactor/proposal.md` — scope and constraints

**Output:**
- `.claude/skills/log-debugger/process-discovery.sh` (new file)

**Implementation details:**
- iTerm2 probe: inline Python using the `iterm2` package; fields per session: `session_id`, `title`, `current_command`, `working_directory`; skip silently if API not reachable or package missing
- tmux probe: `tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command} #{pane_current_path}'`; skip if tmux not on PATH or no active sessions
- Docker probe: `docker ps --format '{{.ID}}\t{{.Names}}\t{{.Ports}}\t{{.Status}}'`; skip if `docker` not on PATH
- Output: a single JSON array to stdout; each element has `type`, `id` (backend-specific handle), `label` (human-readable name), and `meta` (any extra fields)
- Cleanup: `find /tmp -name "cx-capture-*.json" -mtime +1 -delete` and `find /tmp -name "cx-tmux-*.log" -mtime +1 -delete` before probing

**Acceptance criteria:**
- Running the script on a machine with iTerm2, tmux, and Docker all active returns a JSON array with entries from all three backends
- Running on a machine where one or more backends are absent returns a JSON array containing only the available backends (no error, no crash)
- The output JSON is valid (parseable with `node -e 'JSON.parse(require("fs").readFileSync("/dev/stdin","utf8"))'`)
- Each entry has `type`, `id`, and `label` fields
- Stale `/tmp/cx-capture-*.json` and `/tmp/cx-tmux-*.log` files older than 24h are deleted before output is emitted

---

## Task 2 — iTerm2 Capture Script

**Description:**
Create `iterm-capture.py` in `.claude/skills/log-debugger/`. This Python script subscribes to a chosen iTerm2 session's output using the `ScreenStreamer` API and writes captured lines to a rolling buffer file at `/tmp/cx-capture-<session>-<timestamp>.json`.

**Dependencies:** None (shares JSON schema with tasks 3 and 4; schema is defined in design.md)

**Assigned agent:** general-purpose

**Input:**
- `docs/changes/log-debugger-refactor/design.md` — iTerm2 Capture section, Capture JSON Schema section
- `docs/changes/log-debugger-refactor/proposal.md` — scope and constraints

**Output:**
- `.claude/skills/log-debugger/iterm-capture.py` (new file)

**Implementation details:**
- CLI flags: `--session-id <id>`, `--session-index <n>`, `--buffer-size <N>` (default 500), `--match <pattern>`, `--snapshot`, `--timeout <secs>`
- Primary streaming path: subscribe via `ScreenStreamer` for continuous output events
- Fallback: if `ScreenStreamer` connection fails, poll `Session.async_get_screen_contents()` in a loop
- `--snapshot`: capture current visible buffer and exit immediately without entering streaming loop
- `--match <pattern>`: exit when the pattern appears; record matching line in output JSON
- Rolling buffer: keep last `--buffer-size` lines in memory
- On SIGINT, pattern match, or timeout: write the capture JSON to `/tmp/cx-capture-<session>-<timestamp>.json` and exit 0
- API guard: if iTerm2 Python API not reachable, print `Enable Python API at: Preferences → General → Magic → Enable Python API` and exit 1
- Dependency guard: if `iterm2` package not installed, print `pip3 install iterm2` and exit 1
- Output JSON must conform exactly to the Capture JSON Schema in design.md (`source`, `target`, `startedAt`, `endedAt`, `exitReason`, `matchedPattern`, `lines`, `matchedLines`)

**Acceptance criteria:**
- Script starts, connects to a live iTerm2 session, and streams output into the rolling buffer without errors
- `--snapshot` exits immediately and produces a valid capture JSON file
- `--match <pattern>` exits when the pattern is matched and sets `exitReason: "pattern_match"` in the output
- SIGINT causes clean shutdown and produces a valid capture JSON file
- API-not-enabled condition prints the correct message and exits non-zero
- Missing `iterm2` package prints the correct install instruction and exits non-zero
- Output JSON is valid and matches the schema in design.md

---

## Task 3 — tmux Capture Script

**Description:**
Create `tmux-capture.sh` in `.claude/skills/log-debugger/`. This script attaches to a running tmux pane using a two-phase approach: snapshot existing scrollback with `tmux capture-pane`, then stream live output by redirecting pane output to a temp file with `tmux pipe-pane`. Writes a capture JSON on exit.

**Dependencies:** None (shares JSON schema with tasks 2 and 4)

**Assigned agent:** general-purpose

**Input:**
- `docs/changes/log-debugger-refactor/design.md` — tmux Capture section, Capture JSON Schema section
- `docs/changes/log-debugger-refactor/proposal.md` — scope and constraints

**Output:**
- `.claude/skills/log-debugger/tmux-capture.sh` (new file)

**Implementation details:**
- CLI flags: `--target <session:window.pane>`, `--match <pattern>`, `--buffer-size <N>` (default 500), `--timeout <secs>`
- Phase 1 snapshot: `tmux capture-pane -p -t <target> -S -1000` to retrieve last 1000 lines and seed the capture buffer
- Phase 2 live stream: `tmux pipe-pane -o -t <target> 'cat >> /tmp/cx-tmux-<target>.log'`; the `-o` flag disables any existing pipe before enabling a new one
- Existing pipe guard: before phase 2, check pane flags; if a pipe is already active, warn the developer and skip (do not override an existing pipe)
- Tail loop: monitor `/tmp/cx-tmux-<target>.log` and append new lines to the rolling buffer
- On SIGINT: run `tmux pipe-pane -t <target>` (no command argument) to stop piping, then write final capture JSON
- Target format follows `session:window.pane` notation (e.g., `main:1.0`) as returned by `tmux list-panes`
- Output JSON must conform to the Capture JSON Schema in design.md with `source: "tmux"`

**Acceptance criteria:**
- Script attaches to a live tmux pane and streams its output without restarting the pane
- Phase 1 snapshot seeds the capture buffer with existing scrollback before live streaming begins
- SIGINT cleanly stops piping and produces a valid capture JSON
- Existing pipe guard warns the developer and does not double-pipe
- `--match <pattern>` stops capture on match and sets `exitReason: "pattern_match"`
- Output JSON is valid and matches the schema in design.md

---

## Task 4 — Docker Capture Script

**Description:**
Create `docker-capture.sh` in `.claude/skills/log-debugger/`. This script streams container output using `docker logs -f`, seeding the buffer first with recent history (`--tail 100`) and writing a capture JSON on exit.

**Dependencies:** None (shares JSON schema with tasks 2 and 3)

**Assigned agent:** general-purpose

**Input:**
- `docs/changes/log-debugger-refactor/design.md` — Docker Capture section, Capture JSON Schema section
- `docs/changes/log-debugger-refactor/proposal.md` — scope and constraints

**Output:**
- `.claude/skills/log-debugger/docker-capture.sh` (new file)

**Implementation details:**
- CLI flags: `--container <name-or-id>`, `--match <pattern>`, `--buffer-size <N>` (default 500), `--timeout <secs>`, `--cwd <path>`
- Seed step: `docker logs --tail 100 <container>` to populate initial buffer before live streaming
- Live stream: `docker logs -f <container>` piped into the rolling buffer
- `--cwd <path>`: locate a docker-compose file in the given directory; if not provided, walk up from `$PWD` to find the nearest `docker-compose.yml` or `compose.yml`
- On SIGINT or pattern match: write capture JSON to `/tmp/cx-capture-<name>-<ts>.json` and exit 0
- Output JSON must conform to the Capture JSON Schema in design.md with `source: "docker"`

**Acceptance criteria:**
- Script streams live output from a running Docker container without restarting it
- Seed step populates the initial buffer with recent history before live streaming begins
- SIGINT cleanly stops streaming and produces a valid capture JSON
- `--match <pattern>` stops capture on match and sets `exitReason: "pattern_match"`
- `--cwd` resolves to the correct docker-compose file; without it, the script walks up from `$PWD`
- Output JSON is valid and matches the schema in design.md

---

## Task 5 — Analysis Engine

**Description:**
Create `analyze-capture.js` in `.claude/skills/log-debugger/`. This zero-dependency Node.js script reads a capture JSON file produced by any capture backend (tasks 2–4) and outputs a plain-text diagnostic report (~50–100 lines) suitable for Claude to read inline.

**Dependencies:** The Capture JSON Schema must be stable (it is fully defined in design.md). Tasks 2–4 do not need to be complete — a hand-crafted fixture JSON file is sufficient for testing.

**Assigned agent:** general-purpose

**Input:**
- `docs/changes/log-debugger-refactor/design.md` — Claude Analysis section, Capture JSON Schema section
- `docs/changes/log-debugger-refactor/proposal.md` — scope

**Output:**
- `.claude/skills/log-debugger/analyze-capture.js` (new file)

**Implementation details:**
- Invocation: `node analyze-capture.js <capture-file-path>`
- Error detection: scan all lines for common error patterns — `Error:`, `FATAL`, `panic`, HTTP 5xx status codes, OOM indicators (`out of memory`, `killed`, `OOMKilled`), stack trace frames
- Pattern clustering: group repeated messages (identical line text appearing N times) to surface retry loops or connection floods; report count + sample line
- Stack trace extraction: identify stack frames (lines matching Node.js `at ...:<line>:<col>` or similar); group by file and include line numbers
- Exit context: include `exitReason` and `matchedPattern` from the capture JSON; note `source` and `target`
- Output format: plain text to stdout, section headers for errors, repeated patterns, stack traces, and exit context; maximum ~100 lines; no JSON output mode needed
- Zero external dependencies (same constraint as `log-watcher.js` — no `npm install` required)
- Exit 0 on success; exit 2 if capture file is missing or not valid JSON

**Acceptance criteria:**
- Given a capture JSON with error lines (`Error:`, `FATAL`), the script produces a report identifying those errors
- Given a capture JSON with repeated identical lines, the script clusters them and shows a count
- Given a capture JSON with Node.js-style stack traces, the script extracts file + line numbers
- Given a capture JSON with `exitReason: "pattern_match"`, the matched line is highlighted in the report
- Output is under 100 lines for typical inputs (< 500 captured lines)
- Script exits 0 on success, exits 2 if the capture file is missing or malformed JSON
- No `node_modules` or external packages required

---

## Task 6 — iTerm2 Pane Script (Rename and Generalize)

**Description:**
Rename `iterm-tail.sh` to `iterm-pane.sh` and replace the hardcoded `node log-watcher.js` command with an `--cmd <command-string>` argument. All existing AppleScript pane/tab/window split logic is preserved unchanged. The old `iterm-tail.sh` file is deleted.

**Dependencies:** None

**Assigned agent:** general-purpose

**Input:**
- `.claude/skills/log-debugger/iterm-tail.sh` — existing source to rename and modify
- `docs/changes/log-debugger-refactor/design.md` — iTerm2 Pane Display section

**Output:**
- `.claude/skills/log-debugger/iterm-pane.sh` (new file, replaces `iterm-tail.sh`)
- `.claude/skills/log-debugger/iterm-tail.sh` — delete after `iterm-pane.sh` is created

**Implementation details:**
- Add `--cmd <command-string>` flag; when present, this command string is run in the iTerm2 pane instead of the hardcoded `node log-watcher.js ...` invocation
- When `--cmd` is not supplied, fall back to the existing `node log-watcher.js ${WATCHER_ARGS[*]} --highlight --stats` behavior (backward compatible)
- Default title logic: if `--cmd` is supplied and no `--title`, use the first word of `--cmd` as the title; otherwise retain existing `log-watcher: <file>` default
- All `--split`, `--tab`, `--window`, `--title` flags and all three AppleScript blocks remain exactly as they are in `iterm-tail.sh`
- Update the header comment block to reflect the new name (`iterm-pane.sh`) and document the `--cmd` flag

**Acceptance criteria:**
- `bash iterm-pane.sh --cmd "tail -f /tmp/cx-capture-foo.json"` opens an iTerm2 pane running that command
- `bash iterm-pane.sh --file app.log --match ERROR` still works identically to today's `iterm-tail.sh` (backward compatibility)
- `iterm-tail.sh` no longer exists in the skill directory after this task completes
- All three pane modes (split, tab, window) work correctly with `--cmd`
- `--split vertical` and `--split horizontal` behave as before

---

## Task 7 — SKILL.md Rewrite

**Description:**
Fully rewrite `.claude/skills/log-debugger/SKILL.md` to document the new discovery-then-capture paradigm. This task must be done last so the SKILL.md accurately reflects all completed script names, CLI interfaces, and flags.

**Dependencies:** Tasks 1–6 should be complete (or their CLI interfaces finalized) before this task begins.

**Assigned agent:** general-purpose

**Input:**
- `docs/changes/log-debugger-refactor/design.md` — SKILL.md Redesign section (description, argument-hint, trigger conditions, step flow, options reference)
- `docs/changes/log-debugger-refactor/proposal.md` — approach and scope
- `.claude/skills/log-debugger/SKILL.md` — current file (to understand what is being replaced)
- Finalized CLI flag list from tasks 1–6

**Output:**
- `.claude/skills/log-debugger/SKILL.md` (full rewrite of existing file)

**Implementation details:**
- New frontmatter:
  ```
  description: Attach to a running process and analyze its live output — dev servers, Docker containers, tmux panes, or log files. Identifies errors, stack traces, and root causes without restarting the process.
  argument-hint: [process-name-or-number] [--file <path>] [--match <pattern>]
  ```
- Five trigger conditions in priority order as specified in design.md
- Seven-step flow as specified in design.md, with accurate script names, flags, and paths throughout
- Options reference table: all flags from design.md (`--file`, `--match`, `--buffer-size`, `--snapshot`, `--split`, `--tab`, `--window`, `--no-pane`, `--cwd`)
- File fallback section: document that `--file <path>` skips discovery and invokes `log-watcher.js` directly, preserving backward compatibility
- Graceful degradation note: what happens when each backend is unavailable (iTerm2 API disabled, no tmux sessions, Docker not installed)
- Rules section: updated for the new paradigm (discovery-first; `--file` is no longer required; analysis is the primary output)
- Examples section: at minimum one example per mode (iTerm2, tmux, Docker, file fallback)

**Acceptance criteria:**
- SKILL.md frontmatter matches the description and argument-hint from design.md exactly
- All five trigger conditions are present in priority order
- All seven step-flow steps are present with accurate script invocations (e.g., `process-discovery.sh`, `iterm-capture.py`, `tmux-capture.sh`, `docker-capture.sh`, `iterm-pane.sh`, `analyze-capture.js`)
- The `--file` fallback path is clearly documented as invoking `log-watcher.js`
- Options reference includes all flags listed in design.md
- At least one usage example for each of the four modes (iTerm2, tmux, Docker, file fallback)
- No stale references to the old file-watcher-only paradigm remain (old triggers, old required `--file` argument, old `iterm-tail.sh` name)
