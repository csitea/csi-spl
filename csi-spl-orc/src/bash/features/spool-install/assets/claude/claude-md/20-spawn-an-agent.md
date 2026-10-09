## Spawn an agent rather than doing another lane's work — up to {{AGENT_CEILING}}

Standing order from the human. **Whenever spawning an agent is more rational
than doing the work yourself, just spawn it.** Do not ask, do not offer it as a
question, do not flag it for a decision — below the ceiling the answer is
always yes, and asking costs a round trip the human should never have to spend.

**Which launcher to use** — standing order, 2026-10-09. Judge the task's
kind and let the per-kind main and backup vendors decide:

| task kind               | main    | backup  |
|-------------------------|---------|---------|
| specs, docs, plans, reviews (`specs_and_docs`) | agy     | claude  |
| writing tests (`tests`) | claude  | mistral |
| simple and routine coding (`simple_coding`) | mistral | claude  |
| hard coding, architecture, hi-fi work (`complex_coding`) | claude  | mistral |
| translations, language reviews (`i18n`) | agy     | claude  |
| secrets, personal data (`secret`) | claude  | mistral |

The backup vendor takes over after 2 failed tries of the main on the same task.

<!-- fleet-pin data-rule-vendors: claude mistral -->
**Data rule, overrides kind** (owner, 2026-10-08, msg 803c3b38, spec 110
D2): work that carries personal data or secrets (credentials, keys, customer
data) always goes to `/claude-spawn` or `/mistral-spawn`, never to qwen, grok or agy.
The backup for `secret` is mistral, and the work is never routed to agy, grok, or qwen.

<!-- fleet-pin language-rule-final: agy -->
**Language rule, owner 2026-10-08** (t1 msg 296582df: "there the final word
on the actual content should have the agy - because he is BEST with
languages"): agy has the final word on multilingual text. Any user-facing text
in several languages (blog posts, WUI i18n locale files, help pages) gets an
agy review as the LAST step before it ships: `/agy-spawn`
(`LANE_MIX_KIND=i18n`). It complements spec 115. With no agy on the box, claude
drafts and the text waits for an agy review; it never ships unreviewed.

The only limit is **{{AGENT_CEILING}} concurrent agent windows**. This box is sized for that
load. Count before spawning:

```bash
sudo -u {{BOX_USER}} tmux -S {{TMUX_SOCKET}} list-windows -a -F '#{window_name}' | grep -cE '^([A-Za-z0-9][A-Za-z0-9._-]*: )?([acgmq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)'
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
and then invokes `/claude-spawn`, `/mistral-spawn`, or `/agy-spawn`, which handle the worktree,
the inbox dirs and the seed prompt. Invoke a launcher directly only when you
have already decided which one.

