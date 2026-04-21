#!/bin/bash
# raph-track — Token savings tracker for Raph
# Usage:
#   raph-track              # Post-run summary
#   raph-track --live       # Live tracking (refresh every 5s)
#   raph-track --watch      # Watch mode (follow metrics as they come in)
#   raph-track --json       # Machine-readable output
#   raph-track --compare    # Side-by-side baseline vs optimized

set -euo pipefail

RALPH_DIR="${RALPH_DIR:-.ralph}"
METRICS_FILE="$RALPH_DIR/logs/metrics.jsonl"
SESSION_TOKEN_FILE="$RALPH_DIR/.session_tokens"
WORK_SUMMARY_FILE="$RALPH_DIR/.work_summary"
STATUS_FILE="$RALPH_DIR/status.json"
PROMPT_FILE="$RALPH_DIR/PROMPT.md"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'
BOLD='\033[1m'

# Estimate: full prompt size in tokens (~4 chars per token)
get_full_prompt_tokens() {
    if [[ -f "$PROMPT_FILE" ]]; then
        local chars
        chars=$(wc -c < "$PROMPT_FILE" | tr -d ' ')
        echo $(( chars / 4 ))
    else
        echo "2167"  # default from measurements
    fi
}

# Estimate: continuation prompt tokens
CONTINUATION_TOKENS=284  # measured in test_token_savings.bats

check_deps() {
    if ! command -v jq &>/dev/null; then
        echo -e "${RED}Error: jq is required. Install with: brew install jq${NC}" >&2
        exit 1
    fi
}

print_header() {
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                   RAPH TOKEN TRACKER                       ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ─── Post-run summary ──────────────────────────────────────────────

print_summary() {
    local full_prompt_tokens
    full_prompt_tokens=$(get_full_prompt_tokens)

    if [[ ! -f "$METRICS_FILE" ]]; then
        echo -e "${YELLOW}No metrics file found. Run ralph first.${NC}"
        exit 1
    fi

    local total_loops successful failed avg_duration total_calls
    total_loops=$(jq -s 'length' "$METRICS_FILE")
    successful=$(jq -s '[.[] | select(.success==true)] | length' "$METRICS_FILE")
    failed=$(jq -s '[.[] | select(.success==false)] | length' "$METRICS_FILE")
    avg_duration=$(jq -s 'if length > 0 then (map(.duration) | add) / length | floor else 0 end' "$METRICS_FILE")
    total_calls=$(jq -s 'map(.calls) | add // 0' "$METRICS_FILE")

    # Session tokens from metrics
    local last_session_tokens=0
    local max_session_tokens=0
    if jq -e '.[0].session_tokens' <(jq -s '.' "$METRICS_FILE") &>/dev/null; then
        last_session_tokens=$(jq -s 'last.session_tokens // 0' "$METRICS_FILE")
        max_session_tokens=$(jq -s 'map(.session_tokens // 0) | max' "$METRICS_FILE")
    fi

    # Current session tokens
    local current_session_tokens=0
    if [[ -f "$SESSION_TOKEN_FILE" ]]; then
        current_session_tokens=$(cat "$SESSION_TOKEN_FILE" 2>/dev/null || echo "0")
    fi

    # Calculate savings
    local baseline_prompt_tokens=$((full_prompt_tokens * total_loops))
    local optimized_prompt_tokens=0
    if [[ $total_loops -gt 0 ]]; then
        # Loop 1: full prompt, loop 2+: continuation
        optimized_prompt_tokens=$((full_prompt_tokens + CONTINUATION_TOKENS * (total_loops - 1)))
    fi
    local saved_tokens=$((baseline_prompt_tokens - optimized_prompt_tokens))
    local savings_pct=0
    if [[ $baseline_prompt_tokens -gt 0 ]]; then
        savings_pct=$((saved_tokens * 100 / baseline_prompt_tokens))
    fi

    # Per-loop durations
    local min_duration max_duration
    min_duration=$(jq -s 'map(.duration) | min // 0' "$METRICS_FILE")
    max_duration=$(jq -s 'map(.duration) | max // 0' "$METRICS_FILE")

    # Total runtime
    local first_ts last_ts
    first_ts=$(jq -s 'first.timestamp // ""' "$METRICS_FILE" | tr -d '"')
    last_ts=$(jq -s 'last.timestamp // ""' "$METRICS_FILE" | tr -d '"')

    print_header

    # ── Run overview ──
    echo -e "${WHITE}Run Overview${NC}"
    echo -e "  Loops:         ${BOLD}${total_loops}${NC} (${GREEN}${successful} passed${NC}, ${RED}${failed} failed${NC})"
    echo -e "  API calls:     ${BOLD}${total_calls}${NC}"
    echo -e "  Duration:      avg ${avg_duration}s, min ${min_duration}s, max ${max_duration}s"
    echo -e "  Started:       ${DIM}${first_ts}${NC}"
    echo -e "  Last loop:     ${DIM}${last_ts}${NC}"
    echo ""

    # ── Token savings ──
    echo -e "${WHITE}Token Savings (Prompt Caching)${NC}"
    echo -e "  Full prompt:        ${DIM}${full_prompt_tokens} tokens${NC}"
    echo -e "  Continuation:       ${DIM}${CONTINUATION_TOKENS} tokens${NC}"
    echo ""
    echo -e "  Baseline (no opt):  ${RED}${baseline_prompt_tokens} tokens${NC}  (${total_loops} x ${full_prompt_tokens})"
    echo -e "  Optimized (Raph):   ${GREEN}${optimized_prompt_tokens} tokens${NC}  (1 x ${full_prompt_tokens} + $((total_loops - 1)) x ${CONTINUATION_TOKENS})"
    echo -e "  ${BOLD}Saved:              ${GREEN}${saved_tokens} tokens (${savings_pct}%)${NC}"
    echo ""

    # ── Session tokens ──
    echo -e "${WHITE}Session Token Usage${NC}"
    echo -e "  Current session:    ${BOLD}${current_session_tokens}${NC} tokens"
    echo -e "  Peak session:       ${max_session_tokens} tokens"

    # Compact threshold
    local compact_threshold=0
    if [[ -f "$STATUS_FILE" ]]; then
        compact_threshold=$(jq -r '.session_compact_threshold // 0' "$STATUS_FILE" 2>/dev/null || echo "0")
    fi
    if [[ "$compact_threshold" -gt 0 ]]; then
        local pct=$((current_session_tokens * 100 / compact_threshold))
        echo -e "  Compact threshold:  ${compact_threshold} tokens (${pct}% used)"
    fi
    echo ""

    # ── Work summary ──
    if [[ -f "$WORK_SUMMARY_FILE" ]]; then
        local summary_size
        summary_size=$(wc -c < "$WORK_SUMMARY_FILE" | tr -d ' ')
        local summary_lines
        summary_lines=$(wc -l < "$WORK_SUMMARY_FILE" | tr -d ' ')
        echo -e "${WHITE}Work Summary${NC}"
        echo -e "  Size:  ${summary_size} chars (${summary_lines} entries, max 2000)"
        echo -e "  ${DIM}$(tail -3 "$WORK_SUMMARY_FILE" 2>/dev/null | sed 's/^/  /')${NC}"
        echo ""
    fi

    # ── Per-loop breakdown ──
    echo -e "${WHITE}Per-Loop Breakdown${NC}"
    echo -e "  ${DIM}Loop  Duration  Success  Tokens    Prompt Cost${NC}"
    echo -e "  ${DIM}────  ────────  ───────  ──────    ───────────${NC}"

    local i=0
    while IFS= read -r line; do
        i=$((i + 1))
        local dur suc stok
        dur=$(echo "$line" | jq -r '.duration')
        suc=$(echo "$line" | jq -r '.success')
        stok=$(echo "$line" | jq -r '.session_tokens // "-"')

        local suc_icon="${GREEN}ok${NC}"
        [[ "$suc" == "false" ]] && suc_icon="${RED}fail${NC}"

        local prompt_cost
        if [[ $i -eq 1 ]]; then
            prompt_cost="${full_prompt_tokens}t (full)"
        else
            prompt_cost="${CONTINUATION_TOKENS}t (cont)"
        fi

        printf "  ${WHITE}#%-3d${NC}  %5ss    %b    %8s  %s\n" "$i" "$dur" "$suc_icon" "$stok" "$prompt_cost"
    done < "$METRICS_FILE"
    echo ""

    # ── Savings bar ──
    echo -e "${WHITE}Savings Visualization${NC}"
    local bar_len=50
    local filled=$((savings_pct * bar_len / 100))
    local empty=$((bar_len - filled))
    printf "  [${GREEN}"
    printf '█%.0s' $(seq 1 $filled 2>/dev/null) || true
    printf "${DIM}"
    printf '░%.0s' $(seq 1 $empty 2>/dev/null) || true
    printf "${NC}] ${BOLD}${GREEN}${savings_pct}%% saved${NC}\n"
    echo ""
}

# ─── JSON output ────────────────────────────────────────────────────

print_json() {
    local full_prompt_tokens
    full_prompt_tokens=$(get_full_prompt_tokens)

    if [[ ! -f "$METRICS_FILE" ]]; then
        echo '{"error":"no metrics file"}'
        exit 1
    fi

    local total_loops
    total_loops=$(jq -s 'length' "$METRICS_FILE")

    local baseline=$((full_prompt_tokens * total_loops))
    local optimized=$((full_prompt_tokens + CONTINUATION_TOKENS * (total_loops - 1)))
    local saved=$((baseline - optimized))
    local pct=0
    [[ $baseline -gt 0 ]] && pct=$((saved * 100 / baseline))

    local current_session=0
    [[ -f "$SESSION_TOKEN_FILE" ]] && current_session=$(cat "$SESSION_TOKEN_FILE" 2>/dev/null || echo "0")

    jq -s --argjson fpt "$full_prompt_tokens" \
          --argjson ct "$CONTINUATION_TOKENS" \
          --argjson baseline "$baseline" \
          --argjson optimized "$optimized" \
          --argjson saved "$saved" \
          --argjson pct "$pct" \
          --argjson session "$current_session" \
    '{
        total_loops: length,
        successful: ([.[] | select(.success==true)] | length),
        failed: ([.[] | select(.success==false)] | length),
        avg_duration: (if length > 0 then (map(.duration) | add / length | floor) else 0 end),
        total_calls: (map(.calls) | add // 0),
        token_savings: {
            full_prompt_tokens: $fpt,
            continuation_tokens: $ct,
            baseline_total: $baseline,
            optimized_total: $optimized,
            saved: $saved,
            savings_pct: $pct
        },
        session_tokens: $session,
        peak_session_tokens: (map(.session_tokens // 0) | max),
        loops: [.[] | {loop, duration, success, session_tokens}]
    }' "$METRICS_FILE"
}

# ─── Live mode ──────────────────────────────────────────────────────

print_live() {
    while true; do
        clear
        print_summary 2>/dev/null || echo -e "${YELLOW}Waiting for metrics...${NC}"
        echo -e "${DIM}Refreshing every 5s — Ctrl+C to stop${NC}"
        sleep 5
    done
}

# ─── Watch mode (tail -f style) ────────────────────────────────────

print_watch() {
    local full_prompt_tokens
    full_prompt_tokens=$(get_full_prompt_tokens)
    local loop_num=0

    print_header
    echo -e "${DIM}Watching ${METRICS_FILE} for new loops...${NC}"
    echo ""

    # Print existing lines first
    if [[ -f "$METRICS_FILE" ]]; then
        while IFS= read -r line; do
            loop_num=$((loop_num + 1))
            print_loop_line "$line" "$loop_num" "$full_prompt_tokens"
        done < "$METRICS_FILE"
    fi

    # Tail for new lines
    tail -n 0 -f "$METRICS_FILE" 2>/dev/null | while IFS= read -r line; do
        loop_num=$((loop_num + 1))
        print_loop_line "$line" "$loop_num" "$full_prompt_tokens"
    done
}

print_loop_line() {
    local line=$1 num=$2 fpt=$3

    local dur suc stok
    dur=$(echo "$line" | jq -r '.duration')
    suc=$(echo "$line" | jq -r '.success')
    stok=$(echo "$line" | jq -r '.session_tokens // "?"')

    local icon="${GREEN}✓${NC}"
    [[ "$suc" == "false" ]] && icon="${RED}✗${NC}"

    local prompt_type="cont (${CONTINUATION_TOKENS}t)"
    [[ $num -eq 1 ]] && prompt_type="full (${fpt}t)"

    local saved=0
    if [[ $num -gt 1 ]]; then
        saved=$((fpt - CONTINUATION_TOKENS))
    fi

    local ts
    ts=$(echo "$line" | jq -r '.timestamp // ""' | sed 's/T/ /' | cut -c1-19)

    printf "  %b ${WHITE}Loop #%-3d${NC} │ %4ss │ session: %8s │ prompt: %-14s" "$icon" "$num" "$dur" "$stok" "$prompt_type"
    if [[ $saved -gt 0 ]]; then
        printf " │ ${GREEN}saved %dt${NC}" "$saved"
    fi
    printf "  ${DIM}%s${NC}\n" "$ts"
}

# ─── Compare mode ──────────────────────────────────────────────────

print_compare() {
    local full_prompt_tokens
    full_prompt_tokens=$(get_full_prompt_tokens)

    if [[ ! -f "$METRICS_FILE" ]]; then
        echo -e "${YELLOW}No metrics file found.${NC}"
        exit 1
    fi

    local total_loops
    total_loops=$(jq -s 'length' "$METRICS_FILE")

    print_header
    echo -e "${WHITE}Side-by-Side: Ralph (baseline) vs Raph (optimized)${NC}"
    echo ""

    printf "  ${DIM}%-6s  │ %18s │ %18s │ %10s${NC}\n" "Loop" "Ralph (baseline)" "Raph (optimized)" "Saved"
    printf "  ${DIM}──────  │ ────────────────── │ ────────────────── │ ──────────${NC}\n"

    local cumul_baseline=0 cumul_raph=0
    for (( i=1; i<=total_loops; i++ )); do
        local baseline_loop=$full_prompt_tokens
        local raph_loop=$full_prompt_tokens
        [[ $i -gt 1 ]] && raph_loop=$CONTINUATION_TOKENS

        cumul_baseline=$((cumul_baseline + baseline_loop))
        cumul_raph=$((cumul_raph + raph_loop))
        local loop_saved=$((baseline_loop - raph_loop))

        printf "  ${WHITE}#%-4d${NC}  │ %14d tok │ " "$i" "$baseline_loop"
        if [[ $i -eq 1 ]]; then
            printf "%14d tok │ ${DIM}%8d tok${NC}\n" "$raph_loop" "$loop_saved"
        else
            printf "${GREEN}%14d tok${NC} │ ${GREEN}%+9d tok${NC}\n" "$raph_loop" "-$loop_saved"
        fi
    done

    printf "  ${DIM}──────  │ ────────────────── │ ────────────────── │ ──────────${NC}\n"

    local total_saved=$((cumul_baseline - cumul_raph))
    local pct=$((total_saved * 100 / cumul_baseline))
    printf "  ${BOLD}Total${NC}  │ ${RED}%14d tok${NC} │ ${GREEN}%14d tok${NC} │ ${BOLD}${GREEN}-%d tok (-%d%%)${NC}\n" \
        "$cumul_baseline" "$cumul_raph" "$total_saved" "$pct"
    echo ""
}

# ─── Main ───────────────────────────────────────────────────────────

check_deps

case "${1:-}" in
    --live)
        print_live
        ;;
    --watch)
        print_watch
        ;;
    --json)
        print_json
        ;;
    --compare)
        print_compare
        ;;
    -h|--help)
        echo "raph-track — Token savings tracker for Raph"
        echo ""
        echo "Usage:"
        echo "  raph-track              Post-run summary with savings analysis"
        echo "  raph-track --live       Auto-refresh dashboard (every 5s)"
        echo "  raph-track --watch      Follow metrics as loops complete (tail -f style)"
        echo "  raph-track --compare    Side-by-side baseline vs optimized comparison"
        echo "  raph-track --json       Machine-readable JSON output"
        echo "  raph-track --help       This message"
        echo ""
        echo "Run from a Ralph/Raph project directory (must contain .ralph/)."
        ;;
    *)
        print_summary
        ;;
esac
