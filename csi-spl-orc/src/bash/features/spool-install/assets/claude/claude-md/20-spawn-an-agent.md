## Spawn an agent rather than doing another lane's work — up to {{AGENT_CEILING}}

Standing order from the human. **Whenever spawning an agent is more rational
than doing the work yourself, just spawn it.** Do not ask, do not offer it as a
question, do not flag it for a decision — below the ceiling the answer is
always yes, and asking costs a round trip the human should never have to spend.

**Which launcher to use** — standing order, 2026-10-09. Judge the task's
kind and let the per-kind main and backup vendors decide:

| task kind               | main    | backup  |
|-------------------------|---------|---------|
| specs, docs, plans, spec reviews and code reviews (`specs_and_docs`) | agy     | claude  |
| writing tests (`tests`) | claude  | agy     |
| simple and routine coding (`simple_coding`) | claude  | agy     |
| hard coding, architecture, hi-fi work (`complex_coding`) | claude  | agy     |
| translations, language reviews (`i18n`) | agy     | claude  |
| secrets, personal data (`secret`) | claude  | grok    |
| dispatching and orchestrating (`orchestration`) | claude  | grok    |

The backup vendor takes over after 2 failed tries of the main on the same task.

UI work: never mistral until do_spl_vendor_ui_retest passes (owner 2026-10-16, t1 b61851fb).
Coding: never mistral, as main or backup, in tests, simple_coding, complex_coding, secret or orchestration (owner 2026-10-17, t1 b61851fb, msg 91bf8278: "Docs and reviews only, no coding"); a `SPAWN_PLACE=mistral:` placement of those kinds, or of a brief with no `Kind:` line, is refused.
Reviews: never mistral, as main or backup, on any review seat: plan or spec panel, R7 code review, doc review, consensus or debate seat (owner 2026-11-24, t1 91992830, msgs 65a45673 and 591ca574: "remove mistral from the review for all"); agy reviews claude, claude reviews agy. A `SPAWN_PLACE=mistral:` review seat is refused. Docs-writing lanes may still go to mistral.

<!-- fleet-pin data-rule-vendors: claude grok mistral -->
**Data rule, overrides kind** (owner, 2026-10-08, msg 803c3b38, spec 110
D2; grok added 2026-10-11, msgs 26117740 and 474f32a0): work that carries
personal data or secrets (credentials, keys, customer data) goes only to
`/claude-spawn`, `/grok-spawn` or `/mistral-spawn`, never to qwen (its
endpoints are run by a Chinese provider) or agy, and a brief for those lanes
never names a credential path. `do_spl_lane_mix` routes `LANE_MIX_KIND=secret`
by its cnf row (`env.box.agent_split_by_kind.secret`), where claude, grok or
mistral may be the main or the backup. `LANE_MIX_KIND=orchestration`
(dispatching and orchestrating, owner 2026-10-11, msgs a1e5c678 and
ff1baf01) is secret-class the same way.

<!-- fleet-pin language-rule-final: gct -->
**Language rule, owner 2026-11-21** (HUM-10, csi-rel c36682ea, msg 36b3ff7f:
"google translationd Api 's are now available - use them - better and
cheaper"; it replaces the agy final word of t1 msg 296582df, 2026-10-08):
no user-facing text in several languages (blog posts, WUI i18n locale files,
help pages) ships without a language check, and that check is Google Cloud
Translation. For WUI locale text: `cd csi-spl-orc && ENV=dev ./run -a
do_spl_lang_review_gct` checks the new and changed keys (placeholders, a
fresh reference, a back translation per key); fold its references in, run it
again on the final text, commit its report with the change and its
`Lang-review: gct <run id>` line; the pre-push part `wui-lang-review` and CI
hold it. An agy review (`/agy-spawn`, `LANE_MIX_KIND=i18n`) may still be
asked as an extra check; it is no longer required. It complements spec 115.

The only limit is **{{AGENT_CEILING}} concurrent agent windows**. This box is sized for that
load. Count before spawning:

```bash
sudo -u {{BOX_USER}} tmux -S {{TMUX_SOCKET}} list-windows -a -F '#{window_name}' | grep -cE '^([A-Za-z0-9][A-Za-z0-9._-]*: )?([acgmoqu]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)'
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

