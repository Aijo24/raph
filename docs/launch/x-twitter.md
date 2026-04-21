# X / Twitter

## Post 1 — Main launch (pair with screen recording of token counter dropping)

> your Claude Code loop is burning 43,000 tokens on repeated instructions
> 
> every loop sends the full prompt again
> 20 loops = 20 copies of the same text
> you're literally paying to re-read the manual
> 
> I built a fix that cuts this by 78%
> 
> loop 1: full instructions (2,167 tokens)
> loop 2+: tiny continuation (284 tokens)
> 
> the old instructions? cached in system prompt
> Anthropic gives you 90% discount on cached content
> you were leaving money on the table every single loop
> 
> 6 optimization layers:
> → prompt caching (86% smaller prompts)
> → session compaction (auto-reset before context blows up)
> → rolling work summary (bounded, survives resets)
> → active task filtering (skip done tasks)
> → continuation effort levels
> → lightweight repo map
> 
> 111 tests proving zero quality loss
> 26 tests proving Claude gets identical instructions
> 120ms overhead per loop
> 
> it's called Raph
> Ralph minus a letter
> the name is the compression
> 
> github.com/Aijo24/raph

## Post 2 — Technical hook (pair with before/after terminal screenshot)

> nobody talks about the real cost of autonomous coding loops
> 
> it's not the API calls
> it's not the rate limits
> it's the repeated prompts
> 
> I measured it:
> 
> 10 loops with Ralph = 21,677 tokens in prompts alone
> 10 loops with Raph = 4,728 tokens
> 
> same instructions
> same output quality
> 78% less cost
> 
> the trick: your prompt has two parts
> → static (never changes): exit rules, status format, guidelines
> → dynamic (changes each loop): which task, what was done
> 
> loop 1: send everything
> loop 2+: static goes in system prompt (cached at 90% off)
>          dynamic goes in a 284-token continuation
> 
> open source. 618 tests. drop-in replacement.
> 
> github.com/Aijo24/raph

## Post 3 — Curiosity gap (pair with screenshot of the savings table)

> I was mass consuming tokens for 8 months running autonomous Claude Code loops
> 
> then I measured where they actually go
> 
> 78% of prompt tokens were the same instructions copy-pasted into every loop
> 
> not the code
> not the responses  
> not the tool calls
> 
> the prompt
> 
> sent 20 times
> word for word identical
> 20 times
> 
> built a fix. open sourced it.
> 
> before: 2,167 tokens per loop
> after: 284 tokens per loop
> quality: identical (26 tests prove it)
> 
> github.com/Aijo24/raph
