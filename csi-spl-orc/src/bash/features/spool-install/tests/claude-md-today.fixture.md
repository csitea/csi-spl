<!-- spool-install: begin claude-md (csi-spl fleet rules; edit spool-install/assets/claude/claude-md, not this block) -->
<!-- fragment spool-install/00-title -->
# Global Claude Code Instructions

<!-- /fragment -->
<!-- fragment spool-install/05-agents-run-as-agent-user -->
## Claude Code instances start as `agent-user` — verify every programmatic start

Standing order from the human, 2026-10-01. **Every Claude Code instance started
programmatically** (spawn, restore, resume, reopen, respawn-pane, a cron or
`@reboot` launcher, a hand-written launcher script) **runs as the OS user
`agent-user`**, unless the human explicitly states that this one must run as `box-user`.
`agent-user` and `box-user` are meant to be equivalent in access; the only difference is
that the human runs UI programs as `box-user`, so the `box-user` Claude login stays the
human's own and the agent fleet uses `agent-user`'s.

- Launch with `SPOOL_AGENT_USER=agent-user CLAUDE_BIN=/srv/agent-user/.local/bin/claude`
  (csi-spl harness), or `sudo su - agent-user --pty -c '…claude…'` by hand. Never
  `CLAUDE_BIN=/srv/box-user/.local/bin/claude` or `SPOOL_AGENT_USER=box-user` by default.
- Keep the agent inside its existing tmux window (`respawn-pane -k -t <pane-id>`
  for a restart) so the human can still navigate the fleet with tmux.
- **Check after every start**: this must print nothing.
  ```bash
  ps -u box-user -o pid=,args= | awk '$2 ~ /(^|\/)claude$/'
  ```
  It matches the claude binary itself, not launcher shells whose command
  line merely mentions claude. Any line is a box-user-owned agent: stop it, then restart it as `agent-user` (below).
- Moving a box-user session to `agent-user`: the transcript lives under the user that
  ran it. Copy `~box-user/.claude/projects/<slug>/<sid>.jsonl` (plus the `<sid>/`
  dir if present) to the same `<slug>` under `~agent-user/.claude/projects/`,
  chown `agent-user`, then `--resume <sid>` as `agent-user` from the same cwd.
  Recipe used 2026-10-01 for 14 agents:
  `/var/tmp/claude/restore-20261001-aiusr/restart-one.sh <ID>`.
- Why: on 2026-10-01 the whole csi-spl fleet had been launched as `box-user`, shared
  the human's gmail login, hit its weekly limit and stopped, while `agent-user`'s
  login had quota.

<!-- /fragment -->
<!-- fragment spool-install/07-permission-mode-bypass -->
## Permission mode — bypass only, everywhere

Standing order from the human, 2026-10-06. **The only permission mode allowed
on any box of the fleet is the most permissive one:
`--dangerously-skip-permissions` (`bypassPermissions`).** No
other `--permission-mode` value (auto, default, acceptEdits, plan or dontAsk)
anywhere: launchers, restore scripts, worktrees, settings, docs or tests.
This never changes.

- `/srv/agent-user/.claude/settings.json` and `/srv/box-user/.claude/settings.json`
  carry `permissions.defaultMode = bypassPermissions` and
  `skipDangerousModePermissionPrompt = true`; spool-install's
  `settings/00-fleet.json` re-asserts both on every install run.
- The same file sets `permissions.disableAutoMode = "disable"`: without it
  Claude Code (2.1.290+) offers every fresh seat "Make auto mode your default
  permission mode?" and the seat waits on it. It turns auto mode off, never
  bypass. Never answer Yes: that writes `defaultMode = "auto"`.
- A command-line `--permission-mode <x>` BEATS `defaultMode`, so every
  launcher passes `--dangerously-skip-permissions` itself; the setting only
  covers a bare `claude`.
- A long-lived wrapper loop (e.g. `restore-claude-plain.sh` in a pane) keeps
  the flags of the code it started with: after changing a launcher, kill the
  wrapper first, then its claude, then
  `IDENTITY_RESTORE_IDS=<id> DRY_RUN=0 ./run -a do_spl_agent_identity_restore`,
  which resumes the session with the current flags.
- Check after any start (must print nothing):
  ```bash
  ps -eo args= | awk '$1 ~ /(^|\/)claude$/' | grep -E -- '--permission-mode (auto|default|acceptEdits|plan|dontAsk)'
  ```
<!-- /fragment -->
<!-- fragment spool-install/10-push-and-deploy -->
## Push trunk and deploy both environments

Standing order from the human. When your work is ready to land:

1. `git fetch` + `git pull --rebase origin master` (or `main`), then **push directly to trunk**. No PR. No force-push.
2. **Deploy both `dev` and `prd`** with the project's deploy action. Do not wait for a second approval. Sequential if they share a build dir.
3. For csi-web-wui, use `ENV=dev` then `ENV=prd` `./run -a do_gcp_deploy_wui` from `csi-web-utl` with `APP_PATH=/opt/csi/csi-web ORG=csi APP=web CON_WUI=con-csi-web-wui`.

Still forbidden: force-push, hard-reset of trunk, deleting trunk.

<!-- /fragment -->
<!-- fragment spool-install/20-spawn-an-agent -->
## Spawn an agent rather than doing another lane's work — up to 40

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

The only limit is **40 concurrent agent windows**. This box is sized for that
load. Count before spawning:

```bash
sudo -u box-user tmux -S /tmp/tmux-box/default list-windows -a -F '#{window_name}' | grep -cE '^([A-Za-z0-9][A-Za-z0-9._-]*: )?([acgmoqu]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)'
```

The optional `<tag>: ` group is the box tag (`$BOX_TAG`, e.g. `box1`) that
decorates agent window and session names. Anchored on `CLE-` alone this count
skips every tagged window — it read 5 of 20 live agents on 2026-09-10.

At 40 or more: finish it yourself, or close a finished agent first, and say
which you did. Below 40, spawning is the default rather than an escalation.

The trigger is **"this is a different lane from my brief and nobody owns it"**,
not "this is big" — a one-file fix in someone else's lane still spawns. Before
writing the brief, read `git -C <repo> worktree list` so the new scope is
disjoint from every live agent, and name in the brief the files it must NOT
touch. Route follow-ups to that agent through `inbox-send.sh` instead of
absorbing them yourself.

**`/spawn-an-agent` is the front door** — it applies the table above, checks
the 40-agent ceiling, keeps the new scope disjoint from every live worktree,
and then invokes `/claude-spawn`, `/mistral-spawn`, or `/agy-spawn`, which handle the worktree,
the inbox dirs and the seed prompt. Invoke a launcher directly only when you
have already decided which one.

<!-- /fragment -->
<!-- fragment spool-install/22-ui-forms-for-user-input -->
## Ask a user for input with a UI form, never in prose

Standing order from the human, 2026-11-20 (HUM-10, t1 topic f4165bc3,
msg db4d2d0d-9e68-4620-b3c0-1d233eeeb02a): "A , stop once and for all to
propose me no forms questions !!! Write this into the global CLAUDE.md as
imperative, for any agent on any spool-hub box , whener it is using the UI it
must provide ui FORMS when asking for input from any iser".

- Every agent on every spool-hub box that asks ANY user for input in the UI
  (the owner, a member, a customer, in any workspace) asks with a UI form:
  a question, a choice, a yes/no, a go.
- The form is the `poll` block of `csi-spl-doc/doc/help/how-to-post.md`
  (section 7; grammar `csi-spl-wui/src/utils/poll.mjs`). Read it there; it
  is not restated here.
- Never prose options ("reply A or B", "(a) ... (b) ... say 1 or 2"), never
  a table of options, never a bare "shall I proceed?". Every choice is an
  option of the form; a go is a form too.
<!-- /fragment -->
<!-- fragment spool-install/25-stay-in-your-lane -->
## Stay in your own lane

Standing order from the human, 2026-10-09, for every agent and stated
explicitly for every Mistral (`m-`) seat: everyone stays in their own lane
and does their own work. The Bulgarian saying puts it this way:
„Всяка жаба да си знае гьола“ ("every frog should know its own pond").

- Do your brief and only your brief.
- Never touch another lane's files, topic or work. Before you edit a path,
  check it with `lane-map.sh --check <paths> --agent <you>`: exit 3 names the
  owning lane; exit 4 = `unknown:` lanes that recorded no files and have
  edits: ask them first, never treat it as free; exit 5 = `LOCAL-ONLY:`
  the hub did not answer, other machines unread: not free, ask c-001.
- A finding outside your lane goes to the orchestrator
  (`spool-send.sh --to orchestrator`). You never fix it yourself. The one
  exception is your seed's SCOPE (c): it blocks your own tests and nobody
  owns it.
<!-- /fragment -->
<!-- fragment spool-install/27-lane-issue-and-docs -->
## Every lane carries an issue; keep it and the docs current

Standing order from the human, 2026-10-12 (t1 5ea2e615): "the discussions to
be discussions, but the concrete decision on what needs to be done and the
tracking of the statuses must be reflected in the issues. The agents must be
updating those issues constantly and also making sure that the documentation
is kept up to date as well, just like a regular software project."

- A lane placed from a discussion has an issue: the spawn files it (or links
  the `Issue: <KEY>` line of the brief), status `wip`. A lane without an
  issue key does not start.
- No issue without an epic and a git spec (HUM-10, t1 7a98c2d1 msg 5863d0d6):
  a brief that files one carries a `Spec: csi-spl-doc/specs/<NNN-slug>` line
  (a folder on origin/master) and an `Epic: SPL-<n>` line; without them the
  enqueue and the issue filing refuse.
- Every discussion carries one issue, drafted with the owner, even when the
  work is an evaluation or answers the owner's questions (HUM-10, t1 5ea2e615 msg
  fe5ae542): "Maybe spawn one issue always, and the agents should discuss with
  me how to define the issue properly." File it with the first answer
  (`LANE_ISSUE_OP=discussion ./run -a do_spl_lane_issue`); acks, chatter and
  announcements file none.
- The issue holds condensed state (done, doing, next) and links the
  discussion; it does not become a discussion (msg f2c24a7b).
- Cite the key in every commit subject (`feat(orc, SPL-123): ...`). Only two
  forms close it on landing: a `fix|feat|perf|refactor` subject with the key
  in its scope, or a `Closes: SPL-123` trailer.
- A lane that ends without landing (dropped by its gate, superseded) ends its
  issue with the reason: `LANE_ISSUE_OP=end ./run -a do_spl_lane_issue`.
- A commit that changes behaviour lands with its `csi-spl-doc/` change, or
  says why not in a `Docs: none (<why>)` line.
- `/exit-clean` refuses a lane that breaks either of the last two.

How it is enforced: `csi-spl-doc/doc/md/lane-issue-and-docs.md`.
<!-- /fragment -->
<!-- fragment spool-install/28-wiki-designated-team-branch -->
## Never add or move a wiki page outside the owner's designated team branch

Standing order from the human, 2026-11-25 (msg 3d870d38): every agent on every
box MUST NOT create, add or move any wiki (Confluence) page outside the owner's
designated team branch of the wiki space unless the owner explicitly says so
for that page.

- **Designated branch only**: create and add wiki (Confluence) pages exclusively
  under the owner's designated team branch of the wiki space. Never create a
  page at the space root, under another team's branch, or anywhere outside that
  branch tree, and never move an existing page out of it.
- **Explicit owner override only**: the sole exception is when the owner
  explicitly instructs you to place or move that specific page outside the
  owner's designated team branch. A general request to document or publish
  content is never permission to write outside that branch.
- **Where the branch is named**: the real branch name and wiki space live only
  in box-local configuration or the seat brief, never in this public repository.
  If neither names the owner's designated team branch, stop and ask before
  creating or moving any wiki page.
<!-- /fragment -->
<!-- fragment spool-install/30-cross-lane-findings -->
## A cross-lane finding states three fields

Standing rule from 2026-08-28, learned the expensive way.

**What makes a wrong measurement costly is confidence, not error.** An uncertain
finding gets re-measured by whoever receives it. A confident, well-formatted one
gets **routed as work** — and a wrong one then allocates another agent's hours.

**Scope it narrowly or it becomes ceremony.** The trigger is *a finding that
asks someone else to change something* — not status, not a question, not "here
is what I did". The one-line test:

> **If your message would cause another agent to open a worktree, it states the
> version, the tree and the n.**

Where nobody is being asked to act there is no audit to make cheap, and the
fields are pure overhead. Worse, a rule that fires on every message trains
people to skim the header — which is exactly how a `prompt=v1.0` line got read
past twice by two careful agents on the day this rule was written.

So a qualifying measurement carries three fields:

| field | why |
|---|---|
| **the version / config it ran under** | a harness default of `v1.0` against a deployed `v1.3` inverted three case verdicts in one afternoon |
| **the tree or sha it ran on** | the receiver can only audit a claim if they can pin the tree and prove what it did and did not contain |
| **n** | separates *demonstrated* from *suggested*. Six clean samples against a true rate of 2-in-6 happen ~9% of the time — that is evidence of a lower rate, never proof of absence |

With those three, a receiving agent audits a finding in about a minute. Without
them the only way to check is to stand up a worktree and re-measure, which costs
an hour and which most agents will reasonably skip in favour of trusting the
sender. **That skipping is the failure mode** — not that a number was wrong, but
that it was not cheaply auditable enough to be worth auditing.

**Claims about a FILE are not covered by those three fields — cite the command
instead.** Do not write *"the README prints `--dataset-dir`"*; write
*"`grep -c dataset-dir README.md` -> 3"*. You cannot produce the second form
without running it, so the format enforces the check rather than your vigilance,
and it degrades honestly — if you will not run it, write *"I believe, unchecked,
that…"*, which warns the reader. This matters most when **relaying** someone
else's claim: the relayer has no memory of the file, only of someone sounding
sure.

Both rules are one rule: **make claims that carry their own check.**

Corollary: a control that can only detect what someone guessed in advance —
a `must_not_contain` ban list, a path filter, an allow-list — **cannot prove
absence**. Any confident claim that something is NOT happening has to come from
somewhere other than such a control.

<!-- /fragment -->
<!-- spool-install: end claude-md sha256=1fe07ed72ddb31246bf11f73099439348814b544e7c014aa45d30ec8c2cc9174 -->
<!-- fragment org/55-personal -->
## Personal rule

keep me
<!-- /fragment -->
