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
(read the fleet-wide lane map first, `bash {{HARNESS_DIR}}/scripts/lane-map.sh` - every live
agent on every machine, which `git worktree list` cannot see - so the new scope
is disjoint; `--check <path,...>` exits 3 naming the lane that owns one), and how "done" is proven.

### 1.3 Start the window

`spawn-window.sh` allocates the next free `CLE-nn`, claims its spool dir in
the shared spool root (so it and its orchestrator `{{ORCHESTRATOR_ID}}` read one mailbox),
creates a git worktree `<repo>-wt/<ID>` on a branch off the trunk, and starts
claude in a DETACHED window. It prints `<ID> <PANE>`. The last argument is the
branch slug.

```bash
SPOOL_ROOT={{SPOOL_ROOT}} SPOOL_ORCHESTRATOR_ID={{ORCHESTRATOR_ID}} bash {{HARNESS_DIR}}/scripts/spawn-window.sh claude auto <repo-dir> <brief-file> <short-slug>
```

`SPAWN_DRY_RUN=1` in front prints the plan and changes nothing. A working dir
that is not a git checkout runs in place, with no worktree.

Spawns in a parallel batch are serialised at the trust step: each one waits
for the box-wide trust lock, verifies its folder reads back as trusted, and
holds the lock a few seconds while its claude starts. A spawn whose trust does
not verify stops with an error, rather than leaving a window that sits on
"Is this a project you trust?".

In a git checkout the brief carries the DEPLOY-GATE footer, so every push
succeeds the first time:

- run `cd csi-spl-iac && ./run -a do_check_pre_push` before every push, and
  again after the rebase. It includes the lint parts: the CI scanners on the
  touched files.
- missing scanners are installed with `./run -a do_install_lint_tools`.
- never `SPL_PREPUSH_OVERRIDE=1`, except in an emergency reported to the
  orchestrator.
- after the push, check the scanner workflows on that sha
  (`gh run list --commit <sha>`) and fix a red one in the same lane.

### 1.4 Prove it is visible

The window is created with `new-window -d`; never `select-window` or
`refresh-client` - the human switches to it themselves.

```bash
tmux -S "${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u)/default}" list-windows -a -F '#{window_name}'
```

## 2. Message a running CLE-nn

`agent-send.sh` reaches the agent through the mailbox it was spawned with
(the spool for this harness, the older markdown inbox during a switch-over),
so the same command works for every live agent. The message is a file; the
pane line is only the doorbell, and a non-zero exit after `via:` still means
it was delivered unless the script says "nothing delivered".

```bash
SPOOL_ROOT={{SPOOL_ROOT}} bash {{HARNESS_DIR}}/scripts/agent-send.sh --from <YOUR-ID> CLE-nn --kind task --file <message-file>
```

Reports sent to you, not seen yet:

```bash
SPOOL_ROOT={{SPOOL_ROOT}} bash {{HARNESS_DIR}}/scripts/agent-inbox.sh --as <YOUR-ID>
```

## 3. Claude Code specifics

- The session names itself: the seed prompt asks it to run `/rename`.
- Use this lane for architectural, ambiguous or correctness-critical work,
  and for any work that carries personal data or secrets.

## 4. Rules that hold for every kind

- One agent, one worktree, one branch. Name the files it must not touch.
- The brief file is the authority; the pane line is a doorbell.
- Close a finished agent with `/tmux-close-window` (or it runs `/exit-clean`).
