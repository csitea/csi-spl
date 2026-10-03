## Spawn an agent rather than doing another lane's work — up to {{AGENT_CEILING}}

Standing order from the human. **Whenever spawning an agent is more rational
than doing the work yourself, just spawn it.** Do not ask, do not offer it as a
question, do not flag it for a decision — below the ceiling the answer is
always yes, and asking costs a round trip the human should never have to spend.

**Which launcher to use** — standing order, 2026-08-28. Judge the task's
difficulty against your own maximum capacity:

| your difficulty estimate | launcher |
|---|---|
| **< 60%** of what you could handle | `/qwen-spawn` |
| **>= 60%**, or you are unsure | `/claude-spawn` |

Cheap, well-specified, mechanically-bounded work goes to qwen (the cheap lane);
architectural, ambiguous, or correctness-critical work goes to claude. **Data rule, overrides difficulty:** qwen's endpoints are
run by a Chinese provider — work that carries personal data or secrets
(credentials, keys, customer data) always goes to `/claude-spawn`, and a QWN
brief never names a credential path. When the estimate sits
near the line, treat that uncertainty as evidence the task is harder than it
looks and use `/claude-spawn`.

The only limit is **{{AGENT_CEILING}} concurrent agent windows**. This box is sized for that
load. Count before spawning:

```bash
sudo -u {{BOX_USER}} tmux -S {{TMUX_SOCKET}} list-windows -a -F '#{window_name}' | grep -cE '^([A-Za-z0-9][A-Za-z0-9._-]*: )?([acgq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)'
```

The optional `<tag>: ` group is the box tag (`$BOX_TAG`, e.g. `{{BOX_TAG}}`) that
decorates agent window and session names. Anchored on `CLE-` alone this count
skips every tagged window — it read 5 of 20 live agents on 2026-09-10.

At {{AGENT_CEILING}} or more: finish it yourself, or close a finished agent first, and say
which you did. Below {{AGENT_CEILING}}, spawning is the default rather than an escalation.

The trigger is **"this is a different lane from my brief and nobody owns it"**,
not "this is big" — a one-file fix in someone else's lane still spawns. Before
writing the brief, read `git -C <repo> worktree list` so the new scope is
disjoint from every live agent, and name in the brief the files it must NOT
touch. Route follow-ups to that agent through `inbox-send.sh` instead of
absorbing them yourself.

**`/spawn-an-agent` is the front door** — it applies the table above, checks
the {{AGENT_CEILING}}-agent ceiling, keeps the new scope disjoint from every live worktree,
and then invokes `/claude-spawn` or `/qwen-spawn`, which handle the worktree,
the inbox dirs and the seed prompt. Invoke a launcher directly only when you
have already decided which one.

