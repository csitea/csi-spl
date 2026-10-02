# spawn-agents — spool-native agent spawning

Starts Claude Code, grok, antigravity (agy) and Qwen Code (qwen) agents in their own tmux
windows, each with a spool agent id and a spool mailbox, and gives them the
spool protocol (`spool send` / `spool recv` / `spool tail`) as their way to
talk to each other.

This is a **fork** of the box engine's spawn-agents scripts. It was copied
and then adapted to the csi-spl specs. The original is a read-only reference.
Nothing here sources or calls it.

| spec | what it changes here |
|---|---|
| `specs/002-box-agent-messaging/contracts/local-folder-layout.md` | the root is `$SPOOL_ROOT`, default `/var/spool-hub`. Each agent gets `<id>/{inbox,outbox,archive}`, mode 0775 |
| `specs/002-.../contracts/message-schema.md`, `cli.md` | messages are `v:1` JSON objects written by `spool send`, not `.md` files |
| `specs/002-.../contracts/trust-modes.md` §2 | local mode is unsigned: the spawn creates no key and no pin, and messages carry no `sig`. The file is the record and the tmux poke is only a doorbell |
| `doc/md/SPEC-spool-identity-routing.md` §2 | ids match `^[A-Z]{2,4}-[0-9]+$`, are unique per box, and never use the `BOX` prefix. CLE/GRK/AGY/QWN belong to claude/grok/agy/qwen |

Some behaviour is box-level rather than spec-level, so it is kept exactly as
the reference does it:

- **tmux visibility.** Windows are created with `new-window -d` in the session
  the box user's client is attached to. No spawn ever runs `select-window`.
- **Isolation.** Each agent gets its own git worktree, `<repo>-wt/<ID>`, on a
  branch off `origin/<trunk>`.
- **Lane map.** Each spawn writes the agent's row (`<ID>@<box>`, repo, branch,
  scope, files, topic) into the fleet-wide lane map on the hub, and the seed
  prompt's scope check reads that map, not `git worktree list` (section 3.11).
- **Seed prompt.** It carries the scope, integration and leak-gate blocks.
- **Run-as hop.** Agents run as the agent user.
- **Kept-open pane.** When the agent exits, its pane stays open.

## 1. Layout

| path | role |
|---|---|
| `lib/spool-env.inc.sh` | the one resolver: env vars, users, tmux socket, binaries, the id rules, pane lookup |
| `lib/spool-notify.inc.sh` | the one renderer and doorbell (`specs/028-spool-terminal-delivery`): a message is made VISIBLE in the recipient's pane, under the safe-poke rules |
| `scripts/next-agent-id.sh` | allocates the next free id (`c-004`..`c-999`, a per-machine cursor that rolls `999 -> 004`, specs/061 §3.5) and claims it by `mkdir $SPOOL_ROOT/<id>`. `--claim <ID>` claims one exact id |
| `scripts/agent-id-retire.sh` | retires an id once its window is gone (specs/061 §3.6): spool dir to `.retired/`, registry row to `registry.retired.tsv` (the 24 h quarantine), identity record to `agents/retired/`. `/exit-clean` runs it via `tmux-close-window.sh --retire`; `./run -a do_spl_agent_id_retire` by hand |
| `scripts/spawn-window.sh` | creates the detached window and starts the launcher in it. Prints `<ID> <PANE>` |
| `scripts/spawn-{claude,grok,agy,qwen}.sh` | the per-CLI adapters |
| `scripts/spawn-core.inc.sh` | the shared launcher core |
| `scripts/spool-agent.sh` | start claude, grok, agy or qwen SEATED and MIRRORED (`specs/036-spool-terminal-mirror`): claims an id, names the window, seats a desk, gives the session the mirror hooks, then runs the CLI |
| `scripts/spool-mirror.py` | the terminal -> web UI DM mirror: the CLIs' `UserPromptSubmit` / `Stop` hook and its post (redacted, never echoing the web UI's own words) |
| `scripts/spool-harness.sh` | the standard box launcher (`specs/012-spool-box-api`): prepares an agent's spool dirs, checks the box identity, starts the hub sidecar in hub mode, injects `SPOOL_*`, then exec-s the agent CLI; with `--mirror` (every spawn and restore passes it) it also gives the session the terminal mirror hooks |
| `lib/spool-mirror-hooks.inc.sh` | the mirror hook writers (claude `--settings` file, grok / agy / qwen hook files), shared by `spool-agent.sh` and `spool-harness.sh --mirror` |
| `scripts/agent-mirror-check.py` | per live agent: mirrored yes/no and why (`./run -a do_spl_agent_mirror_check`) |
| `scripts/spool-send.sh` | runs `spool send` and then shows the message in the recipient's tmux pane. It replaces `inbox-send.sh` |
| `scripts/spool-notify.sh` | shows a message that is ALREADY in an inbox. This is what `SPOOL_NOTIFY_CMD` points at, so the hub sidecar (cross-box, and a human's WUI task) reaches the terminal too |
| `scripts/riname.sh` | renames an agent's window by id (`--agent <ID>`) |
| `scripts/trust-workdir.sh` | pre-accepts each CLI's "trust this folder?" dialog |
| `scripts/agent-send.sh` | one send command for every live agent: the spool for this harness's agents, the older markdown inbox (through its own sender, `SPOOL_LEGACY_SEND`) for agents spawned before a switch-over (specs/048) |
| `scripts/agent-inbox.sh` | the reports an orchestrator has not seen yet, from its spool inbox and (with `SPOOL_LEGACY_INBOX_ROOT`) the older agents' outboxes |
| `scripts/pane-scan.sh` | census of every agent prompt: RESIDUE (a poke stuck unsent; must be 0), TYPED (unsent text; never poked), clear |
| `scripts/agent-watch.sh` | one line per agent pane that needs someone (DIALOG, TYPED), and a shell-inert nudge for an idle agent with unread mail; `--once` |
| `scripts/restore-{claude,claude-plain,grok,agy,qwen}.sh`, `scripts/restore-core.inc.sh` | resume a session after a restart, in the dir it ran in, through spool-harness, with a re-orientation kick |
| `scripts/spawn-{claude,grok}-{chain,task}.sh` | briefs in sequence in one window (commit, never push), or one brief that commits and pushes |
| `scripts/kill-your-self-report.sh` | read-only close-out discovery for `/exit-clean` |
| `scripts/tmux-sort-windows.sh` | keeps the window bar in natural order, agents first, never moving the window you look at; the tmux snippet's hooks run it |
| `scripts/tmux-close-window.sh` | closes an agent's window by id, now or after it exits (`--defer`); never guesses the active window |
| `assets/commands/*.md`, `assets/skills/*/SKILL.md` | the slash commands and skills; `spool-install/install.sh` renders them into `~/.claude` (and `~/.qwen/skills`) |
| `scripts/agent-top.sh`, `lib/agent-state.inc.sh` | the fleet view (`agent-top.sh`), the tmux status line (`--status-line`: `agents N  >busy ?waiting !ended .idle`) and the window badges (`--badge-loop`); reads both the spool and, with `SPOOL_LEGACY_INBOX_ROOT`, the older markdown mailbox |
| `assets/tmux-agent-status.conf` | the status line, the badge loop and the window-access keys for a fleet; the installer fills in this checkout's path and prints its `source-file` line |
| `harness-parity.tsv` | where every file of the frozen box engine's feature went (specs/048) |
| `tests/run-all-tests.sh` | every test. Each one uses a throwaway root and a private tmux server |

## 2. Configuration

Everything is set through env vars. None of them bakes in a user, a host or a
box. The box config `$SPOOL_BOX_ENV` (default `$SPOOL_ROOT/box.env`) holds this
box's defaults for `SPOOL_AGENT_USER`, `SPOOL_RUN_AS_AGENT`, `SPOOL_AGENT_ID_RANGE`,
`SPOOL_DESK_BOX` and the `*_BIN` paths, so a spawn with no env still runs the agent as the right user; the
environment always wins over it.

| var | default |
|---|---|
| `SPOOL_ROOT` | `/var/spool-hub` |
| `SPOOL_BOX_USER` | the owner of `$SPOOL_ROOT`, else the current user. This user owns the tmux server |
| `SPOOL_AGENT_USER` | the box config, else `$SPOOL_BOX_USER`. The agent CLIs run as this user |
| `SPOOL_RUN_AS_AGENT` | `su-dash` (`sudo su - <agent>`), or `sudo-i` |
| `SPOOL_TMUX_SOCKET` | `/tmp/tmux-<uid of box user>/default` |
| `SPOOL_BOX_TAG` | empty. When set, window and claude session names read `<ID>@<tag>` (the owner's `<ID>@<box>` naming, specs/058; 3 letters preferred) |
| `SPOOL_NAME_STYLE` | `at`. `colon` writes the older `<tag>: <ID>`. Every parser reads both shapes |
| `SPOOL_ORCHESTRATOR_ID` | `CLE-00`. Spawned agents report to this id |
| `SPOOL_AGENT_ID_RANGE` | empty (the whole line). `<lo>-<hi>`: this machine allocates ids only inside that band, so two machines of one fleet never hand out the same id (`csi-spl-doc/specs/058-multi-machine-fleet`). Set it in the box config |
| `SPOOL_DESK_BOX` | `box-desk`. This machine's desk box id: every `DESK_BOX` / `AGENT_BOX` default of the desk actions and scripts reads it (`csi-spl-orc/lib/bash/funcs/spl-desk-box.func.sh`), so two machines of one fleet never seat the same box (the hub keeps one socket per box id; the last hello evicts the other). Set it in the box config |
| `SPOOL_LEGACY_INBOX_ROOT` `SPOOL_LEGACY_SEND` | unset. During a switch-over: the older markdown message root and its sender; `agent-send.sh` / `agent-inbox.sh` use them for agents spawned before it |
| `SPOOL_BIN` | `csi-spl-api/src/go/spool-hub-api/bin/spool`, else `spool` on `PATH` |
| `SPOOL_NOTIFY_CMD` | the notifier the spool binary runs after it writes a message into a local inbox. `spool-harness` sets it to `scripts/spool-notify.sh`; `off` disables it; unset = no terminal leg |
| `SPOOL_NOTIFY_BODY_MAX` `SPOOL_NOTIFY_LINE_MAX` | `600` / `1200` — the bounds on the pane line (`specs/028/contracts/poke-line.md`) |
| `CLAUDE_BIN` `GROK_BIN` `AGY_BIN` `QWEN_BIN` | `<agent home>/.local/bin/<cli>`, else the bare name |

## 3. Use

### 3.1 Build the spool binary

```bash
bash csi-spl-api/src/bash/build.sh
```

### 3.2 Spawn a claude agent with the next free id

#### 3.2.1 Set the agent user once per box

```bash
bash csi-spl-orc/src/bash/features/spawn-agents/scripts/box-config.sh SPOOL_AGENT_USER=<AGENT_USER>
```

#### 3.2.2 Spawn

The last argument is the branch slug. No env is needed once 3.2.1 is done.

```bash
bash csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-window.sh claude auto /opt/csi/csi-spl /path/to/brief.md short-slug
```

### 3.3 Spawn with an exact id in a non-git working dir

A working dir that is not a git checkout gets no worktree and no git closing
steps.

```bash
SPOOL_AGENT_USER=<AGENT_USER> bash csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-window.sh grok GRK-4442 /var/tmp/spool-work /path/to/brief.md
```

### 3.3.1 Start claude or grok seated and mirrored

Run it in a tmux pane on the box user's server. The id comes from `--as`, else
`MCP_BOT_AGENT_ID`, else the next free one; the web UI then reaches this
terminal as `<ID>@box-desk`, and every prompt and answer here is posted into
that DM.

```bash
bash csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-agent.sh claude
```

### 3.3.2 See the plan without changing anything

```bash
bash csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-agent.sh --dry-run --as CLE-4441 grok
```

### 3.3.3 Every spawn and restore is mirrored

`spawn-*.sh`, `restore-*.sh` and `do_spl_agent_identity_restore` start the CLI
through `spool-harness.sh --mirror`: every prompt typed in the terminal and
every final answer goes into the agent's DM `<ID>@box-desk` (redacted; tool
output never). The hook takes the id from the process env (`SPOOL_AGENT_ID`,
else `MCP_BOT_AGENT_ID`), never from a window name. It posts from the agent's
desk seat, and the desk reconcile cron seats every live agent window within
three minutes; until then, and for an agent with no seat, nothing is posted.

### 3.3.4 See which live agents are mirrored

```bash
./run -a do_spl_agent_mirror_check
```

### 3.3.5 Relaunch a running claude session with the mirror

A session started before the mirror keeps running without it. Close its
window (`tmux kill-window -t <its pane>`), then restore it from any pane: the
identity map's record gives its session and worktree, and the restore starts it
in a NEW window through `restore-claude*.sh`, which launches through
`spool-harness.sh --mirror` (`--resume <session>` and `--permission-mode auto`
kept). While its process is alive the action SKIPs it. Run it from a checkout
on trunk.

```bash
IDENTITY_RESTORE_IDS="CLE-002" DRY_RUN=0 ./run -a do_spl_agent_identity_restore
```

Then confirm the agent reads `yes`.

```bash
./run -a do_spl_agent_mirror_check
```

### 3.3.6 Switch the mirror off for the whole box

New launches get no hooks, and the hooks of live sessions post nothing.
Remove the file to switch it back on.

```bash
touch /var/spool-hub/.mirror-off
```

### 3.4 Send a task and show it in the peer's pane

```bash
bash csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh --from CLE-4441 --to GRK-4442 --kind task --body "ping"
```

### 3.4.1 Show a message that already landed in an inbox

The hub sidecar writes cross-box mail and a human's WUI task straight into
`$SPOOL_ROOT/<id>/inbox/`; this is the leg that puts it on the terminal.

```bash
bash csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-notify.sh --to GRK-4442 --from CLE-4441 --kind task --body "ping"
```

### 3.5 Read your inbox

```bash
SPOOL_ROOT=/var/spool-hub csi-spl-api/src/go/spool-hub-api/bin/spool recv --as GRK-4442 --ack
```

### 3.6 Show a thread

```bash
SPOOL_ROOT=/var/spool-hub csi-spl-api/src/go/spool-hub-api/bin/spool tail --task <task_id>
```

### 3.7 Prove the windows are visible

```bash
tmux -S "$SPOOL_TMUX_SOCKET" list-windows -a -F '#{window_name}'
```

### 3.8 Launch an agent CLI through the harness

Local mode needs no box key. In hub mode set `SPOOL_HUB_URL` and pass the box
with `--to-box`; the harness then needs `box-<box_id>.key` (0600) and starts
one `spool hub-run` per spool root. Exit codes: `specs/012-spool-box-api/contracts/spool-harness.md`.

```bash
bash csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-harness.sh --as CLE-4441 -- claude
```

### 3.9 Run the tests

```bash
bash csi-spl-orc/src/bash/features/spawn-agents/tests/run-all-tests.sh
```

### 3.9.1 What a spawned brief says about pushing

Every brief for a git checkout ends with the DEPLOY-GATE footer
(`spawn-core.inc.sh`, asserted by `tests/test-spawn-dry-run.sh`). It tells
the agent:

- run `./run -a do_check_pre_push` before every push, and again after the
  mandatory rebase. That covers the suites the push touches plus the lint
  parts (shellcheck, actionlint, hadolint, eslint-security, trufflehog and
  syntax, on the touched files only, at CI's pins).
- `./run -a do_install_lint_tools` installs a missing scanner.
- the hook is never bypassed outside an audited emergency.
- the scanner workflows (61..67, 85) on the pushed sha are checked, and a
  red one is fixed in the same lane.

### 3.9.2 Parallel spawns start trusted

`trust-workdir.sh --settle` makes each spawn take a box-wide lock
(`~/.spool-spawn-trust.lock`), write the trust entry, and verify that it reads
back (exit 3 if it does not). The spawn then holds the lock for
`TRUST_SETTLE_SECS` (default 6) while its CLI starts. A starting claude
rewrites `~/.claude.json` unlocked, and in a parallel batch that write dropped
a sibling's entry. Run the proof with:

```bash
bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-trust-parallel.sh
```

### 3.9.3 The trust hop never reads a pty

The hop to the agent user carries the trust script in its command line, not
on stdin, and takes no `--pty`: through `su --pty` stdin is the terminal, so a
piped script never reached python, which sat at `>>>` and the CLI never
started. Proof, and the check that no agent CLI runs as the box user:

```bash
bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-user-default.sh
```

```bash
bash csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-user-check.sh
```

### 3.10 The identity map: one record per agent

The map in `$SPOOL_ROOT/agents/` holds one `<ID>.json` per agent and an
`index.json`. The index hash changes exactly when a record changes. Every value
comes from the agent's **process**: `SPOOL_AGENT_ID`, its own session file or
resume argument, its cwd, and the tmux pane whose process tree holds it. A
window name or a registry row is never read as identity. Design:
`csi-spl-doc/doc/md/SPEC-agent-identity-map.md`.

#### 3.10.1 See what a record pass would change (dry run, the default)

```bash
./run -a do_spl_agent_identity_record
```

#### 3.10.2 Write the records and the index

```bash
DRY_RUN=0 ./run -a do_spl_agent_identity_record
```

#### 3.10.3 Compare the map with the live box (exit 1 on drift)

```bash
./run -a do_spl_agent_identity_check
```

#### 3.10.4 Is an agent alive (prints its pid)

```bash
bash -c '. csi-spl-orc/src/bash/features/spawn-agents/lib/agent-identity.inc.sh && ai_alive CLE-002'
```

#### 3.10.5 Name every agent window from the map (dry run, the default)

The name is `<ID>@<tag> [badge] <title>` (older windows: `<tag>: <ID> [badge] <title>`, still parsed). The title is the agent's own session
name (`/rename`), or the one `riname.sh` set. A window that took a neighbour's
name is put back. Plain windows are never touched.

```bash
./run -a do_spl_agent_identity_reconcile
```

#### 3.10.6 Apply the names

```bash
DRY_RUN=0 ./run -a do_spl_agent_identity_reconcile
```

#### 3.10.7 Install the per-minute cron line and the tmux hooks (dry run first)

```bash
./run -a do_spl_agent_identity_install
```

#### 3.10.8 Install them

```bash
DRY_RUN=0 ./run -a do_spl_agent_identity_install
```

#### 3.10.9 Remove them again (the rollback)

```bash
DRY_RUN=0 IDENTITY_UNINSTALL=1 ./run -a do_spl_agent_identity_install
```

#### 3.10.10 After a reboot: see which agents the map would start again (dry run)

Each agent the restart killed resumes its own session in its own worktree, in a
new window. A record that cannot be proven is refused and named.

```bash
./run -a do_spl_agent_identity_restore
```

#### 3.10.11 Start them

```bash
DRY_RUN=0 ./run -a do_spl_agent_identity_restore
```

### 3.11 The fleet-wide lane map: who owns what on every machine

`git worktree list` shows this machine's lanes only, so with agents on two
machines (`csi-spl-doc/specs/058-multi-machine-fleet`, G4) a scope check on
one machine was blind to the other. The lane map is one row per agent on the
hub (rdb `0096_fleet_lanes`, `spool lane`): `<ID>@<box>` (box = the machine's
`SPOOL_DESK_BOX`), repo, branch, scope, files, topic, state `live` or `done`.

| when | who | writes |
|---|---|---|
| spawn | `spawn-core.inc.sh`, in the background, never blocking the spawn | `live`; scope = `SPAWN_LANE_SCOPE`, else the brief's first heading, else the slug; files = `SPAWN_LANE_FILES`; topic = `SPAWN_LANE_TOPIC` |
| exit-clean | the agent (`/exit-clean`, `/kill-your-self`) | `done`, other fields kept |

The map is shared once the machine has a fleet: `LANE_FLEET`, else
`LEASE_FLEET` with `LEASE_ENV` / `LEASE_TENANT` (`LANE_ENV` / `LANE_TENANT`
override them) from the dispatch `lease.conf`. Without one it is this machine's
worktrees, which is the one-machine behaviour. The read always adds this
machine's own worktrees too: a lane the hub has no row for shows as `src
local`. A hub that does not answer prints a WARN and falls back to them.

#### 3.11.1 Read it (live lanes; `--all` adds done, `--json` for scripts)

```bash
bash scripts/lane-map.sh
```

#### 3.11.2 Check the paths a new lane will own (exit 3 names the owner)

```bash
bash scripts/lane-map.sh --check csi-spl-orc/src/bash/run/,csi-spl-doc/specs/058-multi-machine-fleet/ --agent CLE-07
```

#### 3.11.3 Spawn with the lane's files in its row

```bash
SPAWN_LANE_FILES=csi-spl-orc/src/bash/run/spl-lane-map.func.sh SPAWN_LANE_TOPIC=<task-id> bash scripts/spawn-window.sh claude auto <WORKDIR> <BRIEF> <slug>
```

#### 3.11.4 Mark a lane done by hand

```bash
bash scripts/lane-map.sh done --agent CLE-07
```

The same reads and writes as run actions: `./run -a do_spl_lane_map`
(`LANE_CHECK`, `LANE_AGENT`, `LANE_ALL`, `LANE_FORMAT`) and `./run -a
do_spl_lane_put` (`LANE_AGENT`, `LANE_STATE`, ...). Test:
`csi-spl-orc/src/bash/tests/lane-map.tst.sh` (two simulated machines).

## 4. Exit codes of spool-send.sh and spool-notify.sh

The message file is written before the pane is touched. Any exit code below 10
therefore means the message **was** delivered:

| code | meaning |
|---|---|
| `0` | delivered and shown in the pane, or `--no-poke` was given |
| `5` | delivered, but no live window carries the recipient's id |
| `6` | delivered, but the poke was refused because the pane holds unsent typed text |
| `7` | delivered, but the pane runs only shells because the agent has exited |

These exit codes mean nothing was delivered:

| code | meaning |
|---|---|
| `2` | usage error |
| `10+` | `spool send` failed. The code is 10 plus spool's own exit code |

## 5. The frozen box engine, accounted for

`harness-parity.tsv` lists every file of the frozen box engine's feature and
where it went: `ported`, `replaced` by a spool-native piece, or `excluded`
(box maintenance, one-off scripts). Nothing is deferred.
`tests/test-harness-parity.sh` keeps the list honest and checks that all four
kinds have every piece; with `HARNESS_REF_DIR` it also fails on any reference
file without a row.

Hub mode (spec 003) needs one box key per box, minted once by an operator.
Spawning never mints a key.
