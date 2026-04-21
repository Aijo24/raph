# Raph

> **Ralph, minus a letter. The name is the compression.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Tests](https://img.shields.io/badge/tests-618%20passing-green)

Raph is a token-optimized fork of [Ralph for Claude Code](https://github.com/frankbria/ralph-claude-code) — an autonomous AI development loop that runs Claude Code in a continuous cycle until your project is complete.

The problem: Ralph sends the full PROMPT.md (~2,170 tokens) on **every** loop iteration. After 20 loops, that's 43K+ tokens wasted on repeated instructions. Raph fixes this.

## What Raph Adds

| Metric | Ralph | Raph | Savings |
|--------|-------|------|---------|
| User prompt per loop (2+) | 2,167 tokens | 284 tokens | **-86%** |
| 10-loop cumulative | 21,677 tokens | 4,728 tokens | **-78%** |
| System prompt cost (2+) | full price | 90% cached | **-90%** |
| Context growth | unbounded | auto-compacts | **bounded** |
| Optimization overhead | — | 120ms/loop | **< 0.4%** |
| Output quality | baseline | identical | **0% loss** |

All optimizations are **on by default** and **backward-compatible**. Set `PROMPT_CACHING=false` in `.ralphrc` to get exact Ralph behavior.

## How It Works

**Loop 1** — full PROMPT.md sent as user message (same as Ralph):
```
claude -p "Full PROMPT.md (8,671 chars)" --append-system-prompt "Loop context"
```

**Loop 2+** — static instructions cached in system prompt, short continuation in user message:
```
claude -p "Continue working. Remaining: 5 tasks. Recent: auth module done." \
       --append-system-prompt "Full PROMPT.md (cached at 90% discount) + Loop context"
```

The continuation prompt contains only what changed: active tasks, work history, corrective guidance. All static instructions (status reporting, exit scenarios, protected files, testing guidelines) are in the system prompt where the API provider caches them.

## 6 Optimization Layers

### 1. Prompt Caching (default: on)
Loop 2+ sends a 284-token continuation prompt instead of the 2,170-token full PROMPT.md. Static instructions move to `--append-system-prompt` for API-level cache hits.

### 2. Session Compaction (default: 200K threshold)
Tracks cumulative session tokens. Auto-resets the session with a work summary handoff when tokens exceed the threshold — like OpenHands' conversation condensation, but with zero extra API calls.

### 3. Rolling Work Summary (always on)
Maintains a bounded 2,000-char history of completed work across loops. Survives session resets for continuity.

### 4. Active Fix Plan Filtering (always on)
Continuation prompts inline only uncompleted `- [ ]` tasks. Completed items are excluded. Saves a tool call.

### 5. Continuation Effort Level (opt-in)
Use `CONTINUATION_EFFORT=low` in `.ralphrc` to reduce reasoning effort on loop 2+.

### 6. Lightweight Repo Map (opt-in)
Generates a cached function/class signature map (JS/TS, Python, bash, Go, Rust) included in the system prompt. Enable with `REPO_MAP=true`.

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
SESSION_COMPACT_THRESHOLD=200000 # Reset session after 200K tokens (default)
SESSION_MAX_LOOPS=0              # Reset session after N loops (0=disabled, default)
CONTINUATION_EFFORT=             # Effort for loop 2+ (empty=same as primary)
REPO_MAP=false                   # Lightweight repo map (default: off)
REPO_MAP_MAX_TOKENS=1500         # Max chars for repo map
```

CLI flags:

```bash
ralph --no-prompt-caching        # Disable (send full prompt every loop)
ralph --session-max-loops 10     # Reset every 10 loops
ralph --compact-threshold 100000 # Custom token threshold
ralph --repo-map                 # Enable repo map
```

## Monitoring

The dashboard shows session token usage:

```
┌─ Current Status ─────────────────────────┐
│ Loop Count:     #12                       │
│ Status:         running                   │
│ API Calls:      12/100                    │
│ Session Tokens: 85000 / 200000 (42%)      │
└───────────────────────────────────────────┘
```

Warnings are logged as tokens approach the threshold:
```
[INFO]  Session tokens at 50% of threshold (100000/200000)
[WARN]  Session tokens at 75% of threshold (150000/200000)
[WARN]  Session tokens at 90% of threshold (180000/200000). Compaction imminent.
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

## Full Documentation

- **[Token Optimization Guide](docs/TOKEN_OPTIMIZATION.md)** — deep dive into all 6 layers with benchmarks
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
