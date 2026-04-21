# LinkedIn

## Post (pair with savings table screenshot or terminal recording)

I was mass consuming tokens running autonomous Claude Code loops.

Then I measured where they actually go.

78% were the same prompt. Sent over and over. Every single loop. Word for word identical.

Not the code. Not the responses. Not the tool calls.

The prompt.

20 loops = 20 copies of 2,167 tokens = 43,000 tokens on instructions the model already has.

So I built a fix and open-sourced it:

Loop 1: full instructions (2,167 tokens)
Loop 2+: short continuation (284 tokens)

The old instructions? Moved to system prompt. API caches them at 90% discount.

Results:
- 86% smaller prompts per loop
- 78% reduction over 10 loops
- 120ms overhead (the LLM call takes minutes)
- Zero quality loss (26 tests prove identical instructions)

5 additional layers: session compaction, rolling work summaries, active task filtering, continuation effort levels, lightweight repo maps.

618 tests. Fully backward compatible. MIT licensed.

Based on research from OpenHands, Aider, SWE-agent, and JetBrains Research.

It's called Raph. Ralph minus a letter. The name is the compression.

github.com/Aijo24/raph

#OpenSource #AI #DeveloperTools #LLM #CostOptimization
