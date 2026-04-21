# Token Optimization Guide

Ralph's autonomous loop repeatedly invokes Claude Code, and each iteration consumes tokens. Without optimization, a 20-loop session wastes 60K+ tokens on repeated static instructions alone. This guide explains how Ralph minimizes token consumption while maintaining full output quality.

## The Problem

Each loop iteration sends a prompt to Claude via the `-p` flag. The default PROMPT.md template is ~8,700 chars (~2,170 tokens). With `--resume`, every loop appends a **new** user message containing this full content. After 20 loops:

- 20 copies of PROMPT.md = ~43,400 tokens of repeated instructions
- Plus all assistant responses accumulating in the session
- Plus tool call/result history growing unbounded

## The Solution: 6 Optimization Layers

Ralph applies multiple complementary strategies. All are backward-compatible and can be individually disabled.

### Layer 1: Prompt Caching (default: enabled)

**Savings: 86% reduction in user prompt size per loop**

On loop 1, Ralph sends the full PROMPT.md (~2,170 tokens) as the user message. On loop 2+, it:

1. Moves PROMPT.md to `--append-system-prompt` (Anthropic automatically caches system prompt prefixes at **90% cost discount**)
2. Sends a short **continuation prompt** (~284 tokens) as the user message

The continuation prompt contains only dynamic content:
- Current loop number
- Active (uncompleted) tasks from fix_plan.md
- Rolling work summary of recent loops
- Corrective guidance if the previous loop asked questions
- Reminder to include the RALPH_STATUS block

**All static instructions (status reporting format, exit scenarios, testing guidelines, protected files) are still delivered** — they're in the system prompt instead of the user message.

```
Loop 1:  -p "Full PROMPT.md (8,671 chars)"
Loop 2+: --append-system-prompt "Full PROMPT.md (cached)" -p "Short continuation (1,138 chars)"
```

**Configuration:**
```bash
# In .ralphrc
PROMPT_CACHING=true      # Default. Set false to send full prompt every loop.

# CLI flag
ralph --no-prompt-caching  # Disable for a single run
```

### Layer 2: Session Compaction (default: 200K token threshold)

**Savings: prevents unbounded context growth**

Ralph tracks cumulative tokens per session in `.ralph/.session_tokens`. When the session exceeds a configurable threshold, Ralph resets the session and starts fresh with a **handoff prompt** that preserves continuity:

- Rolling work summary (what was accomplished)
- Fix plan status (completed vs remaining tasks)
- Last loop's recommendation

This is equivalent to the "conversation condensation" approach used by OpenHands and Cursor.

```
Session tokens: 0 → 50K → 100K → 150K → 200K [COMPACT] → 0 → 50K → ...
```

**Configuration:**
```bash
# In .ralphrc
SESSION_COMPACT_THRESHOLD=200000   # Reset after 200K tokens (0 = disabled)
SESSION_MAX_LOOPS=0                # Reset after N loops (0 = disabled)

# CLI flags
ralph --compact-threshold 100000   # Lower threshold for cost-sensitive runs
ralph --session-max-loops 10       # Reset every 10 loops (observation masking)
```

### Layer 3: Rolling Work Summary (always on)

**Savings: bounded context with richer history**

Instead of a 200-character truncated summary of only the last loop, Ralph maintains a rolling summary in `.ralph/.work_summary`:

```
- [Loop 1, 09:00] Set up project structure, TypeScript config
- [Loop 2, 09:15] Implemented JWT auth with login/register/refresh
- [Loop 3, 09:32] Created PostgreSQL schema with migrations
```

The file is bounded at 2,000 characters (~500 tokens) — old entries are evicted as new ones are added. The summary survives session resets, providing continuity across compaction events.

### Layer 4: Active Fix Plan Filtering (always on, in continuation prompts)

**Savings: 52% smaller task list**

Instead of Claude reading the full `fix_plan.md` (including completed `[x]` items), the continuation prompt inlines only uncompleted tasks:

```markdown
## Remaining Tasks
## Phase 1
- [ ] Implement WebSocket support
- [ ] Add rate limiting
- [ ] Create admin dashboard
## Phase 2
- [ ] E2E tests
- [ ] Load testing
```

Completed items are excluded, and Claude doesn't need to spend a tool call reading the file.

### Layer 5: Continuation Effort Level (default: disabled)

**Savings: 30-50% per iteration when enabled**

Loop 1 often requires complex planning and setup. Loop 2+ often does straightforward follow-up work. Ralph can use a different `--effort` level for continuation loops:

```bash
# In .ralphrc
CONTINUATION_EFFORT=low    # Use "low" effort on loop 2+ (empty = same as primary)
```

This reduces token consumption in Claude's reasoning, not just the prompt.

### Layer 6: Lightweight Repo Map (default: disabled)

**Savings: eliminates codebase discovery overhead**

When enabled, Ralph generates a compact code map of function/class signatures and includes it in the system prompt:

```
### JS/TS
src/auth.ts:1:export function login(email, password)
src/auth.ts:4:export class AuthService
### Bash
lib/utils.sh:1:connect_db()
```

Supports JS/TS, Python, bash, Go, and Rust. Cached via file checksums — regenerated only when source files change.

```bash
# In .ralphrc
REPO_MAP=true              # Enable repo map generation
REPO_MAP_MAX_TOKENS=1500   # Max chars (~375 tokens)

# CLI flag
ralph --repo-map
```

## Measured Results

All measurements from the test suite using the real PROMPT.md template (297 lines, 8,701 bytes):

### Token Savings

| Metric | Baseline | Optimized | Savings |
|--------|----------|-----------|---------|
| User prompt per loop (loop 2+) | 2,167 tokens | 284 tokens | **86%** |
| 10-loop cumulative (user prompt) | 21,677 tokens | 4,728 tokens | **78%** |
| System prompt (loop 2+) | full price | 90% cached | **~90% cost** |
| Fix plan in prompt | 816 chars | 394 chars | **52%** |
| Work summary | unbounded | 2,000 chars max | **bounded** |

### Performance Overhead

The optimization adds processing before and after each Claude invocation. Measured against Claude's 30-900 second execution time:

| Pipeline | Avg Time | % of Loop |
|----------|----------|-----------|
| Pre-loop (compaction + context + command) | 86ms | 0.01-0.3% |
| Post-loop (tokens + work summary) | 27ms | 0.003-0.09% |
| **Total overhead** | **~120ms** | **< 0.4%** |

Key function timings (50-iteration average):

| Function | Time | Notes |
|----------|------|-------|
| `should_compact_session` | 1ms | Fast JSON read |
| `generate_active_fix_plan` | 3ms | grep filter |
| `build_static_system_prompt` | 4ms | File read |
| `generate_continuation_prompt` | 17ms | Assembles short prompt |
| `update_session_token_count` | 18ms | jq + file write |
| `generate_repo_map` | 24ms | grep across source files |
| `get_repo_map_if_changed` (cached) | 10ms | Checksum compare |

**The continuation path adds only 5% overhead** compared to the baseline command build (105% ratio).

### Quality Parity

26 tests verify that Claude receives **identical instructions** regardless of optimization mode:

| Instruction | Baseline (loop 1) | Optimized (loop 10) |
|---|---|---|
| RALPH_STATUS block (6 fields) | in `-p` | in `--append-system-prompt` |
| 3 status examples | in `-p` | in `--append-system-prompt` |
| 6 exit scenarios | in `-p` | in `--append-system-prompt` |
| EXIT_SIGNAL instructions | in `-p` | in `--append-system-prompt` |
| Protected files warning | in `-p` | in `--append-system-prompt` |
| Testing guidelines | in `-p` | in `--append-system-prompt` |
| Key principles | in `-p` | in `--append-system-prompt` |
| File structure | in `-p` | in `--append-system-prompt` |

The optimization changes **where** instructions are delivered (system prompt vs user message), not **what** is delivered. The model sees the same directives on every loop.

## Monitoring

### Dashboard

The `ralph-monitor` dashboard shows session token usage:

```
┌─ Current Status ─────────────────────────┐
│ Loop Count:     #12                       │
│ Status:         running                   │
│ API Calls:      12/100                    │
│ Session Tokens: 85000 / 200000 (42%)      │
└───────────────────────────────────────────┘
```

### Status JSON

`status.json` includes token optimization fields:

```json
{
    "session_tokens": 85000,
    "session_compact_threshold": 200000
}
```

### Metrics

`logs/metrics.jsonl` tracks session tokens per loop:

```json
{"timestamp":"2026-04-21T10:30:00Z","loop":5,"duration":45,"success":true,"calls":1,"session_tokens":42000}
```

### Warnings

Ralph logs warnings as session tokens approach the compaction threshold:

```
[INFO]  Session tokens at 50% of threshold (100000/200000)
[WARN]  Session tokens at 75% of threshold (150000/200000)
[WARN]  Session tokens at 90% of threshold (180000/200000). Compaction imminent.
```

## Configuration Reference

All settings in `.ralphrc`:

```bash
# ===== TOKEN OPTIMIZATION =====

# Use short continuation prompts on loop 2+
PROMPT_CACHING=true

# Reset session after N cumulative tokens (0 = disabled)
SESSION_COMPACT_THRESHOLD=200000

# Reset session after N loops (0 = disabled)
# Use 10 for aggressive observation masking
SESSION_MAX_LOOPS=0

# Effort level for continuation loops (empty = same as primary)
# Options: low, medium, high, max
CONTINUATION_EFFORT=

# Generate lightweight repo map for context
REPO_MAP=false

# Max characters for repo map (~4 chars per token)
REPO_MAP_MAX_TOKENS=1500
```

CLI flags:

```bash
ralph --no-prompt-caching        # Disable continuation prompts
ralph --session-max-loops 10     # Reset session every 10 loops
ralph --compact-threshold 100000 # Lower compaction threshold
ralph --repo-map                 # Enable repo map
```

## Files

| File | Purpose |
|------|---------|
| `.ralph/.work_summary` | Rolling work summary (bounded at 2,000 chars) |
| `.ralph/.session_tokens` | Cumulative token counter for current session |
| `.ralph/.session_token_warnings` | Tracks last warning threshold to avoid repeats |
| `.ralph/.fix_plan_active.md` | Filtered fix plan (only uncompleted items) |
| `.ralph/.repo_map` | Cached repo map output |
| `.ralph/.repo_map_checksum` | Source file checksum for cache invalidation |

## Test Coverage

| Test File | Tests | Coverage |
|-----------|-------|----------|
| `test_token_optimization.bats` | 32 | Prompt caching, continuation prompts, effort levels, fix plan filtering, repo map |
| `test_session_compaction.bats` | 20 | Token tracking, compaction triggers, session handoff, work summary preservation |
| `test_token_savings.bats` | 15 | Measured savings: prompt size, fix plan reduction, summary bounds, compaction triggers |
| `test_performance.bats` | 18 | Execution time budgets for every function, pipeline overhead, cache effectiveness |
| `test_quality_parity.bats` | 26 | All critical instructions present on continuation loops, compaction safety, fallback behavior |

**Total: 111 tests** covering token savings, performance, and quality parity.

## Design Decisions

**Why move PROMPT.md to system prompt instead of relying on session history?**
With `--resume`, Claude's session already has the PROMPT.md from loop 1. But Anthropic's prompt caching gives a 90% cost discount on system prompt prefixes. By putting PROMPT.md in `--append-system-prompt`, we get this discount on every loop.

**Why not just shorten PROMPT.md?**
The exit scenarios, status reporting format, and protected files instructions are all critical for Ralph's autonomous operation. Removing them degrades exit detection and file safety. Moving them to a cached system prompt preserves quality while reducing cost.

**Why rolling summary instead of LLM summarization?**
LLM-based summarization (like OpenHands) requires an extra API call per loop. JetBrains research (NeurIPS 2025) found that observation masking outperforms LLM summarization in 4/5 settings while being cheaper. Ralph's rolling summary + session rotation achieves similar results with zero extra API calls.

**Why not use `--compact` from Claude Code?**
The `--compact` command is only available in interactive mode. Ralph runs in non-interactive (`-p`) mode. Session reset + handoff prompt achieves the same effect.
