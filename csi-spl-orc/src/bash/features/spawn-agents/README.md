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
| `scripts/next-agent-id.sh` | allocates the next free id and claims it by `mkdir $SPOOL_ROOT/<id>`. `--claim <ID>` claims one exact id |
| `scripts/spawn-window.sh` | creates the detached window and starts the launcher in it. Prints `<ID> <PANE>` |
| `scripts/spawn-{claude,grok,agy}.sh` | the per-CLI adapters |
| `scripts/spawn-core.inc.sh` | the shared launcher core |
| `scripts/spool-send.sh` | runs `spool send` and then rings the recipient's tmux window. It replaces `inbox-send.sh` |
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

### 3.4 Send a task and ring the peer

```bash
bash csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh --from CLE-4441 --to GRK-4442 --kind task --body "ping"
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

### 3.8 Run the tests

```bash
bash csi-spl-orc/src/bash/features/spawn-agents/tests/run-all-tests.sh
```

## 4. Exit codes of spool-send.sh

The message file is written before the doorbell rings. Any exit code below 10
therefore means the message **was** delivered:

| code | meaning |
|---|---|
| `0` | delivered and poked, or `--no-poke` was given |
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
