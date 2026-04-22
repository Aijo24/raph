#!/usr/bin/env bats
# Tests for token optimization features:
# - Feature 1: Rolling work summary
# - Feature 4: Prompt caching / continuation prompts
# - Feature 5: Continuation effort level
# - Feature 6: Active fix plan filtering
# - Feature 8: Lightweight repo map

load '../helpers/test_helper'

# Source the functions under test
setup() {
    # Call parent setup for temp dir and env vars
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

    # Token optimization defaults
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
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Create mock prompt file
    cat > "$PROMPT_FILE" << 'PROMPT'
# Ralph Development Instructions
## Context
You are Ralph, an autonomous AI development agent.
## Status Reporting
Include RALPH_STATUS block at the end of your response.
PROMPT

    # Source ralph_loop.sh functions (avoid executing main)
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
    source "$SCRIPT_DIR/lib/date_utils.sh"
    source "$SCRIPT_DIR/lib/response_analyzer.sh"
    source "$SCRIPT_DIR/lib/circuit_breaker.sh"
    source "$SCRIPT_DIR/lib/file_protection.sh"
    source "$SCRIPT_DIR/lib/log_utils.sh"

    # Source only functions from ralph_loop.sh (not the arg parsing / main execution)
    # We extract functions by sourcing in a controlled way
    # Extract individual functions from ralph_loop.sh using awk (handles multi-line)
    local funcs=(
        update_work_summary get_work_summary
        generate_continuation_prompt build_static_system_prompt
        generate_active_fix_plan generate_repo_map get_repo_map_if_changed
        update_session_token_count get_session_token_count log_session_token_warnings
        should_compact_session extract_token_usage log_status
        build_session_handoff_prompt build_claude_command
    )
    for fn in "${funcs[@]}"; do
        eval "$(awk "/^${fn}\\(\\)/{found=1} found{print; if(/^\\}/){found=0}}" "$SCRIPT_DIR/ralph_loop.sh")"
    done
    # Also need declare for the global array
    declare -a CLAUDE_CMD_ARGS=()
}

teardown() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# =============================================================================
# Feature 1: Rolling Work Summary
# =============================================================================

@test "update_work_summary creates file on first call" {
    # Create mock response analysis
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{"analysis": {"work_summary": "Implemented user authentication"}}
EOF

    update_work_summary 1
    [ -f "$WORK_SUMMARY_FILE" ]
    grep -q "Loop 1" "$WORK_SUMMARY_FILE"
    grep -q "Implemented user authentication" "$WORK_SUMMARY_FILE"
}

@test "update_work_summary appends to existing file" {
    echo "- [Loop 1, 10:00] First task" > "$WORK_SUMMARY_FILE"

    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{"analysis": {"work_summary": "Added tests"}}
EOF

    update_work_summary 2
    # Should have both entries
    grep -q "Loop 1" "$WORK_SUMMARY_FILE"
    grep -q "Loop 2" "$WORK_SUMMARY_FILE"
    grep -q "Added tests" "$WORK_SUMMARY_FILE"
}

@test "update_work_summary truncates to 10000 chars" {
    # Create a large existing summary (> 10000 chars)
    local large_content=""
    for i in $(seq 1 500); do
        large_content+="- [Loop $i, 10:00] Some work was done here for task number $i\n"
    done
    echo -e "$large_content" > "$WORK_SUMMARY_FILE"

    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{"analysis": {"work_summary": "Latest work"}}
EOF

    update_work_summary 501
    local size=$(wc -c < "$WORK_SUMMARY_FILE" | tr -d ' ')
    [ "$size" -le 10100 ]  # Allow small margin for newlines
}

@test "update_work_summary skips when no summary available" {
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{"analysis": {"work_summary": ""}}
EOF

    update_work_summary 1
    [ ! -f "$WORK_SUMMARY_FILE" ]
}

@test "get_work_summary returns empty when no file exists" {
    run get_work_summary
    [ "$output" = "" ]
}

@test "get_work_summary returns full content" {
    local content=""
    for i in $(seq 1 50); do
        content+="- [Loop $i, 10:00] Task done\n"
    done
    echo -e "$content" > "$WORK_SUMMARY_FILE"

    run get_work_summary
    # Full content returned (not truncated)
    [[ "$output" == *"Loop 1"* ]]
    [[ "$output" == *"Loop 50"* ]]
}

# =============================================================================
# Feature 4: Prompt Caching / Continuation Prompts
# =============================================================================

@test "generate_continuation_prompt includes loop number" {
    run generate_continuation_prompt 5
    [[ "$output" == *"loop #5"* ]]
}

@test "generate_continuation_prompt includes active fix plan items" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
## High Priority
- [x] Completed task 1
- [ ] Pending task 2
- [ ] Pending task 3
EOF

    run generate_continuation_prompt 2
    [[ "$output" == *"Pending task 2"* ]]
    [[ "$output" == *"Pending task 3"* ]]
    # Should NOT include completed items
    [[ "$output" != *"Completed task 1"* ]]
}

@test "generate_continuation_prompt includes full work history" {
    echo "- [Loop 1, 10:00] Implemented auth" > "$WORK_SUMMARY_FILE"

    run generate_continuation_prompt 2
    [[ "$output" == *"Implemented auth"* ]]
    [[ "$output" == *"Work History"* ]]
}

@test "generate_continuation_prompt includes question guidance when needed" {
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{"analysis": {"asking_questions": true}}
EOF

    run generate_continuation_prompt 3
    [[ "$output" == *"Do NOT ask questions"* ]]
}

@test "generate_continuation_prompt includes RALPH_STATUS reminder" {
    run generate_continuation_prompt 2
    [[ "$output" == *"RALPH_STATUS"* ]]
}

@test "build_static_system_prompt returns PROMPT.md content" {
    run build_static_system_prompt "$PROMPT_FILE"
    [[ "$output" == *"Ralph Development Instructions"* ]]
}

@test "build_static_system_prompt includes repo map when enabled" {
    # Create a mock source file
    mkdir -p src
    echo 'export function hello() { return "hi"; }' > src/app.js

    CLAUDE_REPO_MAP=true
    run build_static_system_prompt "$PROMPT_FILE"
    [[ "$output" == *"Project Structure"* ]]
}

@test "build_static_system_prompt excludes repo map when disabled" {
    CLAUDE_REPO_MAP=false
    run build_static_system_prompt "$PROMPT_FILE"
    [[ "$output" != *"Project Structure"* ]]
}

# =============================================================================
# Feature 5: Continuation Effort Level
# =============================================================================

@test "build_claude_command uses CLAUDE_EFFORT on loop 1" {
    CLAUDE_EFFORT="high"
    CLAUDE_CONTINUATION_EFFORT="low"
    declare -a CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "" "" 1

    local found=false
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "--effort" && "${CLAUDE_CMD_ARGS[$((i+1))]}" == "high" ]]; then
            found=true
            break
        fi
    done
    [ "$found" = "true" ]
}

@test "build_claude_command uses CLAUDE_CONTINUATION_EFFORT on loop 2+" {
    CLAUDE_EFFORT="high"
    CLAUDE_CONTINUATION_EFFORT="low"
    declare -a CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "" "" 3

    local found=false
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "--effort" && "${CLAUDE_CMD_ARGS[$((i+1))]}" == "low" ]]; then
            found=true
            break
        fi
    done
    [ "$found" = "true" ]
}

@test "build_claude_command uses CLAUDE_EFFORT on loop 2+ when continuation effort is empty" {
    CLAUDE_EFFORT="high"
    CLAUDE_CONTINUATION_EFFORT=""
    declare -a CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "" "" 5

    local found=false
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "--effort" && "${CLAUDE_CMD_ARGS[$((i+1))]}" == "high" ]]; then
            found=true
            break
        fi
    done
    [ "$found" = "true" ]
}

# =============================================================================
# Feature 6: Active Fix Plan Filtering
# =============================================================================

@test "generate_active_fix_plan filters completed items" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
## High Priority
- [x] Done task
- [ ] Pending task 1
## Low Priority
- [x] Another done
- [ ] Pending task 2
EOF

    run generate_active_fix_plan
    [[ "$output" == *"Pending task 1"* ]]
    [[ "$output" == *"Pending task 2"* ]]
    [[ "$output" == *"## High Priority"* ]]
    [[ "$output" != *"Done task"* ]]
    [[ "$output" != *"Another done"* ]]
}

@test "generate_active_fix_plan handles all-complete plan" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
## Tasks
- [x] Done 1
- [x] Done 2
EOF

    run generate_active_fix_plan
    [[ "$output" == *"## Tasks"* ]]
    [[ "$output" != *"Done 1"* ]]
}

@test "generate_active_fix_plan handles missing file" {
    rm -f "$RALPH_DIR/fix_plan.md"
    run generate_active_fix_plan
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "generate_active_fix_plan preserves section headers" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Fix Plan
## Phase 1
- [ ] Task A
## Phase 2
- [ ] Task B
EOF

    run generate_active_fix_plan
    [[ "$output" == *"# Fix Plan"* ]]
    [[ "$output" == *"## Phase 1"* ]]
    [[ "$output" == *"## Phase 2"* ]]
}

# =============================================================================
# Feature 8: Lightweight Repo Map
# =============================================================================

@test "generate_repo_map finds JS/TS exports" {
    mkdir -p src
    echo 'export function hello() { return "hi"; }' > src/app.js
    echo 'export class UserService {}' > src/service.ts

    run generate_repo_map
    [[ "$output" == *"hello"* ]]
    [[ "$output" == *"UserService"* ]]
}

@test "generate_repo_map finds Python functions" {
    mkdir -p src
    cat > src/main.py << 'EOF'
def process_data():
    pass

class DataProcessor:
    pass
EOF

    run generate_repo_map
    [[ "$output" == *"process_data"* ]]
    [[ "$output" == *"DataProcessor"* ]]
}

@test "generate_repo_map finds bash functions" {
    mkdir -p lib
    cat > lib/utils.sh << 'EOF'
my_function() {
    echo "hello"
}

another_function() {
    echo "world"
}
EOF

    run generate_repo_map
    [[ "$output" == *"my_function"* ]]
    [[ "$output" == *"another_function"* ]]
}

@test "generate_repo_map respects max token limit" {
    mkdir -p src
    # Create many functions to exceed the limit
    for i in $(seq 1 100); do
        echo "export function func_${i}() { return $i; }" >> src/big.js
    done

    CLAUDE_REPO_MAP_MAX_TOKENS=200
    run generate_repo_map
    [ ${#output} -le 250 ]  # Allow small margin
}

@test "generate_repo_map returns empty for empty project" {
    run generate_repo_map
    [ "$output" = "" ]
}

@test "get_repo_map_if_changed caches results" {
    mkdir -p src
    echo 'export function hello() {}' > src/app.js

    # First call generates
    run get_repo_map_if_changed
    [ -f "$RALPH_DIR/.repo_map" ]
    [ -f "$RALPH_DIR/.repo_map_checksum" ]
    local first_output="$output"

    # Second call should return cached
    run get_repo_map_if_changed
    [ "$output" = "$first_output" ]
}

# =============================================================================
# Prompt Caching: build_claude_command integration
# =============================================================================

@test "build_claude_command sends full prompt on loop 1" {
    declare -a CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "Loop #1" "" 1

    # Should have -p with full PROMPT.md content
    local found_full=false
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "-p" ]]; then
            if [[ "${CLAUDE_CMD_ARGS[$((i+1))]}" == *"Ralph Development Instructions"* ]]; then
                found_full=true
            fi
            break
        fi
    done
    [ "$found_full" = "true" ]
}

@test "build_claude_command sends continuation prompt on loop 2+ with session" {
    CLAUDE_PROMPT_CACHING=true
    declare -a CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "Loop #5" "session-123" 5

    # Should have -p with continuation prompt (not full PROMPT.md)
    local found_continuation=false
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "-p" ]]; then
            if [[ "${CLAUDE_CMD_ARGS[$((i+1))]}" == *"Continue working"* ]]; then
                found_continuation=true
            fi
            break
        fi
    done
    [ "$found_continuation" = "true" ]
}

@test "build_claude_command sends full prompt when caching disabled" {
    CLAUDE_PROMPT_CACHING=false
    declare -a CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "Loop #5" "session-123" 5

    # Should have -p with full PROMPT.md content
    local found_full=false
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "-p" ]]; then
            if [[ "${CLAUDE_CMD_ARGS[$((i+1))]}" == *"Ralph Development Instructions"* ]]; then
                found_full=true
            fi
            break
        fi
    done
    [ "$found_full" = "true" ]
}

@test "build_claude_command sends full prompt on loop 2+ without session" {
    CLAUDE_PROMPT_CACHING=true
    declare -a CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "Loop #3" "" 3

    # No session_id = no continuation, should use full prompt
    local found_full=false
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "-p" ]]; then
            if [[ "${CLAUDE_CMD_ARGS[$((i+1))]}" == *"Ralph Development Instructions"* ]]; then
                found_full=true
            fi
            break
        fi
    done
    [ "$found_full" = "true" ]
}

@test "build_claude_command puts PROMPT.md in system prompt on continuation" {
    CLAUDE_PROMPT_CACHING=true
    declare -a CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "Loop #5" "session-123" 5

    # System prompt should contain PROMPT.md content
    local found_system=false
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "--append-system-prompt" ]]; then
            if [[ "${CLAUDE_CMD_ARGS[$((i+1))]}" == *"Ralph Development Instructions"* ]]; then
                found_system=true
            fi
            break
        fi
    done
    [ "$found_system" = "true" ]
}
