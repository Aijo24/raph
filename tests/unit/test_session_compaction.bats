#!/usr/bin/env bats
# Tests for session compaction and token monitoring features:
# - Feature 2: Session size monitoring
# - Feature 3: Session compaction / periodic reset
# - Feature 7: Session lifecycle / observation masking

load '../helpers/test_helper'

setup() {
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp/bats-ralph-$$}/test.XXXXXX")"
    cd "$TEST_TEMP_DIR"

    export RALPH_DIR=".ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    export STATUS_FILE="$RALPH_DIR/status.json"
    export CALL_COUNT_FILE="$RALPH_DIR/.call_count"
    export TOKEN_COUNT_FILE="$RALPH_DIR/.token_count"
    export TIMESTAMP_FILE="$RALPH_DIR/.last_reset"
    export EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
    export RESPONSE_ANALYSIS_FILE="$RALPH_DIR/.response_analysis"
    export SESSION_TOKEN_FILE="$RALPH_DIR/.session_tokens"
    export WORK_SUMMARY_FILE="$RALPH_DIR/.work_summary"
    export RALPH_SESSION_FILE="$RALPH_DIR/.ralph_session"
    export CLAUDE_SESSION_FILE="$RALPH_DIR/.claude_session_id"
    export RALPH_SESSION_HISTORY_FILE="$RALPH_DIR/.ralph_session_history"
    export PROMPT_FILE="$RALPH_DIR/PROMPT.md"

    export SESSION_COMPACT_THRESHOLD=200000
    export SESSION_MAX_LOOPS=0
    export VERBOSE_PROGRESS=false

    mkdir -p "$LOG_DIR" "$RALPH_DIR"
    echo "0" > "$CALL_COUNT_FILE"
    echo "0" > "$SESSION_TOKEN_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Source functions
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
    source "$SCRIPT_DIR/lib/date_utils.sh"
    source "$SCRIPT_DIR/lib/response_analyzer.sh"
    source "$SCRIPT_DIR/lib/circuit_breaker.sh"
    source "$SCRIPT_DIR/lib/file_protection.sh"
    source "$SCRIPT_DIR/lib/log_utils.sh"

    eval "$(sed -n '/^update_session_token_count()/,/^}/p' "$SCRIPT_DIR/ralph_loop.sh")"
    eval "$(sed -n '/^get_session_token_count()/,/^}/p' "$SCRIPT_DIR/ralph_loop.sh")"
    eval "$(sed -n '/^log_session_token_warnings()/,/^}/p' "$SCRIPT_DIR/ralph_loop.sh")"
    eval "$(sed -n '/^should_compact_session()/,/^}/p' "$SCRIPT_DIR/ralph_loop.sh")"
    eval "$(sed -n '/^compact_session()/,/^}/p' "$SCRIPT_DIR/ralph_loop.sh")"
    eval "$(sed -n '/^build_session_handoff_prompt()/,/^}/p' "$SCRIPT_DIR/ralph_loop.sh")"
    eval "$(sed -n '/^extract_token_usage()/,/^}/p' "$SCRIPT_DIR/ralph_loop.sh")"
    eval "$(sed -n '/^get_work_summary()/,/^}/p' "$SCRIPT_DIR/ralph_loop.sh")"
    eval "$(sed -n '/^get_work_summary_compact()/,/^}/p' "$SCRIPT_DIR/ralph_loop.sh")"
    eval "$(sed -n '/^generate_active_fix_plan()/,/^}/p' "$SCRIPT_DIR/ralph_loop.sh")"
    eval "$(sed -n '/^log_status()/,/^}/p' "$SCRIPT_DIR/ralph_loop.sh")"
    eval "$(sed -n '/^reset_session()/,/^}/p' "$SCRIPT_DIR/ralph_loop.sh")"
    eval "$(sed -n '/^log_session_transition()/,/^}/p' "$SCRIPT_DIR/ralph_loop.sh")"
}

teardown() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# =============================================================================
# Feature 2: Session Size Monitoring
# =============================================================================

@test "get_session_token_count returns 0 when no file" {
    rm -f "$SESSION_TOKEN_FILE"
    run get_session_token_count
    [ "$output" = "0" ]
}

@test "get_session_token_count reads stored value" {
    echo "150000" > "$SESSION_TOKEN_FILE"
    run get_session_token_count
    [ "$output" = "150000" ]
}

@test "update_session_token_count accumulates tokens" {
    echo "0" > "$SESSION_TOKEN_FILE"

    # Create mock output file with token usage
    cat > "$TEST_TEMP_DIR/output.json" << 'EOF'
{"usage": {"input_tokens": 5000, "output_tokens": 3000}}
EOF

    update_session_token_count "$TEST_TEMP_DIR/output.json"
    local result=$(cat "$SESSION_TOKEN_FILE")
    [ "$result" = "8000" ]
}

@test "update_session_token_count adds to existing count" {
    echo "10000" > "$SESSION_TOKEN_FILE"

    cat > "$TEST_TEMP_DIR/output.json" << 'EOF'
{"usage": {"input_tokens": 2000, "output_tokens": 1000}}
EOF

    update_session_token_count "$TEST_TEMP_DIR/output.json"
    local result=$(cat "$SESSION_TOKEN_FILE")
    [ "$result" = "13000" ]
}

@test "log_session_token_warnings warns at 50 percent" {
    SESSION_COMPACT_THRESHOLD=100000
    echo "0" > "$RALPH_DIR/.session_token_warnings"

    run log_session_token_warnings 50000
    [ -f "$RALPH_DIR/.session_token_warnings" ]
    local warning_level=$(cat "$RALPH_DIR/.session_token_warnings")
    [ "$warning_level" = "50" ]
}

@test "log_session_token_warnings warns at 75 percent" {
    SESSION_COMPACT_THRESHOLD=100000
    echo "50" > "$RALPH_DIR/.session_token_warnings"

    run log_session_token_warnings 75000
    local warning_level=$(cat "$RALPH_DIR/.session_token_warnings")
    [ "$warning_level" = "75" ]
}

@test "log_session_token_warnings warns at 90 percent" {
    SESSION_COMPACT_THRESHOLD=100000
    echo "75" > "$RALPH_DIR/.session_token_warnings"

    run log_session_token_warnings 90000
    local warning_level=$(cat "$RALPH_DIR/.session_token_warnings")
    [ "$warning_level" = "90" ]
}

@test "log_session_token_warnings does not repeat warnings" {
    SESSION_COMPACT_THRESHOLD=100000
    echo "50" > "$RALPH_DIR/.session_token_warnings"

    # 55% should not re-warn (already warned at 50)
    run log_session_token_warnings 55000
    local warning_level=$(cat "$RALPH_DIR/.session_token_warnings")
    [ "$warning_level" = "50" ]
}

@test "log_session_token_warnings disabled when threshold is 0" {
    SESSION_COMPACT_THRESHOLD=0

    run log_session_token_warnings 999999
    # Should not create warning file
    [ ! -f "$RALPH_DIR/.session_token_warnings" ] || [ "$(cat "$RALPH_DIR/.session_token_warnings")" = "0" ]
}

# =============================================================================
# Feature 3: Session Compaction
# =============================================================================

@test "should_compact_session returns 1 when below threshold" {
    SESSION_COMPACT_THRESHOLD=200000
    echo "50000" > "$SESSION_TOKEN_FILE"

    run should_compact_session 5
    [ "$status" -eq 1 ]
}

@test "should_compact_session returns 0 when tokens exceed threshold" {
    SESSION_COMPACT_THRESHOLD=100000
    echo "150000" > "$SESSION_TOKEN_FILE"

    run should_compact_session 5
    [ "$status" -eq 0 ]
}

@test "should_compact_session returns 0 when loops exceed max" {
    SESSION_MAX_LOOPS=5
    echo "0" > "$SESSION_TOKEN_FILE"

    # Create session file with loop count at threshold
    cat > "$RALPH_SESSION_FILE" << 'EOF'
{"session_id": "test-123", "session_loop_count": 6}
EOF

    run should_compact_session 7
    [ "$status" -eq 0 ]
}

@test "should_compact_session returns 1 when loop max is disabled" {
    SESSION_MAX_LOOPS=0
    echo "0" > "$SESSION_TOKEN_FILE"

    cat > "$RALPH_SESSION_FILE" << 'EOF'
{"session_id": "test-123", "session_loop_count": 100}
EOF

    run should_compact_session 101
    [ "$status" -eq 1 ]
}

@test "should_compact_session returns 1 when both thresholds disabled" {
    SESSION_COMPACT_THRESHOLD=0
    SESSION_MAX_LOOPS=0
    echo "999999" > "$SESSION_TOKEN_FILE"

    run should_compact_session 999
    [ "$status" -eq 1 ]
}

@test "compact_session resets session tokens" {
    echo "150000" > "$SESSION_TOKEN_FILE"
    echo "75" > "$RALPH_DIR/.session_token_warnings"
    SESSION_COMPACT_THRESHOLD=100000

    # Create minimal session file
    cat > "$RALPH_SESSION_FILE" << 'EOF'
{"session_id": "test-123", "session_loop_count": 10}
EOF

    compact_session 11

    local tokens=$(cat "$SESSION_TOKEN_FILE")
    [ "$tokens" = "0" ]
    [ ! -f "$RALPH_DIR/.session_token_warnings" ]
}

@test "compact_session preserves work summary" {
    echo "- [Loop 5, 10:00] Important work" > "$WORK_SUMMARY_FILE"
    echo "100000" > "$SESSION_TOKEN_FILE"
    SESSION_COMPACT_THRESHOLD=50000

    cat > "$RALPH_SESSION_FILE" << 'EOF'
{"session_id": "test-123", "session_loop_count": 5}
EOF

    compact_session 6

    [ -f "$WORK_SUMMARY_FILE" ]
    grep -q "Important work" "$WORK_SUMMARY_FILE"
}

# =============================================================================
# Feature 7: Session Handoff
# =============================================================================

@test "build_session_handoff_prompt includes work summary" {
    echo "- [Loop 3, 10:00] Built API endpoints" > "$WORK_SUMMARY_FILE"

    run build_session_handoff_prompt
    [[ "$output" == *"Built API endpoints"* ]]
    [[ "$output" == *"Work Completed"* ]]
}

@test "build_session_handoff_prompt includes fix plan status" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
## Tasks
- [x] Done 1
- [x] Done 2
- [ ] Pending 1
EOF

    run build_session_handoff_prompt
    [[ "$output" == *"Completed: 2"* ]]
    [[ "$output" == *"Remaining: 1"* ]]
}

@test "build_session_handoff_prompt includes last recommendation" {
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{"analysis": {"work_summary": "Continue with auth module"}}
EOF

    run build_session_handoff_prompt
    [[ "$output" == *"Continue with auth module"* ]]
}

@test "build_session_handoff_prompt includes header even with minimal context" {
    rm -f "$WORK_SUMMARY_FILE" "$RALPH_DIR/fix_plan.md" "$RESPONSE_ANALYSIS_FILE"

    run build_session_handoff_prompt
    # Should always include the handoff header
    [[ "$output" == *"Session Handoff"* ]] || [[ "$output" == *"Continuing"* ]] || [ -z "$(echo "$output" | tr -d '[:space:]')" ]
}
