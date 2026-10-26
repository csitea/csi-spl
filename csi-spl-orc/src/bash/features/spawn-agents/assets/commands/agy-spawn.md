---
name: agy-spawn
description: >
  Spawn a new antigravity (agy) agent in its own detached tmux window, auto-titled
  a-004, a-005, ... with its own git worktree and spool mailbox - or send a
  message to an already-running a-NNN through the spool. Use when the user runs
  /agy-spawn, asks to spawn or start a new agy worker, open a a-NNN window, or
  send a prompt to a running a-NNN agent.
---

# /agy-spawn — spawn a antigravity (agy) worker (a-NNN) or message a running one

> Generated from qto doc `11861108-d699-49cd-b819-ce5d5963bf64`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

| Invocation | Mode |
|---|---|
| `/agy-spawn <brief...>` | **Spawn** a new `a-NNN` window with that brief |
| `/agy-spawn a-NNN <message...>` | **Message** the running `a-NNN` through the spool |
| `/agy-spawn` (no args) | Ask what the new session should work on; never spawn empty |

<a id="ws-doc-a6e12924-2d86-4b6a-8444-e07f28d18c43"></a>
## 1. Spawn

<a id="ws-doc-731aaddc-c7e5-481c-8259-ef1bd795e3e0"></a>
### 1.1 Count the live agents first

The ceiling is {{AGENT_CEILING}} agent windows. At or above it, finish the work
yourself or close a finished agent first, and say which you did.

```bash
tmux -S "${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u)/default}" list-windows -a -F '#{window_name}' | grep -cE '^([A-Za-z0-9][A-Za-z0-9._-]*: )?([acgmq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)'
```

<a id="ws-doc-1bfe57f9-3e17-4978-a609-69f3f19dc270"></a>
### 1.2 Write the brief to a file

Put the full task in a markdown file: the scope, the files it must NOT touch
(read the fleet-wide lane map first, `bash {{HARNESS_DIR}}/scripts/lane-map.sh` - every live
agent on every machine, which `git worktree list` cannot see - so the new scope
is disjoint; `--check <path,...>` exits 3 naming the lane that owns one), and how "done" is proven.

<a id="ws-doc-d902faf8-fd26-4f42-96b8-dce5101c83b8"></a>
### 1.3 Start the window

`spawn-window.sh` allocates the next free `a-NNN`, claims its spool dir in
the shared spool root (so it and its orchestrator `{{ORCHESTRATOR_ID}}` read one mailbox),
creates a git worktree `<repo>-wt/<ID>` on a branch off the trunk, and starts
agy in a DETACHED window. It prints `<ID> <PANE>`. The last argument is the
branch slug.

```bash
SPOOL_ROOT={{SPOOL_ROOT}} SPOOL_ORCHESTRATOR_ID={{ORCHESTRATOR_ID}} bash {{HARNESS_DIR}}/scripts/spawn-window.sh agy auto <repo-dir> <brief-file> <short-slug>
```

`SPAWN_DRY_RUN=1` in front prints the plan and changes nothing. A working dir
that is not a git checkout runs in place, with no worktree.

<a id="ws-doc-db30cd02-0abc-44dc-9e09-29785e63dbc4"></a>
### 1.4 Prove it is visible

The window is created with `new-window -d`; never `select-window` or
`refresh-client` - the human switches to it themselves.

```bash
tmux -S "${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u)/default}" list-windows -a -F '#{window_name}'
```

<a id="ws-doc-dc37f760-eec7-4c5e-98d0-a0a4ff017415"></a>
## 2. Message a running a-NNN

`agent-send.sh` reaches the agent through the mailbox it was spawned with
(the spool for this harness, the older markdown inbox during a switch-over),
so the same command works for every live agent. The message is a file; the
pane line is only the doorbell, and a non-zero exit after `via:` still means
it was delivered unless the script says "nothing delivered".

```bash
SPOOL_ROOT={{SPOOL_ROOT}} bash {{HARNESS_DIR}}/scripts/agent-send.sh --from <YOUR-ID> a-NNN --kind task --file <message-file>
```

Reports sent to you, not seen yet:

```bash
SPOOL_ROOT={{SPOOL_ROOT}} bash {{HARNESS_DIR}}/scripts/agent-inbox.sh --as <YOUR-ID>
```

<a id="ws-doc-ac56e94d-c948-4d9b-aaa7-1ccf5b996963"></a>
## 3. antigravity (agy) specifics

- agy paints on the NORMAL screen: the launcher marks its pane so a notice is
  never typed over its UI; messages reach it through its inbox and strip.
- agy cannot name a session: the window name (riname) is the one a human reads.
- Work that carries personal data or secrets never goes to agy (the data rule
  in `/spawn-an-agent`).

<a id="ws-doc-f7b534ec-0942-42a0-ae5f-4de7b5700214"></a>
## 4. Rules that hold for every kind

- One agent, one worktree, one branch. Name the files it must not touch.
- The brief file is the authority; the pane line is a doorbell.
- Close a finished agent with `/tmux-close-window` (or it runs `/exit-clean`).
