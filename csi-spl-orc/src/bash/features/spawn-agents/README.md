# spawn-agents — spool-native agent spawning

Starts Claude Code, grok and antigravity (agy) agents in their own tmux
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
| `doc/md/SPEC-spool-identity-routing.md` §2 | ids match `^[A-Z]{2,4}-[0-9]+$`, are unique per box, and never use the `BOX` prefix. CLE/GRK/AGY belong to claude/grok/agy |

Some behaviour is box-level rather than spec-level, so it is kept exactly as
the reference does it:

- **tmux visibility.** Windows are created with `new-window -d` in the session
  the box user's client is attached to. No spawn ever runs `select-window`.
- **Isolation.** Each agent gets its own git worktree, `<repo>-wt/<ID>`, on a
  branch off `origin/<trunk>`.
- **Seed prompt.** It carries the scope, integration and leak-gate blocks.
- **Run-as hop.** Agents run as the agent user.
- **Kept-open pane.** When the agent exits, its pane stays open.

## 1. Layout

| path | role |
|---|---|
| `lib/spool-env.inc.sh` | the one resolver: env vars, users, tmux socket, binaries, the id rules, pane lookup |
| `lib/spool-notify.inc.sh` | the one renderer and doorbell (`specs/028-spool-terminal-delivery`): a message is made VISIBLE in the recipient's pane, under the safe-poke rules |
| `scripts/next-agent-id.sh` | allocates the next free id and claims it by `mkdir $SPOOL_ROOT/<id>`. `--claim <ID>` claims one exact id |
| `scripts/spawn-window.sh` | creates the detached window and starts the launcher in it. Prints `<ID> <PANE>` |
| `scripts/spawn-{claude,grok,agy}.sh` | the per-CLI adapters |
| `scripts/spawn-core.inc.sh` | the shared launcher core |
| `scripts/spool-agent.sh` | start claude or grok SEATED and MIRRORED (`specs/036-spool-terminal-mirror`): claims an id, names the window, seats a desk, gives the session the mirror hooks, then runs the CLI |
| `scripts/spool-mirror.py` | the terminal -> web UI DM mirror: the CLIs' `UserPromptSubmit` / `Stop` hook and its post (redacted, never echoing the web UI's own words) |
| `scripts/spool-harness.sh` | the standard box launcher (`specs/012-spool-box-api`): prepares an agent's spool dirs, checks the box identity, starts the hub sidecar in hub mode, injects `SPOOL_*`, then exec-s the agent CLI |
| `scripts/spool-send.sh` | runs `spool send` and then shows the message in the recipient's tmux pane. It replaces `inbox-send.sh` |
| `scripts/spool-notify.sh` | shows a message that is ALREADY in an inbox. This is what `SPOOL_NOTIFY_CMD` points at, so the hub sidecar (cross-box, and a human's WUI task) reaches the terminal too |
| `scripts/riname.sh` | renames an agent's window by id (`--agent <ID>`) |
| `scripts/trust-workdir.sh` | pre-accepts each CLI's "trust this folder?" dialog |
| `tests/run-all-tests.sh` | every test. Each one uses a throwaway root and a private tmux server |

## 2. Configuration

Everything is set through env vars. None of them bakes in a user, a host or a
box.

| var | default |
|---|---|
| `SPOOL_ROOT` | `/var/spool-hub` |
| `SPOOL_BOX_USER` | the owner of `$SPOOL_ROOT`, else the current user. This user owns the tmux server |
| `SPOOL_AGENT_USER` | `$SPOOL_BOX_USER`. The agent CLIs run as this user |
| `SPOOL_RUN_AS_AGENT` | `su-dash` (`sudo su - <agent>`), or `sudo-i` |
| `SPOOL_TMUX_SOCKET` | `/tmp/tmux-<uid of box user>/default` |
| `SPOOL_BOX_TAG` | empty. When set, window names read `<tag>: <ID>` |
| `SPOOL_ORCHESTRATOR_ID` | `CLE-00`. Spawned agents report to this id |
| `SPOOL_BIN` | `csi-spl-api/src/go/spool-hub-api/bin/spool`, else `spool` on `PATH` |
| `SPOOL_NOTIFY_CMD` | the notifier the spool binary runs after it writes a message into a local inbox. `spool-harness` sets it to `scripts/spool-notify.sh`; `off` disables it; unset = no terminal leg |
| `SPOOL_NOTIFY_BODY_MAX` `SPOOL_NOTIFY_LINE_MAX` | `600` / `1200` — the bounds on the pane line (`specs/028/contracts/poke-line.md`) |
| `CLAUDE_BIN` `GROK_BIN` `AGY_BIN` | `<agent home>/.local/bin/<cli>`, else the bare name |

## 3. Use

### 3.1 Build the spool binary

```bash
bash csi-spl-api/src/bash/build.sh
```

### 3.2 Spawn a claude agent with the next free id

The last argument is the branch slug.

```bash
SPOOL_AGENT_USER=<AGENT_USER> bash csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-window.sh claude auto /opt/csi/csi-spl /path/to/brief.md short-slug
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

## 5. Not forked (yet)

These reference pieces were left out on purpose:

- pnpm worktree hydration
- the mode-churn detector. The seed prompt gives the manual check instead
- agent-top / pane-scan fleet views
- restore scripts
- `tmux-close-window`

Hub mode (spec 003) needs one box key per box, minted once by an operator.
Spawning never mints a key.
