---
name: agy-spawn
description: >
  Spawn a new antigravity (agy) agent in its own detached tmux window, auto-titled
  AGY-01, AGY-02, ... with its own git worktree and spool mailbox - or send a
  message to an already-running AGY-nn through the spool. Use when the user runs
  /agy-spawn, asks to spawn or start a new agy worker, open a AGY window, or
  send a prompt to a running AGY-nn agent.
---

# /agy-spawn — spawn a antigravity (agy) worker (AGY-nn) or message a running one

| Invocation | Mode |
|---|---|
| `/agy-spawn <brief...>` | **Spawn** a new `AGY-nn` window with that brief |
| `/agy-spawn AGY-nn <message...>` | **Message** the running `AGY-nn` through the spool |
| `/agy-spawn` (no args) | Ask what the new session should work on; never spawn empty |

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

`spawn-window.sh` allocates the next free `AGY-nn`, claims its spool dir,
creates a git worktree `<repo>-wt/<ID>` on a branch off the trunk, and starts
agy in a DETACHED window. It prints `<ID> <PANE>`. The last argument is the
branch slug.

```bash
bash {{HARNESS_DIR}}/scripts/spawn-window.sh agy auto <repo-dir> <brief-file> <short-slug>
```

`SPAWN_DRY_RUN=1` in front prints the plan and changes nothing. A working dir
that is not a git checkout runs in place, with no worktree.

### 1.4 Prove it is visible

The window is created with `new-window -d`; never `select-window` or
`refresh-client` - the human switches to it themselves.

```bash
tmux -S "${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u)/default}" list-windows -a -F '#{window_name}'
```

## 2. Message a running AGY-nn

The message is a file in the agent's spool inbox; the pane line is only the
doorbell. Exit codes below 10 all mean it WAS delivered.

```bash
bash {{HARNESS_DIR}}/scripts/spool-send.sh --from <YOUR-ID> --to AGY-nn --kind task --body-file <message-file>
```

## 3. antigravity (agy) specifics

- agy paints on the NORMAL screen: the launcher marks its pane so a notice is
  never typed over its UI; messages reach it through its inbox and strip.
- agy cannot name a session: the window name (riname) is the one a human reads.

## 4. Rules that hold for every kind

- One agent, one worktree, one branch. Name the files it must not touch.
- The brief file is the authority; the pane line is a doorbell.
- Close a finished agent with `/tmux-close-window` (or it runs `/exit-clean`).
