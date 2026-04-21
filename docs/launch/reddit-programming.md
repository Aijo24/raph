# Reddit — r/programming

## Title: Reducing token waste in autonomous AI coding loops — 78% fewer prompt tokens with 0% quality loss

Autonomous coding agents that loop (run LLM, analyze output, repeat) have a structural inefficiency that nobody seems to talk about: **they re-send the full instruction set on every iteration.**

I've been running one of these tools (Ralph, an autonomous loop for Claude Code) and decided to measure where the tokens actually go. The result: the 297-line PROMPT.md template (~2,170 tokens) gets appended as a new user message on every loop. With session continuity (`--resume`), that means the conversation accumulates N copies of identical instructions.

20 loops = 43K+ tokens on the same text. That's before any code, tool calls, or model responses.

## The fix (general approach, not tool-specific)

The idea is simple and applies to any looping agent:

1. **First iteration**: send full instructions as user message (establishes context)
2. **Subsequent iterations**: move static instructions to the system prompt (most API providers cache this prefix — Anthropic at 90% discount, OpenAI at 50%) and send only a short continuation message with what actually changed

The continuation message contains ~284 tokens: which tasks remain, what was done recently, any corrective guidance. All static content (exit conditions, output format, safety rules, testing guidelines) is in the system prompt where it's cached.

## Additional layers

- **Session compaction**: track cumulative tokens per session, auto-reset when a threshold is exceeded. On reset, generate a "handoff" summary so the new session starts with context. This is OpenHands' conversation condensation approach but without the extra LLM call.
- **Observation masking via session rotation**: periodic session resets (every N loops) prevent unbounded growth from accumulated tool outputs. JetBrains Research found this outperforms LLM summarization in 4/5 settings while being simpler and cheaper.
- **Active task filtering**: instead of sending the full task file (including completed items), extract only uncompleted entries and inline them in the continuation message.
- **Repo map**: generate a compact function/class signature map from source files, include it in the cached system prompt so the model doesn't need to discover the codebase from scratch.

## Constraint: quality parity

The model must receive identical instructions regardless of optimization. This isn't something you can eyeball — you need tests. I wrote 26 that verify every critical directive (status reporting format with all 6 fields, all 6 exit scenarios, protected file warnings, testing guidelines) is present in the combined system+user prompt on every loop.

## Results

Measured with the real 297-line template, not a synthetic benchmark:

- 86% smaller user prompts on continuation loops (2,167 → 284 tokens)
- 78% cumulative reduction over 10 loops (21,677 → 4,728 tokens)
- 120ms processing overhead per loop (the LLM call itself takes 30-900 seconds)
- Zero quality degradation (26 parity tests)

## Code

Open source, MIT: https://github.com/Aijo24/raph

Technical writeup with all measurements: https://github.com/Aijo24/raph/blob/main/docs/TOKEN_OPTIMIZATION.md

The approach is informed by:

- [Aider](https://aider.chat/docs/repomap.html) — PageRank repo maps
- [OpenHands](https://docs.openhands.dev/sdk/guides/context-condenser) — conversation condensation
- [SWE-agent](https://swe-agent.com/latest/reference/history_processor_config/) — observation windowing
- [JetBrains Research](https://blog.jetbrains.com/research/2025/12/efficient-context-management/) — masking vs summarization benchmarks
