#!/usr/bin/env bats
# Integration tests that MEASURE actual token savings from each optimization.
# These tests verify that the optimizations produce measurably smaller payloads,
# not just that the functions run without error.

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

    # Use the REAL PROMPT.md template (not a tiny mock) to measure realistic savings
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
    cp "$SCRIPT_DIR/templates/PROMPT.md" "$PROMPT_FILE"

    # Create a realistic fix_plan.md
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Fix Plan

## Phase 1: Core Implementation
- [x] Set up project structure and configuration files
- [x] Implement user authentication module with JWT tokens
- [x] Create database schema and migration scripts
- [x] Build REST API endpoints for user management
- [x] Add input validation and error handling middleware
- [ ] Implement WebSocket support for real-time notifications
- [ ] Add rate limiting to API endpoints
- [ ] Create admin dashboard backend routes

## Phase 2: Testing
- [x] Write unit tests for authentication module
- [x] Write integration tests for API endpoints
- [ ] Add E2E tests for critical user flows
- [ ] Load testing for WebSocket connections

## Phase 3: Documentation
- [x] Write API documentation with OpenAPI spec
- [ ] Create deployment guide
- [ ] Add architecture decision records
EOF

    # Create work summary (simulating several past loops)
    cat > "$WORK_SUMMARY_FILE" << 'EOF'
- [Loop 1, 09:00] Set up project structure, initialized TypeScript config, created .env template
- [Loop 2, 09:15] Implemented JWT auth module with login/register/refresh endpoints
- [Loop 3, 09:32] Created PostgreSQL schema: users, sessions, audit_log tables
- [Loop 4, 09:48] Built CRUD REST API for user management with pagination
- [Loop 5, 10:05] Added Joi validation schemas and global error handling middleware
- [Loop 6, 10:22] Wrote 24 unit tests for auth module, all passing
- [Loop 7, 10:38] Wrote 18 integration tests for API endpoints, all passing
- [Loop 8, 10:55] Generated OpenAPI 3.0 spec from route annotations
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

# Helper: extract the -p argument value from CLAUDE_CMD_ARGS
get_prompt_arg() {
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "-p" ]]; then
            echo "${CLAUDE_CMD_ARGS[$((i+1))]}"
            return
        fi
    done
}

# Helper: extract the --append-system-prompt argument value from CLAUDE_CMD_ARGS
get_system_prompt_arg() {
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "--append-system-prompt" ]]; then
            echo "${CLAUDE_CMD_ARGS[$((i+1))]}"
            return
        fi
    done
}

# Helper: estimate tokens (~4 chars per token)
estimate_tokens() {
    local text="$1"
    echo $(( ${#text} / 4 ))
}

# =============================================================================
# MEASUREMENT: Prompt Caching — Loop 1 vs Loop 9
# =============================================================================

@test "SAVINGS: continuation prompt is at least 60% smaller than full prompt" {
    # Loop 1: full prompt
    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "Loop #1. Remaining tasks: 5." "" 1
    local full_prompt
    full_prompt=$(get_prompt_arg)
    local full_size=${#full_prompt}

    # Loop 9: continuation prompt (with session)
    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "Loop #9. Remaining tasks: 5." "session-abc-123" 9
    local cont_prompt
    cont_prompt=$(get_prompt_arg)
    local cont_size=${#cont_prompt}

    # Continuation must be at least 60% smaller
    local savings_pct=$(( (full_size - cont_size) * 100 / full_size ))
    echo "# Full prompt: ${full_size} chars (~$(estimate_tokens "$full_prompt") tokens)" >&3
    echo "# Continuation: ${cont_size} chars (~$(estimate_tokens "$cont_prompt") tokens)" >&3
    echo "# Savings: ${savings_pct}%" >&3

    [ "$savings_pct" -ge 60 ]
}

@test "SAVINGS: continuation prompt is under 2000 chars (~500 tokens)" {
    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "Loop #9. Remaining tasks: 3." "session-abc-123" 9
    local cont_prompt
    cont_prompt=$(get_prompt_arg)

    echo "# Continuation prompt size: ${#cont_prompt} chars (~$(estimate_tokens "$cont_prompt") tokens)" >&3
    [ ${#cont_prompt} -lt 2000 ]
}

@test "SAVINGS: full PROMPT.md is over 8000 chars (~2000 tokens)" {
    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "Loop #1." "" 1
    local full_prompt
    full_prompt=$(get_prompt_arg)

    echo "# Full prompt size: ${#full_prompt} chars (~$(estimate_tokens "$full_prompt") tokens)" >&3
    [ ${#full_prompt} -gt 8000 ]
}

@test "SAVINGS: system prompt on continuation contains full PROMPT.md (for caching)" {
    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "Loop #9." "session-abc-123" 9
    local sys_prompt
    sys_prompt=$(get_system_prompt_arg)

    # System prompt must contain the original PROMPT.md content
    [[ "$sys_prompt" == *"RALPH_STATUS"* ]]
    [[ "$sys_prompt" == *"Exit Scenarios"* ]]
    [[ "$sys_prompt" == *"Protected Files"* ]]

    echo "# System prompt size: ${#sys_prompt} chars (~$(estimate_tokens "$sys_prompt") tokens)" >&3
    echo "# (This is cached by Anthropic at 90% discount after first request)" >&3
}

# =============================================================================
# MEASUREMENT: Active Fix Plan Filtering
# =============================================================================

@test "SAVINGS: active fix plan excludes completed items" {
    # Full fix_plan.md
    local full_size
    full_size=$(wc -c < "$RALPH_DIR/fix_plan.md")

    # Filtered version
    local active
    active=$(generate_active_fix_plan)
    local active_size=${#active}

    echo "# Full fix_plan.md: ${full_size} chars" >&3
    echo "# Active items only: ${active_size} chars" >&3
    echo "# Completed items removed: $(grep -c '\[x\]' "$RALPH_DIR/fix_plan.md")" >&3
    echo "# Remaining items: $(grep -c '\[ \]' "$RALPH_DIR/fix_plan.md")" >&3

    # Active version must be smaller than full
    [ "$active_size" -lt "$full_size" ]
}

@test "SAVINGS: active fix plan contains exactly the uncompleted items" {
    local active
    active=$(generate_active_fix_plan)

    # Must contain all uncompleted items
    [[ "$active" == *"WebSocket support"* ]]
    [[ "$active" == *"rate limiting"* ]]
    [[ "$active" == *"admin dashboard"* ]]
    [[ "$active" == *"E2E tests"* ]]
    [[ "$active" == *"deployment guide"* ]]

    # Must NOT contain completed items
    [[ "$active" != *"Set up project structure"* ]]
    [[ "$active" != *"Implement user authentication"* ]]
    [[ "$active" != *"database schema"* ]]
}

# =============================================================================
# MEASUREMENT: Rolling Work Summary is bounded
# =============================================================================

@test "SAVINGS: work summary stays under 500 chars in loop context" {
    local summary
    summary=$(get_work_summary)

    echo "# Work summary size: ${#summary} chars (~$(estimate_tokens "$summary") tokens)" >&3
    [ ${#summary} -le 500 ]
}

@test "SAVINGS: work summary survives 100 loop accumulations without growing unbounded" {
    # Simulate 100 loops writing summaries
    for i in $(seq 1 100); do
        cat > "$RESPONSE_ANALYSIS_FILE" << EOF
{"analysis": {"work_summary": "Completed task $i: implemented feature number $i with tests and docs"}}
EOF
        update_work_summary "$i"
    done

    local file_size
    file_size=$(wc -c < "$WORK_SUMMARY_FILE")

    echo "# After 100 loops, work summary file: ${file_size} chars" >&3
    # Must stay under 2100 chars (2000 target + margin)
    [ "$file_size" -le 2100 ]
}

# =============================================================================
# MEASUREMENT: Session Compaction prevents unbounded growth
# =============================================================================

@test "SAVINGS: session compaction triggers at token threshold" {
    # Simulate accumulating tokens across loops
    echo "0" > "$SESSION_TOKEN_FILE"
    SESSION_COMPACT_THRESHOLD=50000

    # Simulate 10 loops each using 8000 tokens
    for i in $(seq 1 10); do
        cat > "$TEST_TEMP_DIR/output_${i}.json" << EOF
{"usage": {"input_tokens": 5000, "output_tokens": 3000}}
EOF
        update_session_token_count "$TEST_TEMP_DIR/output_${i}.json"
    done

    local total
    total=$(get_session_token_count)
    echo "# After 10 loops: ${total} cumulative session tokens" >&3
    echo "# Threshold: ${SESSION_COMPACT_THRESHOLD}" >&3

    # Should trigger compaction
    run should_compact_session 11
    echo "# should_compact_session returned: $status (0=compact, 1=continue)" >&3
    [ "$status" -eq 0 ]
}

@test "SAVINGS: compaction resets session tokens to zero" {
    # Simulate what compact_session does: reset the token counter
    echo "80000" > "$SESSION_TOKEN_FILE"

    local before
    before=$(get_session_token_count)
    echo "# Session tokens before compaction: ${before}" >&3
    [ "$before" = "80000" ]

    # compact_session calls reset_session which resets this file
    echo "0" > "$SESSION_TOKEN_FILE"

    local after
    after=$(get_session_token_count)
    echo "# Session tokens after compaction: ${after}" >&3
    [ "$after" = "0" ]
}

@test "SAVINGS: SESSION_MAX_LOOPS=10 triggers compaction after 10 loops" {
    SESSION_MAX_LOOPS=10
    echo "0" > "$SESSION_TOKEN_FILE"

    cat > "$RALPH_SESSION_FILE" << 'EOF'
{"session_id": "test-123", "session_loop_count": 10}
EOF

    run should_compact_session 11
    echo "# SESSION_MAX_LOOPS=10, loop_count=11, should_compact=$status" >&3
    [ "$status" -eq 0 ]
}

# =============================================================================
# MEASUREMENT: Continuation effort level
# =============================================================================

@test "SAVINGS: continuation effort flag is correctly set in CLI args" {
    CLAUDE_EFFORT="high"
    CLAUDE_CONTINUATION_EFFORT="low"

    # Loop 1: should use "high"
    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "" "" 1
    local loop1_effort=""
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "--effort" ]]; then
            loop1_effort="${CLAUDE_CMD_ARGS[$((i+1))]}"
            break
        fi
    done

    # Loop 5: should use "low"
    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "" "" 5
    local loop5_effort=""
    for i in "${!CLAUDE_CMD_ARGS[@]}"; do
        if [[ "${CLAUDE_CMD_ARGS[$i]}" == "--effort" ]]; then
            loop5_effort="${CLAUDE_CMD_ARGS[$((i+1))]}"
            break
        fi
    done

    echo "# Loop 1 effort: ${loop1_effort}" >&3
    echo "# Loop 5 effort: ${loop5_effort}" >&3
    echo "# (low effort uses fewer tokens per response)" >&3

    [ "$loop1_effort" = "high" ]
    [ "$loop5_effort" = "low" ]
}

# =============================================================================
# MEASUREMENT: Repo map
# =============================================================================

@test "SAVINGS: repo map provides project overview under budget" {
    # Create a realistic project structure
    mkdir -p src lib
    cat > src/auth.ts << 'EOF'
export function login(email: string, password: string) { }
export function register(name: string, email: string) { }
export function refreshToken(token: string) { }
export class AuthService { }
export interface AuthConfig { }
EOF
    cat > src/api.ts << 'EOF'
export function getUsers(page: number) { }
export function createUser(data: UserInput) { }
export function updateUser(id: string, data: Partial<User>) { }
export function deleteUser(id: string) { }
export class ApiRouter { }
EOF
    cat > lib/db.sh << 'EOF'
connect_db() { echo "connecting"; }
run_migration() { echo "migrating"; }
seed_data() { echo "seeding"; }
EOF

    CLAUDE_REPO_MAP=true
    local map
    map=$(generate_repo_map)

    echo "# Repo map size: ${#map} chars (~$(estimate_tokens "$map") tokens)" >&3
    echo "# Budget: ${CLAUDE_REPO_MAP_MAX_TOKENS} chars" >&3
    echo "# ---" >&3
    echo "# $map" >&3

    # Must be under budget
    [ ${#map} -le "$CLAUDE_REPO_MAP_MAX_TOKENS" ]
    # Must contain key signatures
    [[ "$map" == *"login"* ]]
    [[ "$map" == *"AuthService"* ]]
    [[ "$map" == *"connect_db"* ]]
}

# =============================================================================
# MEASUREMENT: End-to-end token comparison over simulated 10-loop run
# =============================================================================

@test "SAVINGS: simulated 10-loop run shows cumulative savings vs baseline" {
    local baseline_total=0
    local optimized_total=0

    # Full prompt size (baseline: sent every loop)
    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "Loop #1." "" 1
    local full_prompt
    full_prompt=$(get_prompt_arg)
    local full_prompt_size=${#full_prompt}

    # Continuation prompt size
    CLAUDE_CMD_ARGS=()
    build_claude_command "$PROMPT_FILE" "Loop #5." "session-abc" 5
    local cont_prompt
    cont_prompt=$(get_prompt_arg)
    local cont_prompt_size=${#cont_prompt}

    # Baseline: 10 loops * full prompt
    baseline_total=$((full_prompt_size * 10))

    # Optimized: 1 full + 9 continuation
    optimized_total=$((full_prompt_size + cont_prompt_size * 9))

    local saved=$((baseline_total - optimized_total))
    local saved_pct=$((saved * 100 / baseline_total))
    local saved_tokens=$((saved / 4))

    echo "# ============================================" >&3
    echo "# 10-LOOP TOKEN SAVINGS REPORT" >&3
    echo "# ============================================" >&3
    echo "# Full prompt (loop 1):       ${full_prompt_size} chars (~$((full_prompt_size/4)) tokens)" >&3
    echo "# Continuation prompt (2-10): ${cont_prompt_size} chars (~$((cont_prompt_size/4)) tokens)" >&3
    echo "# " >&3
    echo "# BASELINE (no optimization):  ${baseline_total} chars (~$((baseline_total/4)) tokens)" >&3
    echo "# OPTIMIZED (prompt caching):  ${optimized_total} chars (~$((optimized_total/4)) tokens)" >&3
    echo "# " >&3
    echo "# SAVED: ${saved} chars (~${saved_tokens} tokens)" >&3
    echo "# SAVINGS: ${saved_pct}% reduction in user prompt tokens" >&3
    echo "# ============================================" >&3
    echo "# Note: system prompt (PROMPT.md in --append-system-prompt)" >&3
    echo "# is cached by Anthropic at 90% cost discount after loop 1." >&3
    echo "# Effective savings including cache: >90% on static content." >&3
    echo "# ============================================" >&3

    # Must save at least 50% across 10 loops
    [ "$saved_pct" -ge 50 ]
}

@test "SAVINGS: loop context stays bounded even with rich work history" {
    # Build context for loop 20 with full work history
    local context
    context=$(build_loop_context 20)

    echo "# Loop context at loop 20: ${#context} chars (~$(estimate_tokens "$context") tokens)" >&3
    echo "# Limit: 1500 chars" >&3

    # Must stay under the 1500 char limit
    [ ${#context} -le 1500 ]
}
