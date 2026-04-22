# Token Optimization Guide

Raph's autonomous loop repeatedly invokes Claude Code, and each iteration consumes tokens. Without optimization, a 20-loop session wastes 60K+ tokens on repeated static instructions alone, works on only one task per loop, and compacts the session too early at 200K tokens.

**Raph's philosophy: don't send less, send better.** Replace wasted repeated instructions with useful context (git diff, test results, file tree, task grouping suggestions). Use the 1M context window aggressively with an 800K compaction threshold instead of 200K.

## The Problem

Each loop iteration sends a prompt to Claude via the `-p` flag. The default PROMPT.md template is ~8,700 chars (~2,170 tokens). With `--resume`, every loop appends a **new** user message containing this full content. After 20 loops:

- 20 copies of PROMPT.md = ~43,400 tokens of repeated instructions
- Plus all assistant responses accumulating in the session
- Plus tool call/result history growing unbounded
- Only 1 task per loop = missed opportunities to batch related work

## The Solution: Smart Context + Multi-Task Planning

Raph applies multiple complementary strategies. All are backward-compatible and can be individually disabled.

### Layer 1: Smart Context Management (default: enabled)

**Savings: 86% reduction in user prompt size per loop, replaced with richer context**

On loop 1, Raph sends the full PROMPT.md (~2,170 tokens) as the user message. On loop 2+, it:

1. Moves PROMPT.md to `--append-system-prompt` (Anthropic automatically caches system prompt prefixes at **90% cost discount**)
2. Sends a **rich context prompt** as the user message containing:

The continuation prompt replaces repeated instructions with useful context:
- **Git diff** of changes from the previous loop (what actually changed)
- **Test results** (pass/fail counts, specific failures with file:line)
- **File tree** snapshot (lightweight overview of project structure)
- **Active tasks** from fix_plan.md (only uncompleted items)
- **Task grouping suggestions** (related tasks that share context)
- Rolling work summary of recent loops
- Corrective guidance if the previous loop asked questions

**All static instructions (status reporting format, exit scenarios, testing guidelines, protected files) are still delivered** — they're in the system prompt instead of the user message. Loop 2+ stops re-sending them because they're already in the session.

```
Loop 1:  -p "Full PROMPT.md (8,671 chars)"
Loop 2+: --append-system-prompt "Full PROMPT.md (cached)" -p "Rich context (git diff, tests, tasks, suggestions)"
```

**Configuration:**
```bash
# In .ralphrc
PROMPT_CACHING=true      # Default. Set false to send full prompt every loop.

# CLI flag
ralph --no-prompt-caching  # Disable for a single run
```

### Layer 2: Session Compaction at 800K (default: 800K token threshold)

**Savings: uses the full 1M context window aggressively, prevents unbounded growth**

Raph tracks cumulative tokens per session in `.ralph/.session_tokens`. Instead of compacting conservatively at 200K (wasting 80% of the context window), Raph uses an 800K threshold — utilizing the 1M context window aggressively.

When the session exceeds the threshold, Raph resets with a **thorough handoff prompt** that preserves continuity:

- Rolling work summary (what was accomplished)
- Git log of recent commits
- Remaining tasks from fix_plan.md
- File tree snapshot
- Last loop's recommendation

This is equivalent to the "conversation condensation" approach used by OpenHands and Cursor, but with a much higher threshold that respects the available context window.

```
Session tokens: 0 → 200K → 400K → 600K → 800K [COMPACT] → 0 → 200K → ...
```

**Configuration:**
```bash
# In .ralphrc
SESSION_COMPACT_THRESHOLD=800000   # Reset after 800K tokens (0 = disabled)
SESSION_MAX_LOOPS=0                # Reset after N loops (0 = disabled)

# CLI flags
ralph --compact-threshold 500000   # Lower threshold for cost-sensitive runs
ralph --session-max-loops 10       # Reset every 10 loops (observation masking)
```

### Layer 3: Rolling Work Summary (always on)

**Savings: bounded context with richer history**

Instead of a 200-character truncated summary of only the last loop, Raph maintains a rolling summary in `.ralph/.work_summary`:

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

Loop 1 often requires complex planning and setup. Loop 2+ often does straightforward follow-up work. Raph can use a different `--effort` level for continuation loops:

```bash
# In .ralphrc
CONTINUATION_EFFORT=low    # Use "low" effort on loop 2+ (empty = same as primary)
```

This reduces token consumption in Claude's reasoning, not just the prompt.

### Layer 6: Lightweight Repo Map (default: disabled)

**Savings: eliminates codebase discovery overhead**

When enabled, Raph generates a compact code map of function/class signatures and includes it in the system prompt:

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

### Multi-Task Planning (always on)

**Savings: 2-4x throughput by batching related tasks**

Instead of working on one task per loop, Raph's `suggest_task_groups()` function analyzes `fix_plan.md` and identifies tasks that share context — typically tasks under the same section heading (e.g., all auth-related tasks, all database migration tasks).

The continuation prompt includes a suggested task group:

```markdown
## Suggested task group (shared context: auth module)
- [ ] Implement JWT auth middleware
- [ ] Write auth middleware tests
- [ ] Add auth error handling
```

This is a suggestion, not forced batching. Claude decides whether to accept the grouping or work on tasks individually based on complexity. Benefits:

- **Reduced context switching**: Related files are already loaded
- **Fewer loops**: 3 related tasks in 1 loop instead of 3 separate loops
- **Better coherence**: Tests are written alongside the implementation they test

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
| Context utilization | compacts at 200K (20% of 1M) | compacts at 800K (80% of 1M) | **4x more context** |
| Tasks per loop | 1 (serial) | 2-4 (batched) | **2-4x throughput** |

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
│ Session Tokens: 350000 / 800000 (43%)     │
└───────────────────────────────────────────┘
```

### Status JSON

`status.json` includes token optimization fields:

```json
{
    "session_tokens": 350000,
    "session_compact_threshold": 800000
}
```

### Metrics

`logs/metrics.jsonl` tracks session tokens per loop:

```json
{"timestamp":"2026-04-21T10:30:00Z","loop":5,"duration":45,"success":true,"calls":1,"session_tokens":42000}
```

### Warnings

Raph logs warnings as session tokens approach the compaction threshold:

```
[INFO]  Session tokens at 50% of threshold (400000/800000)
[WARN]  Session tokens at 75% of threshold (600000/800000)
[WARN]  Session tokens at 90% of threshold (720000/800000). Compaction imminent.
```

## Configuration Reference

All settings in `.ralphrc`:

```bash
# ===== TOKEN OPTIMIZATION =====

# Use smart context management on loop 2+ (don't re-send instructions, send rich context instead)
PROMPT_CACHING=true

# Reset session after N cumulative tokens (0 = disabled)
# Default 800K uses 80% of the 1M context window before compacting
SESSION_COMPACT_THRESHOLD=800000

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
ralph --no-prompt-caching        # Disable smart context (send full prompt every loop)
ralph --session-max-loops 10     # Reset session every 10 loops
ralph --compact-threshold 500000 # Lower compaction threshold
ralph --repo-map                 # Enable repo map
```

### Token Savings Tracker (raph-track)

`raph-track` provides detailed analytics on token savings:

```bash
raph-track              # Summary of token savings for current project
raph-track --live       # Real-time token tracking during a loop
raph-track --watch      # Continuous monitoring (refreshes every 5s)
raph-track --compare    # Side-by-side comparison: Raph vs baseline Ralph
raph-track --json       # Machine-readable output for pipelines
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

**Why "send better, not less"?**
The naive approach to token optimization is to send less. But Claude performs better with more context, not less. The 1M context window exists to be used. Instead of minimizing what we send, we replace wasted repeated instructions with genuinely useful context: what changed (git diff), what's broken (test results), what's available (file tree), and what to work on next (task groupings).

**Why 800K instead of 200K?**
The 200K threshold wastes 80% of the available context window. With a 1M context window, there's no reason to compact so aggressively. The 800K threshold lets Claude maintain much richer session history — more tool outputs, more file contents, more reasoning — while still leaving a 200K buffer for the compaction handoff and the next iteration's work.

**Why multi-task batching?**
Working on one task per loop means constant context switching. If 3 tasks all touch the auth module, Claude reads the same files 3 times across 3 loops. Batching related tasks means the files are loaded once and all 3 tasks benefit. The `suggest_task_groups()` function identifies tasks under the same fix_plan section and suggests grouping them.

**Why move PROMPT.md to system prompt instead of relying on session history?**
With `--resume`, Claude's session already has the PROMPT.md from loop 1. But Anthropic's prompt caching gives a 90% cost discount on system prompt prefixes. By putting PROMPT.md in `--append-system-prompt`, we get this discount on every loop.

**Why not just shorten PROMPT.md?**
The exit scenarios, status reporting format, and protected files instructions are all critical for Raph's autonomous operation. Removing them degrades exit detection and file safety. Moving them to a cached system prompt preserves quality while reducing cost.

**Why rolling summary instead of LLM summarization?**
LLM-based summarization (like OpenHands) requires an extra API call per loop. JetBrains research (NeurIPS 2025) found that observation masking outperforms LLM summarization in 4/5 settings while being cheaper. Raph's rolling summary + session rotation achieves similar results with zero extra API calls.

**Why not use `--compact` from Claude Code?**
The `--compact` command is only available in interactive mode. Raph runs in non-interactive (`-p`) mode. Session reset + handoff prompt achieves the same effect.
