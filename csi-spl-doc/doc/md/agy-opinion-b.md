# Antigravity (Gemini) Opinion: Context Lifecycle, Restarts, and Handovers

Review of `specs/063-agent-context-lifecycle` from the perspective of an Antigravity (Gemini) CLI agent.

## Gemini vs Claude Differences
Gemini features a 1M+ token window with strong long-context needle retrieval, meaning instructions are rarely lost to context saturation. However, in CLI agent loops, large contexts heavily penalize turn latency (TTFT) and token cost, while accumulated bash/test outputs dilute focus. Where Claude degrades through attention drift around 200k, Gemini suffers through latency and noise accumulation. Clean restarts beat in-session summarization for both.

## Top 5 Recommendations

1. **Clean restart over in-session `/compact` every time**
   *Reason:* Model-written compaction is lossy, non-deterministic, and silently drops critical constraints (fileMode quirks, git identities, negative results). A fresh process seeded with structured state is faster, cleaner, and immune to prompt drift.

2. **Trigger lane restart at 200k tokens or 30 minutes, not 400k (disagree with R-L1)**
   *Reason:* 400k is tail-failure territory (11/130 lanes). A lane reaching 200k or working >30 min on a single task is almost always thrashing or rabbit-holing in command output. Force a green-commit checkpoint and restart/handover before latency spikes.

3. **Mandate explicit negative knowledge in handovers (`tried` + `failed`)**
   *Reason:* The costliest token sink after rotation is repeating dead-end approaches. In R-D1's `NOTES.md`, require explicit recording of what failed and why, alongside the immediate next step.

4. **Replace raw pane terminal scrapes with structured git and spool state (disagree with R-D1 row 2)**
   *Reason:* 60 lines of raw pane capture injects ANSI sequences, banner noise, and partial tool outputs. Replace with structured `git status --short`, unpushed commits, and the last spool message body.

5. **Kill and respawn on failed rotation; never inject `/compact` into wedged panes (disagree with R-R2)**
   *Reason:* Typing `/compact` via tmux into a failing or wedged process risks partial execution or hung processes. If rotation fails twice, kill the pane and spawn fresh from the hold state.

## Disagreements with Spec 063
- **R-L1 (400k lane restart):** Too permissive. 400k allows runaway sessions to burn tokens. Cap at 200k / 30 min.
- **R-R2 & 7.3 (`/compact` fallback):** In-place compaction is unreliable in automated fleet harnesses. Rely strictly on external restart.
- **R-D1 (Distil contents):** Strip raw terminal captures and general `tmux list-windows` for lanes. Keep lane distils strictly scoped to worktree, branch, unpushed commits, and NOTES.md.
