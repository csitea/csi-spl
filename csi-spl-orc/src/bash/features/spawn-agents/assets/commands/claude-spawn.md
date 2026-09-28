---
name: claude-spawn
description: >
  Spawn a new Claude Code agent in its own detached tmux window, auto-titled
  CLE-01, CLE-02, ... with its own git worktree and spool mailbox - or send a
  message to an already-running CLE-nn through the spool. Use when the user runs
  /claude-spawn, asks to spawn or start a new claude worker, open a CLE window, or
  send a prompt to a running CLE-nn agent.
---

# /claude-spawn — spawn a Claude Code worker (CLE-nn) or message a running one

| Invocation | Mode |
|---|---|
| `/claude-spawn <brief...>` | **Spawn** a new `CLE-nn` window with that brief |
| `/claude-spawn CLE-nn <message...>` | **Message** the running `CLE-nn` through the spool |
| `/claude-spawn` (no args) | Ask what the new session should work on; never spawn empty |

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

`spawn-window.sh` allocates the next free `CLE-nn`, claims its spool dir,
creates a git worktree `<repo>-wt/<ID>` on a branch off the trunk, and starts
claude in a DETACHED window. It prints `<ID> <PANE>`. The last argument is the
branch slug.

```bash
bash {{HARNESS_DIR}}/scripts/spawn-window.sh claude auto <repo-dir> <brief-file> <short-slug>
```

`SPAWN_DRY_RUN=1` in front prints the plan and changes nothing. A working dir
that is not a git checkout runs in place, with no worktree.

### 1.4 Prove it is visible

The window is created with `new-window -d`; never `select-window` or
`refresh-client` - the human switches to it themselves.

```bash
tmux -S "${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u)/default}" list-windows -a -F '#{window_name}'
```

## 2. Message a running CLE-nn

The message is a file in the agent's spool inbox; the pane line is only the
doorbell. Exit codes below 10 all mean it WAS delivered.

```bash
bash {{HARNESS_DIR}}/scripts/spool-send.sh --from <YOUR-ID> --to CLE-nn --kind task --body-file <message-file>
```

## 3. Claude Code specifics

- The session names itself: the seed prompt asks it to run `/rename`.
- Use this lane for architectural, ambiguous or correctness-critical work,
  and for any work that carries personal data or secrets.

## 4. Rules that hold for every kind

- One agent, one worktree, one branch. Name the files it must not touch.
- The brief file is the authority; the pane line is a doorbell.
- Close a finished agent with `/tmux-close-window` (or it runs `/exit-clean`).
