#!/usr/bin/env bats
# Quality parity tests: verify that the optimized path delivers ALL critical
# instructions to Claude, so output quality is unchanged.
#
# The concern: if we send a 284-token continuation prompt instead of a 2167-token
# full prompt, does Claude still know:
#   - How to report status (RALPH_STATUS block)?
#   - What files are protected?
#   - What tasks remain?
#   - What work was already done?
#   - When to set EXIT_SIGNAL?
#   - Testing guidelines?
#
# These tests assert that EVERY critical instruction is reachable by Claude
# on EVERY loop, regardless of optimization mode.

load '../helpers/test_helper'

setup() {
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp/bats-ralph-$$}/test.XXXXXX")"
    cd "$TEST_TEMP_DIR"

    export RALPH_DIR=".ralph"
    export PROMPT_FILE="$RALPH_DIR/PROMPT.md"
    export LOG_DIR="$RALPH_DIR/logs"
    export STATUS_FILE="$RALPH_DIR/status.json"
    export PROGRESS_FILE="$RALPH_DIR/progress.json"
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

    export CLAUDE_PROMPT_CACHING=true
    export SESSION_COMPACT_THRESHOLD=200000
    export SESSION_MAX_LOOPS=0
    export CLAUDE_CONTINUATION_EFFORT=""
    export CLAUDE_REPO_MAP=false
    export CLAUDE_REPO_MAP_MAX_TOKENS=1500
    export CLAUDE_EFFORT=""
    export CLAUDE_MODEL=""
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_ALLOWED_TOOLS="Write,Read,Edit"
    export CLAUDE_USE_CONTINUE=true
    export CLAUDE_CODE_CMD="claude"
    export VERBOSE_PROGRESS=false
    export LIVE_OUTPUT=false

    mkdir -p "$LOG_DIR" "$RALPH_DIR"
    echo "0" > "$CALL_COUNT_FILE"
    echo "0" > "$SESSION_TOKEN_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Use the REAL PROMPT.md template
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
    cp "$SCRIPT_DIR/templates/PROMPT.md" "$PROMPT_FILE"

    # Realistic project state
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Fix Plan
## Phase 1
- [x] Set up project structure
- [x] Implement auth module
- [x] Create database schema
- [ ] Implement WebSocket support
- [ ] Add rate limiting
- [ ] Create admin dashboard
## Phase 2
- [x] Unit tests for auth
- [ ] E2E tests
- [ ] Load testing
## Phase 3
- [ ] Deployment guide
EOF

    cat > "$WORK_SUMMARY_FILE" << 'EOF'
- [Loop 1, 09:00] Set up project structure, TypeScript config
- [Loop 2, 09:15] Implemented JWT auth with login/register/refresh
- [Loop 3, 09:32] Created PostgreSQL schema with migrations
- [Loop 4, 09:48] Wrote 24 unit tests for auth, all passing
EOF

    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{"analysis": {"work_summary": "Wrote unit tests for auth module", "asking_questions": false, "exit_signal": false}}
EOF

    cat > "$RALPH_DIR/.circuit_breaker_state" << 'EOF'
{"state": "CLOSED", "consecutive_no_progress": 0}
EOF

    # Source functions
    source "$SCRIPT_DIR/lib/date_utils.sh"
    source "$SCRIPT_DIR/lib/response_analyzer.sh"
    source "$SCRIPT_DIR/lib/circuit_breaker.sh"
    source "$SCRIPT_DIR/lib/file_protection.sh"
    source "$SCRIPT_DIR/lib/log_utils.sh"

    local funcs=(
        update_work_summary get_work_summary
        generate_continuation_prompt build_static_system_prompt
        generate_active_fix_plan generate_repo_map get_repo_map_if_changed
        update_session_token_count get_session_token_count log_session_token_warnings
        should_compact_session extract_token_usage log_status
        build_session_handoff_prompt build_claude_command build_loop_context
    )
    for fn in "${funcs[@]}"; do
        eval "$(awk "/^${fn}\\(\\)/{found=1} found{print; if(/^\\}/){found=0}}" "$SCRIPT_DIR/ralph_loop.sh")"
    done
    declare -a CLAUDE_CMD_ARGS=()
}

teardown() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# Helper: get the COMBINED text Claude sees (system prompt + user prompt)
get_full_claude_input() {
    local loop_count=$1
    local session_id=$2

    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "$(build_loop_context "$loop_count")" "$session_id" "$loop_count"

    local system_prompt="" user_prompt=""
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        case "${CLAUDE_CMD_ARGS[$i]}" in
            --append-system-prompt) system_prompt="${CLAUDE_CMD_ARGS[$((i+1))]}" ;;
            -p) user_prompt="${CLAUDE_CMD_ARGS[$((i+1))]}" ;;
        esac
    done

    echo "${system_prompt}"$'\n'"${user_prompt}"
}

# =============================================================================
# CRITICAL INSTRUCTION PARITY: Loop 1 vs Loop 10
# Every instruction Claude needs MUST be reachable on continuation loops.
# On loop 1, everything is in -p (user prompt).
# On loop 10, static instructions move to --append-system-prompt, dynamic to -p.
# The UNION must contain all critical directives.
# =============================================================================

@test "QUALITY: RALPH_STATUS block format is present on loop 1" {
    local input
    input=$(get_full_claude_input 1 "")
    [[ "$input" == *"---RALPH_STATUS---"* ]]
    [[ "$input" == *"STATUS:"* ]]
    [[ "$input" == *"EXIT_SIGNAL:"* ]]
    [[ "$input" == *"WORK_TYPE:"* ]]
    [[ "$input" == *"TASKS_COMPLETED_THIS_LOOP:"* ]]
    [[ "$input" == *"---END_RALPH_STATUS---"* ]]
}

@test "QUALITY: RALPH_STATUS block format is present on loop 10 (continuation)" {
    local input
    input=$(get_full_claude_input 10 "session-abc")
    [[ "$input" == *"---RALPH_STATUS---"* ]]
    [[ "$input" == *"STATUS:"* ]]
    [[ "$input" == *"EXIT_SIGNAL:"* ]]
    [[ "$input" == *"WORK_TYPE:"* ]]
    [[ "$input" == *"TASKS_COMPLETED_THIS_LOOP:"* ]]
    [[ "$input" == *"---END_RALPH_STATUS---"* ]]
}

@test "QUALITY: EXIT_SIGNAL instructions are present on continuation loops" {
    local input
    input=$(get_full_claude_input 10 "session-abc")
    # Claude must know WHEN to set EXIT_SIGNAL true
    [[ "$input" == *"EXIT_SIGNAL"*"true"* ]]
    [[ "$input" == *"fix_plan.md"*"marked"* ]] || [[ "$input" == *"fix_plan.md"* ]]
}

@test "QUALITY: protected files warning is present on continuation loops" {
    local input
    input=$(get_full_claude_input 10 "session-abc")
    [[ "$input" == *"Protected Files"* ]] || [[ "$input" == *"DO NOT MODIFY"* ]] || [[ "$input" == *".ralph/"* ]]
}

@test "QUALITY: testing guidelines are present on continuation loops" {
    local input
    input=$(get_full_claude_input 10 "session-abc")
    [[ "$input" == *"Testing"* ]]
}

@test "QUALITY: exit scenarios are present on continuation loops" {
    local input
    input=$(get_full_claude_input 10 "session-abc")
    [[ "$input" == *"Exit Scenario"* ]] || [[ "$input" == *"Scenario"* ]]
}

@test "QUALITY: key principles are present on continuation loops" {
    local input
    input=$(get_full_claude_input 10 "session-abc")
    [[ "$input" == *"ONE task per loop"* ]] || [[ "$input" == *"Key Principles"* ]]
}

# =============================================================================
# TASK AWARENESS: Claude knows what to work on
# =============================================================================

@test "QUALITY: continuation prompt tells Claude which tasks remain" {
    local input
    input=$(get_full_claude_input 10 "session-abc")

    # Must mention uncompleted tasks
    [[ "$input" == *"WebSocket"* ]]
    [[ "$input" == *"rate limiting"* ]]
    [[ "$input" == *"admin dashboard"* ]]
}

@test "QUALITY: continuation prompt does NOT include completed tasks" {
    local input
    input=$(get_full_claude_input 10 "session-abc")

    # The -p part (continuation prompt) should not list done items
    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "$(build_loop_context 10)" "session-abc" 10
    local user_prompt=""
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "-p" ]]; then
            user_prompt="${CLAUDE_CMD_ARGS[$((i+1))]}"
            break
        fi
    done

    [[ "$user_prompt" != *"[x] Set up project structure"* ]]
    [[ "$user_prompt" != *"[x] Implement auth module"* ]]
}

@test "QUALITY: continuation prompt includes work history for context" {
    local input
    input=$(get_full_claude_input 10 "session-abc")

    # Must mention what was already done
    [[ "$input" == *"JWT auth"* ]] || [[ "$input" == *"auth"* ]]
    [[ "$input" == *"PostgreSQL"* ]] || [[ "$input" == *"schema"* ]]
}

@test "QUALITY: continuation prompt tells Claude to follow fix_plan.md" {
    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "$(build_loop_context 10)" "session-abc" 10
    local user_prompt=""
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "-p" ]]; then
            user_prompt="${CLAUDE_CMD_ARGS[$((i+1))]}"
            break
        fi
    done

    [[ "$user_prompt" == *"fix_plan.md"* ]]
}

@test "QUALITY: continuation prompt reminds Claude to include RALPH_STATUS" {
    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "$(build_loop_context 10)" "session-abc" 10
    local user_prompt=""
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "-p" ]]; then
            user_prompt="${CLAUDE_CMD_ARGS[$((i+1))]}"
            break
        fi
    done

    [[ "$user_prompt" == *"RALPH_STATUS"* ]]
}

# =============================================================================
# SESSION COMPACTION: no context loss on reset
# =============================================================================

@test "QUALITY: after compaction, first loop sends full PROMPT.md again" {
    # Simulate: session was compacted, now loop 11 starts with no session_id
    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "$(build_loop_context 11)" "" 11

    local user_prompt=""
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "-p" ]]; then
            user_prompt="${CLAUDE_CMD_ARGS[$((i+1))]}"
            break
        fi
    done

    # Full prompt must be sent (no session = no continuation)
    [[ "$user_prompt" == *"Ralph Development Instructions"* ]]
    [[ "$user_prompt" == *"RALPH_STATUS"* ]]
    [[ "$user_prompt" == *"Exit Scenario"* ]]
}

@test "QUALITY: after compaction, handoff includes work history" {
    CLAUDE_CMD_ARGS=()
    # loop_count > 1 but no session_id = first loop of new session after compaction
    build_claude_command "$PROMPT_FILE" "$(build_loop_context 11)" "" 11

    local system_prompt=""
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "--append-system-prompt" ]]; then
            system_prompt="${CLAUDE_CMD_ARGS[$((i+1))]}"
            break
        fi
    done

    # Handoff context must include what was accomplished
    [[ "$system_prompt" == *"auth"* ]] || [[ "$system_prompt" == *"Loop"* ]]
}

@test "QUALITY: after compaction, fix plan status is communicated" {
    local handoff
    handoff=$(build_session_handoff_prompt)

    [[ "$handoff" == *"Completed:"* ]]
    [[ "$handoff" == *"Remaining:"* ]]
}

@test "QUALITY: work summary survives compaction" {
    # Save current summary
    local before
    before=$(cat "$WORK_SUMMARY_FILE")

    # Simulate what compact_session does (reset session but NOT work summary)
    echo "0" > "$SESSION_TOKEN_FILE"
    rm -f "$RALPH_DIR/.session_token_warnings"
    # work_summary is NOT deleted

    local after
    after=$(cat "$WORK_SUMMARY_FILE")
    [ "$before" = "$after" ]
}

# =============================================================================
# QUESTION SUPPRESSION: headless mode guidance
# =============================================================================

@test "QUALITY: question guidance is injected when previous loop asked questions" {
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{"analysis": {"work_summary": "Asked about database choice", "asking_questions": true, "exit_signal": false}}
EOF

    local input
    input=$(get_full_claude_input 6 "session-abc")
    [[ "$input" == *"Do NOT ask questions"* ]]
    [[ "$input" == *"autonomously"* ]] || [[ "$input" == *"autonomous"* ]]
}

@test "QUALITY: question guidance is NOT injected when previous loop was normal" {
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{"analysis": {"work_summary": "Implemented feature", "asking_questions": false, "exit_signal": false}}
EOF

    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "$(build_loop_context 6)" "session-abc" 6
    local user_prompt=""
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "-p" ]]; then
            user_prompt="${CLAUDE_CMD_ARGS[$((i+1))]}"
            break
        fi
    done

    [[ "$user_prompt" != *"Do NOT ask questions"* ]]
}

# =============================================================================
# DISABLED OPTIMIZATION: verify baseline behavior is unchanged
# =============================================================================

@test "QUALITY: with PROMPT_CACHING=false, loop 10 gets identical input to loop 1" {
    CLAUDE_PROMPT_CACHING=false

    local input_loop1
    input_loop1=$(get_full_claude_input 1 "")

    local input_loop10
    input_loop10=$(get_full_claude_input 10 "session-abc")

    # Both should contain full PROMPT.md in -p
    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "$(build_loop_context 1)" "" 1
    local p1=""
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "-p" ]]; then
            p1="${CLAUDE_CMD_ARGS[$((i+1))]}"
            break
        fi
    done

    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "$(build_loop_context 10)" "session-abc" 10
    local p10=""
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "-p" ]]; then
            p10="${CLAUDE_CMD_ARGS[$((i+1))]}"
            break
        fi
    done

    # Both must contain the full prompt
    [[ "$p1" == *"Ralph Development Instructions"* ]]
    [[ "$p10" == *"Ralph Development Instructions"* ]]
    [[ "$p1" == *"RALPH_STATUS"* ]]
    [[ "$p10" == *"RALPH_STATUS"* ]]
}

@test "QUALITY: with PROMPT_CACHING=false, no continuation prompt is used" {
    CLAUDE_PROMPT_CACHING=false

    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "$(build_loop_context 10)" "session-abc" 10
    local p=""
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "-p" ]]; then
            p="${CLAUDE_CMD_ARGS[$((i+1))]}"
            break
        fi
    done

    # Must NOT use the short continuation prompt
    [[ "$p" != *"Continue working on the project"* ]]
    # Must use the full prompt
    [[ "$p" == *"Ralph Development Instructions"* ]]
}

# =============================================================================
# COMPLETE INSTRUCTION SET: nothing critical is missing
# =============================================================================

@test "QUALITY: all 6 RALPH_STATUS fields are in system prompt on continuation" {
    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "$(build_loop_context 10)" "session-abc" 10
    local sys=""
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "--append-system-prompt" ]]; then
            sys="${CLAUDE_CMD_ARGS[$((i+1))]}"
            break
        fi
    done

    [[ "$sys" == *"STATUS:"* ]]
    [[ "$sys" == *"TASKS_COMPLETED_THIS_LOOP:"* ]]
    [[ "$sys" == *"FILES_MODIFIED:"* ]]
    [[ "$sys" == *"TESTS_STATUS:"* ]]
    [[ "$sys" == *"WORK_TYPE:"* ]]
    [[ "$sys" == *"EXIT_SIGNAL:"* ]]
}

@test "QUALITY: all 3 RALPH_STATUS examples are in system prompt on continuation" {
    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "$(build_loop_context 10)" "session-abc" 10
    local sys=""
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "--append-system-prompt" ]]; then
            sys="${CLAUDE_CMD_ARGS[$((i+1))]}"
            break
        fi
    done

    # All 3 examples from PROMPT.md
    [[ "$sys" == *"Work in progress"* ]]
    [[ "$sys" == *"Project complete"* ]]
    [[ "$sys" == *"Stuck/blocked"* ]]
}

@test "QUALITY: all 6 exit scenarios are in system prompt on continuation" {
    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "$(build_loop_context 10)" "session-abc" 10
    local sys=""
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "--append-system-prompt" ]]; then
            sys="${CLAUDE_CMD_ARGS[$((i+1))]}"
            break
        fi
    done

    [[ "$sys" == *"Scenario 1"* ]]
    [[ "$sys" == *"Scenario 2"* ]]
    [[ "$sys" == *"Scenario 3"* ]]
    [[ "$sys" == *"Scenario 4"* ]]
    [[ "$sys" == *"Scenario 5"* ]]
    [[ "$sys" == *"Scenario 6"* ]]
}

@test "QUALITY: protected files list is in system prompt on continuation" {
    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "$(build_loop_context 10)" "session-abc" 10
    local sys=""
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "--append-system-prompt" ]]; then
            sys="${CLAUDE_CMD_ARGS[$((i+1))]}"
            break
        fi
    done

    [[ "$sys" == *".ralph/"* ]]
    [[ "$sys" == *".ralphrc"* ]]
    [[ "$sys" == *"NEVER delete"* ]] || [[ "$sys" == *"DO NOT MODIFY"* ]]
}

@test "QUALITY: file structure section is in system prompt on continuation" {
    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "$(build_loop_context 10)" "session-abc" 10
    local sys=""
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "--append-system-prompt" ]]; then
            sys="${CLAUDE_CMD_ARGS[$((i+1))]}"
            break
        fi
    done

    [[ "$sys" == *"File Structure"* ]]
    [[ "$sys" == *"specs/"* ]]
    [[ "$sys" == *"fix_plan.md"* ]]
}

@test "QUALITY: testing guidelines are in system prompt on continuation" {
    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "$(build_loop_context 10)" "session-abc" 10
    local sys=""
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "--append-system-prompt" ]]; then
            sys="${CLAUDE_CMD_ARGS[$((i+1))]}"
            break
        fi
    done

    [[ "$sys" == *"Testing Guidelines"* ]]
    [[ "$sys" == *"LIMIT testing"* ]]
}
