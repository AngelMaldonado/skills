#!/bin/bash
set -euo pipefail

# tmux-capture.sh — Capture output from a running tmux pane
#
# Two-phase capture:
#   Phase 1 (snapshot): Capture recent scrollback via tmux capture-pane
#   Phase 2 (stream):   Redirect ongoing output via tmux pipe-pane to a temp file
#
# Watch any process running in a tmux pane for expected patterns with a timeout.
# Works with dev servers, firmware serial output, build processes, test runners, etc.
#
# Output: JSON capture file with timestamped lines and match metadata.
#
# Usage:
#   tmux-capture.sh --pane <pane_id> [--output <path>] [--scrollback <lines>]
#                    [--stop-pattern <regex>] [--buffer-size <N>]
#                    [--match <pattern>] [--timeout <secs>]

# ─── Defaults ────────────────────────────────────────────────────────────────

PANE_ID=""
OUTPUT_FILE=""
SCROLLBACK=200
STOP_PATTERN=""
MATCH_PATTERN=""
BUFFER_SIZE=500
TIMEOUT=30
PIPE_FILE=""
STARTED_AT=""
EXIT_REASON="sigint"
MATCHED_LINE=""
MATCHED_LINE_INDEX=-1
PIPE_INSTALLED=false

# ─── Help ────────────────────────────────────────────────────────────────────

usage() {
    cat <<'HELP'
tmux-capture.sh — Capture output from a running tmux pane

Watch any process running in a tmux pane for expected patterns with a timeout.

USAGE:
    tmux-capture.sh --pane <pane_id> [OPTIONS]

REQUIRED:
    --pane <pane_id>        tmux pane target (e.g., dev:0.1, main:1.0, %3)

OPTIONS:
    --output <path>         Output capture file path
                            (default: /tmp/log-debugger-tmux-<pane_id>.capture)
    --scrollback <lines>    Lines of recent scrollback to include (default: 200)
    --stop-pattern <regex>  Stop streaming when this pattern matches a line
    --match <pattern>       Alias for --stop-pattern
    --buffer-size <N>       Maximum lines to keep in rolling buffer (default: 500)
    --timeout <secs>        Stop capture after this many seconds (default: 30)
    --help                  Show this help message

EXAMPLES:
    # Watch for a server startup pattern with 30s timeout
    tmux-capture.sh --pane dev:0.1 --stop-pattern "Listening on port 3000"

    # Stream for 60 seconds capturing all output
    tmux-capture.sh --pane dev:0.1 --timeout 60

    # Watch for errors with custom output path
    tmux-capture.sh --pane build:0.0 --stop-pattern "ERROR|FATAL" --output /tmp/my-capture.json
HELP
    exit 0
}

# ─── Argument Parsing ────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pane)
            PANE_ID="$2"; shift 2 ;;
        --output)
            OUTPUT_FILE="$2"; shift 2 ;;
        --scrollback)
            SCROLLBACK="$2"; shift 2 ;;
        --stop-pattern)
            STOP_PATTERN="$2"; shift 2 ;;
        --match)
            MATCH_PATTERN="$2"; shift 2 ;;
        --buffer-size)
            BUFFER_SIZE="$2"; shift 2 ;;
        --timeout)
            TIMEOUT="$2"; shift 2 ;;
        --help|-h)
            usage ;;
        *)
            echo "Error: Unknown option: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1 ;;
    esac
done

# Reconcile --match and --stop-pattern (--match is an alias)
if [[ -n "$MATCH_PATTERN" && -z "$STOP_PATTERN" ]]; then
    STOP_PATTERN="$MATCH_PATTERN"
elif [[ -n "$MATCH_PATTERN" && -n "$STOP_PATTERN" ]]; then
    # Both provided — prefer --stop-pattern
    :
fi

# ─── Validation ──────────────────────────────────────────────────────────────

if [[ -z "$PANE_ID" ]]; then
    echo "Error: --pane <pane_id> is required." >&2
    echo "Run with --help for usage." >&2
    exit 1
fi

# Validate tmux is available
if ! command -v tmux &>/dev/null; then
    echo "Error: tmux is not installed or not on PATH." >&2
    exit 1
fi

# Validate tmux server is running
if ! tmux info &>/dev/null 2>&1; then
    echo "Error: tmux server is not running. Start a tmux session first." >&2
    exit 1
fi

# Validate the target pane exists
# Use capture-pane as the authoritative check — it fails clearly for nonexistent panes
if ! tmux capture-pane -p -t "$PANE_ID" &>/dev/null; then
    echo "Error: tmux pane '$PANE_ID' does not exist." >&2
    echo "List available panes with: tmux list-panes -a" >&2
    exit 1
fi

# Set default output file if not specified
if [[ -z "$OUTPUT_FILE" ]]; then
    # Sanitize pane ID for filename (replace : and . with -)
    SAFE_PANE_ID="${PANE_ID//[:.]/-}"
    OUTPUT_FILE="/tmp/log-debugger-tmux-${SAFE_PANE_ID}.capture"
fi

# ─── Utilities ───────────────────────────────────────────────────────────────

iso_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%S.000Z"
}

json_escape() {
    # Escape a string for safe JSON embedding
    local s="$1"
    s="${s//\\/\\\\}"     # backslash
    s="${s//\"/\\\"}"     # double quote
    s="${s//$'\n'/\\n}"   # newline
    s="${s//$'\r'/\\r}"   # carriage return
    s="${s//$'\t'/\\t}"   # tab
    # Remove control characters (ASCII 0x00-0x1F except those handled above)
    s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
    printf '%s' "$s"
}

# ─── Rolling Buffer (in-memory via temp file) ────────────────────────────────

BUFFER_FILE=$(mktemp /tmp/cx-tmux-capture-buffer.XXXXXX)
LINE_COUNT=0

buffer_add_line() {
    local ts="$1"
    local text="$2"
    local escaped_text
    escaped_text=$(json_escape "$text")
    local escaped_ts
    escaped_ts=$(json_escape "$ts")

    echo "{\"timestamp\": \"${escaped_ts}\", \"line\": \"${escaped_text}\", \"source\": \"tmux\", \"pane_id\": \"${PANE_ID}\"}" >> "$BUFFER_FILE"
    LINE_COUNT=$((LINE_COUNT + 1))

    # Enforce rolling buffer size
    if [[ $LINE_COUNT -gt $((BUFFER_SIZE + 100)) ]]; then
        # Trim to BUFFER_SIZE to avoid trimming on every single line
        local tmp
        tmp=$(mktemp /tmp/cx-tmux-capture-trim.XXXXXX)
        tail -n "$BUFFER_SIZE" "$BUFFER_FILE" > "$tmp"
        mv "$tmp" "$BUFFER_FILE"
        LINE_COUNT=$BUFFER_SIZE
    fi
}

# ─── Write Final Capture JSON ────────────────────────────────────────────────

write_capture_json() {
    local ended_at
    ended_at=$(iso_timestamp)

    local matched_pattern_json="null"
    if [[ -n "$STOP_PATTERN" && "$EXIT_REASON" == "pattern_match" ]]; then
        matched_pattern_json="\"$(json_escape "$STOP_PATTERN")\""
    fi

    local matched_line_json="null"

    # Trim buffer to final BUFFER_SIZE
    local final_buffer
    final_buffer=$(mktemp /tmp/cx-tmux-capture-final.XXXXXX)
    tail -n "$BUFFER_SIZE" "$BUFFER_FILE" > "$final_buffer"

    # Build lines array from the per-line JSON entries in the buffer
    # Each line in buffer is already a JSON object with timestamp, line, source, pane_id
    # But the capture schema wants {"ts": "<ISO>", "text": "<line content>"} format in the lines array
    # We need to transform our buffer format to the schema format

    {
        echo "{"
        echo "  \"source\": \"tmux\","
        echo "  \"target\": \"$(json_escape "$PANE_ID")\","
        echo "  \"startedAt\": \"${STARTED_AT}\","
        echo "  \"endedAt\": \"${ended_at}\","
        echo "  \"exitReason\": \"${EXIT_REASON}\","
        echo "  \"matchedPattern\": ${matched_pattern_json},"
        echo "  \"lines\": ["

        # Detect jq availability once
        local has_jq=false
        if command -v jq &>/dev/null; then
            has_jq=true
        fi

        local first=true
        local line_index=0
        while IFS= read -r json_line; do
            if [[ -z "$json_line" ]]; then
                continue
            fi
            if [[ "$first" == "true" ]]; then
                first=false
            else
                echo ","
            fi
            # Extract timestamp and line text from our buffer format
            # Our buffer lines are: {"timestamp": "...", "line": "...", "source": "tmux", "pane_id": "..."}
            # We need to convert to: {"ts": "...", "text": "..."}
            local ts_val line_val

            if [[ "$has_jq" == "true" ]]; then
                # Robust: use jq for proper JSON field extraction
                ts_val=$(printf '%s' "$json_line" | jq -r '.timestamp // empty')
                line_val=$(printf '%s' "$json_line" | jq -r '.line // empty')
                # Re-escape for embedding in our output JSON
                line_val=$(json_escape "$line_val")
            else
                # Fallback: careful extraction without greedy matching across fields
                # Timestamp uses [^"]* which is safe since ISO timestamps have no quotes
                ts_val=$(printf '%s' "$json_line" | sed 's/.*"timestamp": "\([^"]*\)".*/\1/')
                # For "line", extract everything between "line": " and the LAST occurrence of ", "source"
                # Use awk to handle this robustly: split on the known delimiters
                line_val=$(printf '%s' "$json_line" | awk '
                    {
                        # Find the start: after "line": "
                        start_marker = "\"line\": \""
                        idx = index($0, start_marker)
                        if (idx == 0) { print ""; next }
                        rest = substr($0, idx + length(start_marker))
                        # Find the LAST occurrence of ", "source" to handle lines containing that substring
                        end_marker = "\", \"source\""
                        result = ""
                        while (1) {
                            pos = index(rest, end_marker)
                            if (pos == 0) break
                            if (result != "") result = result end_marker
                            result = result substr(rest, 1, pos - 1)
                            rest = substr(rest, pos + length(end_marker))
                        }
                        print result
                    }
                ')
            fi
            printf '    {"ts": "%s", "text": "%s"}' "$ts_val" "$line_val"

            # Track matched line
            if [[ $line_index -eq $MATCHED_LINE_INDEX && "$EXIT_REASON" == "pattern_match" ]]; then
                matched_line_json="{\"lineIndex\": ${line_index}, \"text\": \"${line_val}\"}"
            fi
            line_index=$((line_index + 1))
        done < "$final_buffer"

        echo ""
        echo "  ],"

        # matchedLines array
        if [[ "$matched_line_json" != "null" ]]; then
            echo "  \"matchedLines\": [${matched_line_json}]"
        else
            echo "  \"matchedLines\": []"
        fi

        echo "}"
    } > "$OUTPUT_FILE"

    rm -f "$final_buffer"

    echo "Capture written to: $OUTPUT_FILE" >&2
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────

cleanup() {
    # Remove tmux pipe if we installed it
    if [[ "$PIPE_INSTALLED" == "true" ]]; then
        tmux pipe-pane -t "$PANE_ID" 2>/dev/null || true
        echo "Removed tmux pipe-pane from $PANE_ID" >&2
    fi

    # Write final capture JSON
    write_capture_json

    # Clean up temp files
    rm -f "$BUFFER_FILE"
    if [[ -n "$PIPE_FILE" && -f "$PIPE_FILE" ]]; then
        rm -f "$PIPE_FILE"
    fi
}

# Track whether cleanup has already run to avoid double-execution
CLEANUP_DONE=false

trap_handler() {
    if [[ "$CLEANUP_DONE" == "true" ]]; then
        return
    fi
    CLEANUP_DONE=true
    if [[ "$EXIT_REASON" == "sigint" ]]; then
        # Only set sigint if not already set to a more specific reason
        :
    fi
    cleanup
}

trap 'EXIT_REASON="sigint"; trap_handler; exit 0' INT TERM
trap 'trap_handler' EXIT

# ─── Phase 1: Snapshot ───────────────────────────────────────────────────────

STARTED_AT=$(iso_timestamp)

echo "Phase 1: Capturing scrollback (last ${SCROLLBACK} lines) from pane ${PANE_ID}..." >&2

snapshot_output=$(tmux capture-pane -p -t "$PANE_ID" -S "-${SCROLLBACK}" 2>/dev/null || true)

if [[ -n "$snapshot_output" ]]; then
    snapshot_ts=$(iso_timestamp)
    while IFS= read -r line; do
        buffer_add_line "$snapshot_ts" "$line"

        # Check stop pattern against snapshot lines
        if [[ -n "$STOP_PATTERN" ]] && echo "$line" | grep -qE "$STOP_PATTERN" 2>/dev/null; then
            EXIT_REASON="pattern_match"
            MATCHED_LINE="$line"
            MATCHED_LINE_INDEX=$((LINE_COUNT - 1))
            echo "Pattern matched in snapshot: $line" >&2
            exit 0
        fi
    done <<< "$snapshot_output"
    echo "Snapshot captured: ${LINE_COUNT} lines" >&2
else
    echo "Snapshot: no scrollback content (pane may be empty)" >&2
fi

# ─── Phase 2: Live Stream via pipe-pane ──────────────────────────────────────

echo "Phase 2: Setting up live stream via pipe-pane..." >&2

# Check for existing pipe
existing_pipe=$(tmux display-message -p -t "$PANE_ID" '#{pane_pipe}' 2>/dev/null || echo "")

if [[ "$existing_pipe" == "1" ]]; then
    echo "Replacing existing pipe-pane on '$PANE_ID'..." >&2
    tmux pipe-pane -t "$PANE_ID" 2>/dev/null || true
fi

# Set up pipe-pane output file
SAFE_PANE_ID_FOR_PIPE="${PANE_ID//[:.]/-}"
PIPE_FILE="/tmp/cx-tmux-${SAFE_PANE_ID_FOR_PIPE}-$$.log"
: > "$PIPE_FILE"  # Create empty file

# Install pipe-pane
tmux pipe-pane -o -t "$PANE_ID" "cat >> '${PIPE_FILE}'"
PIPE_INSTALLED=true
echo "pipe-pane installed: streaming to $PIPE_FILE" >&2

# ─── Tail loop: monitor pipe file for new lines ─────────────────────────────

echo "Streaming (timeout: ${TIMEOUT}s)..." >&2

# Set up timeout if specified
DEADLINE=0
if [[ "$TIMEOUT" -gt 0 ]]; then
    DEADLINE=$(( $(date +%s) + TIMEOUT ))
fi

# Track current position in the pipe file
LAST_SIZE=0

while true; do
    # Check timeout
    if [[ "$DEADLINE" -gt 0 && $(date +%s) -ge "$DEADLINE" ]]; then
        EXIT_REASON="timeout"
        echo "Timeout reached (${TIMEOUT}s)." >&2
        break
    fi

    # Check if the pane still exists
    if ! tmux display-message -p -t "$PANE_ID" '#{pane_id}' &>/dev/null 2>&1; then
        EXIT_REASON="source_gone"
        echo "Pane '$PANE_ID' no longer exists." >&2
        break
    fi

    # Read new content from pipe file
    CURRENT_SIZE=$(wc -c < "$PIPE_FILE" 2>/dev/null || echo "0")
    CURRENT_SIZE=$(echo "$CURRENT_SIZE" | tr -d ' ')

    if [[ "$CURRENT_SIZE" -gt "$LAST_SIZE" ]]; then
        # Read new bytes from the pipe file
        new_content=$(tail -c +"$((LAST_SIZE + 1))" "$PIPE_FILE" 2>/dev/null || true)
        LAST_SIZE=$CURRENT_SIZE

        if [[ -n "$new_content" ]]; then
            ts=$(iso_timestamp)
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                buffer_add_line "$ts" "$line"

                # Check stop pattern
                if [[ -n "$STOP_PATTERN" ]] && echo "$line" | grep -qE "$STOP_PATTERN" 2>/dev/null; then
                    EXIT_REASON="pattern_match"
                    MATCHED_LINE="$line"
                    MATCHED_LINE_INDEX=$((LINE_COUNT - 1))
                    echo "Pattern matched: $line" >&2
                    exit 0
                fi
            done <<< "$new_content"
        fi
    fi

    # Small sleep to avoid busy loop
    sleep 0.2
done

# Normal exit (timeout or source gone) — EXIT trap handles cleanup
exit 0
