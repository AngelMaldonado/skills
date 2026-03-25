---
name: log-debugger
description: Attach to a tmux pane and watch its output for expected patterns. Coordinates with the human for manual actions. Used by agents to verify behavior after changes.
argument-hint: --pane <target> --patterns '["pattern1","pattern2"]' [--actions '{"pattern":"action"}'] [--timeout <secs>]
allowed-tools: Bash, AskUserQuestion
---

# Skill: log-debugger

## Description

Attach to a tmux pane and watch its output for expected patterns. Coordinates with the human for manual actions (press a button, refresh a browser, restart a service). Used by agents to verify behavior after changes.

## Triggers

1. Agent needs to verify behavior by watching process output in a tmux pane
2. Agent says "watch for", "verify logs show", "wait for output"
3. Agent needs human to perform an action and confirm via process output
4. Developer asks to monitor a running process

## Steps

### 1. Identify the tmux pane

The caller provides the tmux pane target (e.g., `dev:0.1`). If not provided, list panes and ask:

```bash
tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}'
```

Use `AskUserQuestion` to ask which pane has the target process output.

### 2. Get watch parameters

The caller provides:
- **patterns**: list of log patterns (strings or regex) to watch for
- **actions** (optional): map of pattern to human action description. When that pattern is the next one needed, ask the human to perform the action before continuing.
- **timeout** (optional): how long to wait in seconds (default: 30)

### 3. Start capture

Run the capture script targeting the pane:

```bash
bash ${CLAUDE_SKILL_DIR}/tmux-capture.sh --pane <target> --timeout <T>
```

The script streams pane output and writes captured lines to a JSON file at `/tmp/log-debugger-tmux-<pane>.capture`.

For pattern-based early termination, pass the first pending pattern as `--stop-pattern`:

```bash
bash ${CLAUDE_SKILL_DIR}/tmux-capture.sh --pane <target> --timeout <T> --stop-pattern "<regex>"
```

### 4. Monitor for patterns

Read the capture file after the script exits. Check captured lines against all expected patterns. Track which patterns have been found and which are still pending.

If not all patterns were found in one capture run and time remains, restart capture with the next pending pattern as `--stop-pattern`.

### 5. Handle human actions

When a pattern requires a manual action (defined in `actions`), use `AskUserQuestion` BEFORE starting capture for that pattern. Tell the human:
- What action to perform
- What output pattern you are watching for

Example: "Please restart the dev server. I'm watching for: `[SERVER] Listening on port 3000`"

Wait for the human to confirm, then start/continue capture.

### 6. On timeout

If the timeout expires before all patterns are found:

1. Capture the last 50 lines from the pane for context:
   ```bash
   tmux capture-pane -p -t <target> -S -50
   ```
2. Return to the caller with:
   - Which patterns were found (with the matched lines)
   - Which patterns were NOT found
   - The last 50 lines of output for diagnosis

### 7. On success

When all patterns are found, return to the caller with:
- Confirmation that all patterns matched
- The matched lines with timestamps

## Options

Flags for `tmux-capture.sh`:

```
REQUIRED:
    --pane <pane_id>        tmux pane target (e.g., dev:0.1, main:1.0, %3)

OPTIONS:
    --output <path>         Output capture file path
                            (default: /tmp/log-debugger-tmux-<pane_id>.capture)
    --stop-pattern <regex>  Stop streaming when this pattern matches a line
    --match <pattern>       Alias for --stop-pattern
    --timeout <secs>        Stop capture after this many seconds (default: 30)
    --scrollback <lines>    Lines of scrollback to include (default: 200)
    --buffer-size <N>       Max lines to keep in rolling buffer (default: 500)
    --help                  Show help
```

## Examples

### Example 1 -- Dev server startup

```
Caller: Watch pane dev:0.1 for patterns ["[SERVER] Listening on port 3000", "Database connected"]
        Timeout: 30s
Skill:  Starts capture with --stop-pattern "[SERVER] Listening on port 3000"
        Pattern found at +3s, restarts capture with --stop-pattern "Database connected"
        Pattern found at +5s -> returns success with both matched lines
```

### Example 2 -- Firmware with human action

```
Caller: Watch pane dev:0.1 for patterns ["[BOOT] System initialized", "[BTN] Button pressed"]
        Actions: {"[BTN] Button pressed": "Press the user button on the dev board"}
        Timeout: 60s
Skill:  Starts capture with --stop-pattern "[BOOT] System initialized"
        Pattern found at +2s
        Asks human via AskUserQuestion: "Press the user button on the dev board.
        I'm watching for: [BTN] Button pressed"
        Human confirms -> starts capture
        "[BTN] Button pressed" found at +14s -> returns success
```

### Example 3 -- Build output with timeout

```
Caller: Watch pane build:0.0 for patterns ["BUILD SUCCESSFUL"]
        Timeout: 120s
Skill:  Starts capture, watches for 120s, pattern not found
        Captures last 50 lines from pane
        Returns: NOT FOUND: "BUILD SUCCESSFUL"
        Context (last 50 lines): [actual build output for diagnosis]
```

## Rules

- Always confirm the tmux pane exists before starting capture
- Use `${CLAUDE_SKILL_DIR}` for script paths -- never hardcode absolute paths
- When asking for human actions, be specific about what to do AND what output pattern you are watching for
- On timeout, ALWAYS capture and return context lines -- the caller needs them for diagnosis
- Clean up capture files after returning results: `rm -f /tmp/log-debugger-tmux-*.capture`
- If the tmux pane dies during capture (exitReason: `source_gone`), report it immediately with the last captured output
- Never restart processes in the tmux pane -- only observe
