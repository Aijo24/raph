# Raph

> **Ralph, minus a letter. The name is the compression.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Tests](https://img.shields.io/badge/tests-618%20passing-green)

Raph is a token-optimized fork of [Ralph for Claude Code](https://github.com/frankbria/ralph-claude-code) — an autonomous AI development loop that runs Claude Code in a continuous cycle until your project is complete.

The problem: Ralph sends the full PROMPT.md (~2,170 tokens) on **every** loop iteration and works on one task per loop. After 20 loops, that's 43K+ tokens wasted on repeated instructions and missed opportunities to batch related work. Raph fixes this with a philosophy: **don't send less, send better.** Replace wasted repeated instructions with useful context (git diff, test results, file tree) and use the 1M context window aggressively.

## What Raph Adds

| Metric | Ralph | Raph | Savings |
|--------|-------|------|---------|
| User prompt per loop (2+) | 2,167 tokens | 284 tokens | **-86%** |
| 10-loop cumulative | 21,677 tokens | 4,728 tokens | **-78%** |
| System prompt cost (2+) | full price | 90% cached | **-90%** |
| Context growth | unbounded | auto-compacts at 800K | **bounded** |
| Tasks per loop | 1 (serial) | 2-4 (batched) | **2-4x throughput** |
| Optimization overhead | — | 120ms/loop | **< 0.4%** |
| Output quality | baseline | identical | **0% loss** |

All optimizations are **on by default** and **backward-compatible**. Set `PROMPT_CACHING=false` in `.ralphrc` to get exact Ralph behavior.

## How It Works

**Loop 1** — full PROMPT.md sent as user message (same as Ralph):
```
claude -p "Full PROMPT.md (8,671 chars)" --append-system-prompt "Loop context"
```

**Loop 2+** — instructions already in session, sends rich context instead:
```
claude -p "Git diff: +45/-12 lines. Tests: 3 passing, 1 failing (auth.test.ts:42).
           File tree: src/ (6 files). Remaining: 5 tasks.
           Suggested batch: auth middleware + auth tests + auth docs (same module)." \
       --append-system-prompt "Full PROMPT.md (cached at 90% discount) + Loop context"
```

The continuation prompt replaces repeated instructions with useful context: git diff of recent changes, test results, file tree, work history, and task grouping suggestions. All static instructions (status reporting, exit scenarios, protected files, testing guidelines) are in the system prompt where the API provider caches them.

## 6 Optimization Layers

### 1. Prompt Caching (default: on)
Loop 2+ sends a 284-token continuation prompt instead of the 2,170-token full PROMPT.md. Static instructions move to `--append-system-prompt` for API-level cache hits.

### 2. Session Compaction (default: 800K threshold)
Uses the 1M context window aggressively. Auto-resets the session with a thorough handoff (work history, git log, remaining tasks, file tree) when tokens exceed the threshold — like OpenHands' conversation condensation, but with zero extra API calls.

### 3. Rolling Work Summary (always on)
Maintains a bounded 2,000-char history of completed work across loops. Survives session resets for continuity.

### 4. Active Fix Plan Filtering (always on)
Continuation prompts inline only uncompleted `- [ ]` tasks. Completed items are excluded. Saves a tool call.

### 5. Continuation Effort Level (opt-in)
Use `CONTINUATION_EFFORT=low` in `.ralphrc` to reduce reasoning effort on loop 2+.

### 6. Lightweight Repo Map (opt-in)
Generates a cached function/class signature map (JS/TS, Python, bash, Go, Rust) included in the system prompt. Enable with `REPO_MAP=true`.

## Multi-Task Planning

Ralph works on one task per loop. Raph batches 2-4 related tasks per loop using `suggest_task_groups()`:

```
## Suggested task group (shared context: auth module)
- [ ] Implement JWT auth middleware
- [ ] Write auth middleware tests
- [ ] Add auth error handling

These tasks share the same module context. Working on them together
avoids re-reading the same files across 3 separate loops.
```

The function reads `fix_plan.md`, identifies tasks under the same section heading, and suggests grouping them in the continuation prompt. Claude decides whether to accept the grouping or work on tasks individually.

This is not forced batching — it's a suggestion. Claude still reports `TASKS_COMPLETED_THIS_LOOP` accurately, and the circuit breaker and exit detection work the same way.

## Quick Start

```bash
# Clone and install
git clone https://github.com/Aijo24/raph.git
cd raph
./install.sh

# Set up a project
cd my-project
ralph-enable

# Run with token optimization (on by default)
ralph --monitor
```

## Configuration

Add to `.ralphrc`:

```bash
# Token optimization (all optional — defaults are sensible)
PROMPT_CACHING=true              # Short continuation prompts on loop 2+ (default)
SESSION_COMPACT_THRESHOLD=800000 # Reset session after 800K tokens (default, uses 1M window aggressively)
SESSION_MAX_LOOPS=0              # Reset session after N loops (0=disabled, default)
CONTINUATION_EFFORT=             # Effort for loop 2+ (empty=same as primary)
REPO_MAP=false                   # Lightweight repo map (default: off)
REPO_MAP_MAX_TOKENS=1500         # Max chars for repo map
```

CLI flags:

```bash
ralph --no-prompt-caching        # Disable (send full prompt every loop)
ralph --session-max-loops 10     # Reset every 10 loops
ralph --compact-threshold 500000 # Custom token threshold
ralph --repo-map                 # Enable repo map
```

## Monitoring

The dashboard shows session token usage:

```
┌─ Current Status ─────────────────────────┐
│ Loop Count:     #12                       │
│ Status:         running                   │
│ API Calls:      12/100                    │
│ Session Tokens: 85000 / 800000 (10%)      │
└───────────────────────────────────────────┘
```

Warnings are logged as tokens approach the threshold:
```
[INFO]  Session tokens at 50% of threshold (400000/800000)
[WARN]  Session tokens at 75% of threshold (600000/800000)
[WARN]  Session tokens at 90% of threshold (720000/800000). Compaction imminent.
```

## Quality Guarantee

26 tests verify that Claude receives **identical instructions** on every loop regardless of optimization mode:

- All 6 RALPH_STATUS fields present
- All 6 exit scenarios present
- All 3 status examples present
- Protected files warning present
- Testing guidelines present
- Key principles present
- File structure section present

The optimization changes **where** instructions are delivered (system prompt vs user message), not **what** is delivered.

## Test Suite

```bash
npm test    # 618 tests
```

111 new tests across 5 files covering token optimization:

| File | Tests | What it covers |
|------|-------|----------------|
| `test_token_optimization.bats` | 32 | Prompt caching, continuation prompts, effort, fix plan, repo map |
| `test_session_compaction.bats` | 20 | Token tracking, compaction triggers, handoff, summary preservation |
| `test_token_savings.bats` | 15 | Measured savings with real PROMPT.md template |
| `test_performance.bats` | 18 | Execution time budgets, overhead ratio, cache effectiveness |
| `test_quality_parity.bats` | 26 | All critical instructions present on every loop |

## Token Savings Tracker

Raph ships with `raph-track`, a tool for monitoring token savings across sessions:

```bash
raph-track              # Summary of token savings for current project
raph-track --live       # Real-time token tracking during a loop
raph-track --watch      # Continuous monitoring (refreshes every 5s)
raph-track --compare    # Side-by-side comparison: Raph vs baseline Ralph
raph-track --json       # Machine-readable output for pipelines
```

## Full Documentation

- **[Token Optimization Guide](docs/TOKEN_OPTIMIZATION.md)** — deep dive into all layers with benchmarks
- **[CLI Options Reference](docs/CLI_OPTIONS.md)** — every flag documented
- **[User Guide](docs/user-guide/)** — getting started, writing requirements, understanding files

## Everything Else from Ralph

Raph inherits all of Ralph's features:

- Autonomous development loops with intelligent exit detection
- Dual-condition exit gate (completion indicators + EXIT_SIGNAL)
- Rate limiting (calls/hour + tokens/hour)
- Circuit breaker with auto-recovery
- Session continuity with `--resume`
- Live streaming output with `--live`
- tmux integration for monitoring
- `ralph-enable` wizard for existing projects
- PRD import from markdown, text, JSON, Word, PDF
- `.ralphrc` project configuration
- File protection (prevents Claude from deleting .ralph/)
- 5-hour API limit handling with auto-wait

See the [upstream Ralph documentation](https://github.com/frankbria/ralph-claude-code) for details on these features.

## Credits

- [Ralph for Claude Code](https://github.com/frankbria/ralph-claude-code) by Frank Bria — the original autonomous loop
- [Ralph technique](https://ghuntley.com/ralph/) by Geoffrey Huntley — the concept
- Research from [Aider](https://aider.chat/docs/repomap.html) (repo maps), [OpenHands](https://docs.openhands.dev/sdk/guides/context-condenser) (condensation), [SWE-agent](https://swe-agent.com/latest/reference/history_processor_config/) (observation masking), and [JetBrains Research](https://blog.jetbrains.com/research/2025/12/efficient-context-management/) (masking vs summarization benchmarks)

## License

MIT — same as upstream Ralph.
