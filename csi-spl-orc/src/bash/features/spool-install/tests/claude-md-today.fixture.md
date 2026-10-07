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

The only limit is **40 concurrent agent windows**. This box is sized for that
load. Count before spawning:

```bash
sudo -u box-user tmux -S /tmp/tmux-box/default list-windows -a -F '#{window_name}' | grep -cE '^([A-Za-z0-9][A-Za-z0-9._-]*: )?([acgq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)'
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
and then invokes `/claude-spawn` or `/qwen-spawn`, which handle the worktree,
the inbox dirs and the seed prompt. Invoke a launcher directly only when you
have already decided which one.

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
<!-- spool-install: end claude-md sha256=a3fe6df4294d2c9a4e45b4976d99a4b5a2451bf7761d288794ff3c95f3b44896 -->
<!-- fragment org/55-personal -->
## Personal rule

keep me
<!-- /fragment -->
