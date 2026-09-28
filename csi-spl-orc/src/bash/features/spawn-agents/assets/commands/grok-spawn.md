---
name: grok-spawn
description: >
  Spawn a new grok agent in its own detached tmux window, auto-titled
  GRK-01, GRK-02, ... with its own git worktree and spool mailbox - or send a
  message to an already-running GRK-nn through the spool. Use when the user runs
  /grok-spawn, asks to spawn or start a new grok worker, open a GRK window, or
  send a prompt to a running GRK-nn agent.
---

# /grok-spawn — spawn a grok worker (GRK-nn) or message a running one

| Invocation | Mode |
|---|---|
| `/grok-spawn <brief...>` | **Spawn** a new `GRK-nn` window with that brief |
| `/grok-spawn GRK-nn <message...>` | **Message** the running `GRK-nn` through the spool |
| `/grok-spawn` (no args) | Ask what the new session should work on; never spawn empty |

## 1. Spawn

### 1.1 Count the live agents first

The ceiling is {{AGENT_CEILING}} agent windows. At or above it, finish the work
yourself or close a finished agent first, and say which you did.

```bash
tmux -S "${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u)/default}" list-windows -a -F '#{window_name}' | grep -cE '^([A-Za-z0-9][A-Za-z0-9._-]*: )?(CLE|GRK|AGY|QWN)-[0-9]+'
```

### 1.2 Write the brief to a file

Put the full task in a markdown file: the scope, the files it must NOT touch
(read `git worktree list` first so the new scope is disjoint from every live
agent), and how "done" is proven.

### 1.3 Start the window

`spawn-window.sh` allocates the next free `GRK-nn`, claims its spool dir,
creates a git worktree `<repo>-wt/<ID>` on a branch off the trunk, and starts
grok in a DETACHED window. It prints `<ID> <PANE>`. The last argument is the
branch slug.

```bash
bash {{HARNESS_DIR}}/scripts/spawn-window.sh grok auto <repo-dir> <brief-file> <short-slug>
```

`SPAWN_DRY_RUN=1` in front prints the plan and changes nothing. A working dir
that is not a git checkout runs in place, with no worktree.

### 1.4 Prove it is visible

The window is created with `new-window -d`; never `select-window` or
`refresh-client` - the human switches to it themselves.

```bash
tmux -S "${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u)/default}" list-windows -a -F '#{window_name}'
```

## 2. Message a running GRK-nn

The message is a file in the agent's spool inbox; the pane line is only the
doorbell. Exit codes below 10 all mean it WAS delivered.

```bash
bash {{HARNESS_DIR}}/scripts/spool-send.sh --from <YOUR-ID> --to GRK-nn --kind task --body-file <message-file>
```

## 3. grok specifics

- grok's TUI binds `Ctrl+J`. If that is your tmux prefix, reach the fleet by a
  status-bar click, `F12 w` or `Ctrl-Alt-Left/Right` (assets/tmux-agent-status.conf).
- grok cannot name a session: the window name (riname) is the one a human reads.

## 4. Rules that hold for every kind

- One agent, one worktree, one branch. Name the files it must not touch.
- The brief file is the authority; the pane line is a doorbell.
- Close a finished agent with `/tmux-close-window` (or it runs `/exit-clean`).
