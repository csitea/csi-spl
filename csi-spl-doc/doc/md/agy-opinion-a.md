# Antigravity (Gemini) Agent Opinion: Token Minimization & Focus

> Generated from qto doc `96934cbb-080d-4d80-a80a-659c8631eb46`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Review of `csi-spl-doc/doc/md/agent-token-focus-plan.md` (c-077, sha `b0888ab8`).

<a id="ws-doc-ea5c45e3-6ea8-4366-b0b2-c6e8aa606357"></a>
## 1. Gemini CLI Experience vs Claude
- **Context window vs attention dilution**: Gemini's 1M+ token window prevents hard context limits, but large context dilutes instruction compliance (e.g., commit leak-gates, narrow scopes) and inflates turn latency.
- **Where context goes**: AGY preambles load system instructions, skill catalogs, and subagent specs alongside repo docs. Every command output (logs, banners, map sweeps) is re-sent in full across subsequent turns.
- **Claude vs Gemini differences**: Claude needs `/compact` to survive 200k limits. Gemini handles long turns better, but in-session compaction discards crucial guardrails and risks hallucinated state; fresh agent restarts are vastly cleaner.

<a id="ws-doc-2348dc30-1796-42e4-a2d9-b7bf18f8c731"></a>
## 2. Disagreements with `agent-token-focus-plan.md`
- **Brief size dismissal**: The plan claims briefs (median 3.2 KB) are "not a driver". In practice, brief quality directly drives token usage: rambling or multi-step briefs trigger scope drift and wasted command loops. Clean, single-task briefs keep agents focused.
- **Compaction reliance**: Compacting a running agent rarely restores crispness. Fresh lane spawning with a minimal handoff is superior to running `/compact` and nursing an aging session.

<a id="ws-doc-c8f46a17-7ac9-452e-b6bd-f8f43cf385d7"></a>
## 3. Top 5 Recommendations
1. **Fresh lanes over in-session compaction**: Retire agents after one task; never reuse worker lanes across tasks. Clean worktrees and clean context guarantee adherence to protocols.
2. **Quiet tool outputs (implement first)**: Strip ANSI escapes, banners, and debug noise from `./run`; make `lane-map --check` return a single verdict line. High-frequency tool output is the biggest recurring token drain.
3. **Declarative seed prompts**: Remove historical anecdotes and post-mortem lore from seed prompts into referenced docs. State rules directly and concisely.
4. **Harness-isolated preambles**: Stop leaking Claude-specific files (`MEMORY.md`, global `CLAUDE.md`) or unrelated project rules into non-target lanes or Gemini sessions.
5. **Terse handovers & spool results**: Cap `result` bodies to ≤600 chars with links to git SHAs or files. Keep handovers deterministic and free of duplicated chatter.

<a id="ws-doc-bcab0bfb-e470-4181-9f8a-df5df08f9431"></a>
## 4. What to Do First and Why
Implement **Quiet Tool Outputs & Single-Line Lane-Map Check** first. It requires zero policy or prompt rewrites, touches only tooling, and immediately slashes token consumption across every active lane in the fleet on every single turn.
