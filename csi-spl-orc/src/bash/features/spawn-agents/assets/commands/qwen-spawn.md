---
name: qwen-spawn
description: >
  Spawn a new Qwen Code (qwen) agent in its own detached tmux window, auto-titled
  q-004, q-005, ... with its own git worktree and spool mailbox - or send a
  message to an already-running q-NNN through the spool. Use when the user runs
  /qwen-spawn, asks to spawn or start a new qwen worker, open a q-NNN window, or
  send a prompt to a running q-NNN agent.
---

# /qwen-spawn — spawn a Qwen Code (qwen) worker (q-NNN) or message a running one

| Invocation | Mode |
|---|---|
| `/qwen-spawn <brief...>` | **Spawn** a new `q-NNN` window with that brief |
| `/qwen-spawn q-NNN <message...>` | **Message** the running `q-NNN` through the spool |
| `/qwen-spawn` (no args) | Ask what the new session should work on; never spawn empty |

## 1. Spawn

### 1.1 Count the live agents first

The ceiling is {{AGENT_CEILING}} agent windows. At or above it, finish the work
yourself or close a finished agent first, and say which you did.

```bash
tmux -S "${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u)/default}" list-windows -a -F '#{window_name}' | grep -cE '^([A-Za-z0-9][A-Za-z0-9._-]*: )?([acgmq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)'
```

### 1.2 Write the brief to a file

Put the full task in a markdown file: the scope, the files it must NOT touch
(read the fleet-wide lane map first, `bash {{HARNESS_DIR}}/scripts/lane-map.sh` - every live
agent on every machine, which `git worktree list` cannot see - so the new scope
is disjoint; `--check <path,...>` exits 3 naming the lane that owns one), and how "done" is proven.

### 1.3 Start the window

`spawn-window.sh` allocates the next free `q-NNN`, claims its spool dir in
the shared spool root (so it and its orchestrator `{{ORCHESTRATOR_ID}}` read one mailbox),
creates a git worktree `<repo>-wt/<ID>` on a branch off the trunk, and starts
qwen in a DETACHED window. It prints `<ID> <PANE>`. The last argument is the
branch slug.

```bash
SPOOL_ROOT={{SPOOL_ROOT}} SPOOL_ORCHESTRATOR_ID={{ORCHESTRATOR_ID}} bash {{HARNESS_DIR}}/scripts/spawn-window.sh qwen auto <repo-dir> <brief-file> <short-slug>
```

`SPAWN_DRY_RUN=1` in front prints the plan and changes nothing. A working dir
that is not a git checkout runs in place, with no worktree.

### 1.4 Prove it is visible

The window is created with `new-window -d`; never `select-window` or
`refresh-client` - the human switches to it themselves.

```bash
tmux -S "${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u)/default}" list-windows -a -F '#{window_name}'
```

## 2. Message a running q-NNN

`agent-send.sh` reaches the agent through the mailbox it was spawned with
(the spool for this harness, the older markdown inbox during a switch-over),
so the same command works for every live agent. The message is a file; the
pane line is only the doorbell, and a non-zero exit after `via:` still means
it was delivered unless the script says "nothing delivered".

```bash
SPOOL_ROOT={{SPOOL_ROOT}} bash {{HARNESS_DIR}}/scripts/agent-send.sh --from <YOUR-ID> q-NNN --kind task --file <message-file>
```

Reports sent to you, not seen yet:

```bash
SPOOL_ROOT={{SPOOL_ROOT}} bash {{HARNESS_DIR}}/scripts/agent-inbox.sh --as <YOUR-ID>
```

## 3. Qwen Code (qwen) specifics

- qwen is the cheap lane: mechanical, well-specified work. Its hosted endpoints
  are run by a third-party provider, so work that carries personal data or
  secrets (credentials, keys, customer data) never goes to it, and a q-NNN brief
  never names a credential path.
- Auth is set once by a human in the agent user's `~/.qwen/settings.json` and
  `~/.qwen/.env` (mode 0600). The launcher passes no key on any command line.
- qwen cannot name a session: the window name (riname) is the one a human reads.

## 4. Rules that hold for every kind

- One agent, one worktree, one branch. Name the files it must not touch.
- The brief file is the authority; the pane line is a doorbell.
- Close a finished agent with `/tmux-close-window` (or it runs `/exit-clean`).
