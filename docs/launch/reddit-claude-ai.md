# Reddit — r/ClaudeAI

## Title: I measured where Ralph actually burns tokens. 78% were wasted. Built a fix.

Been running Ralph (the autonomous Claude Code loop) for months. Started tracking where tokens actually go.

The result surprised me: **78% of prompt tokens are the same instructions sent over and over.**

The full PROMPT.md (~2,170 tokens) gets re-sent as a new user message on every single loop. With `--resume`, that means 20 loops = 20 copies of the same instructions sitting in the conversation history. You're paying Claude to re-read the same manual 20 times.

So I forked it and built an optimization layer. Called it **Raph** — Ralph minus a letter. The name is the compression.

## What it actually does

Loop 1: sends the full PROMPT.md normally (same as Ralph).

Loop 2+: static instructions (exit scenarios, status format, protected files, testing guidelines) move to `--append-system-prompt` where Anthropic **caches them at 90% discount**. The user message becomes a short ~284-token continuation prompt with just what changed: active tasks, work history, corrective guidance.

Claude sees the exact same instructions. They're just delivered through the system prompt (cached) instead of the user message (full price).

## Real measurements, not estimates

Used the actual PROMPT.md template from Ralph (297 lines, 8,701 bytes):

| Metric | Ralph | Raph | Savings |
|--------|-------|------|---------|
| User prompt per loop | 2,167 tokens | 284 tokens | **-86%** |
| 10-loop cumulative | 21,677 tokens | 4,728 tokens | **-78%** |
| System prompt (loop 2+) | full price | 90% cached | **-90% cost** |
| Quality | baseline | identical | **0% loss** |
| Overhead | — | 120ms/loop | **< 0.4%** |

## Other optimizations baked in

- **Session compaction**: tracks cumulative tokens per session, auto-resets at 200K with a work summary handoff. Like OpenHands' condensation but zero extra API calls.
- **Rolling work summary**: bounded 2K-char history of what was done. Survives session resets. No more "what did we do last loop?" amnesia.
- **Active fix plan filtering**: only sends uncompleted `- [ ]` tasks. Done items filtered out. Saves a tool call.
- **Continuation effort level**: set `CONTINUATION_EFFORT=low` in `.ralphrc` for cheaper reasoning on follow-up loops.
- **Lightweight repo map**: cached function/class signatures for JS/TS, Python, bash, Go, Rust. Claude doesn't need to discover your codebase from scratch every session.

## How I verified quality doesn't drop

This was the main concern. 26 tests verify Claude receives identical instructions on every loop:

- All 6 RALPH_STATUS fields present
- All 6 exit scenarios present
- All 3 status examples present
- Protected files warning present
- Testing guidelines present
- Key principles present

The optimization changes WHERE instructions are delivered, not WHAT.

## What it doesn't do

- No tiered model routing (no Opus for planning / Haiku for edits)
- No LLM-based summarization between loops (JetBrains research showed observation masking actually outperforms it in 4/5 settings)
- Doesn't change Claude's behavior or system prompt identity

618 tests total, 111 new. Backward compatible — `PROMPT_CACHING=false` to get exact Ralph behavior.

**Repo**: https://github.com/Aijo24/raph

**Technical deep-dive**: https://github.com/Aijo24/raph/blob/main/docs/TOKEN_OPTIMIZATION.md

Based on research from Aider (repo maps), OpenHands (condensation), SWE-agent (observation masking), and JetBrains (masking vs summarization benchmarks). Happy to answer questions.
