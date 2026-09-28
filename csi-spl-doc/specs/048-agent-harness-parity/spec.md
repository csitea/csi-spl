# Feature Specification: Agent Harness Parity (claude, agy, grok, qwen)

**Feature ID**: `048-agent-harness-parity` · **Milestone**: M3 · **Status**: Partial
**Created**: 2026-09-28 · **Lane**: harness-parity (CLE-35090) · **Epic**: SPL-1152
**Authority**: this file for the behaviour and its rules; `tasks.md` for what is
built, with the sha and the check for each item. Status vocabulary:
`../README.md` §2.3.

Builds on `037-spool-agent-install` (the installer), `036-spool-terminal-mirror`
(`spool-agent.sh`, the mirror hooks) and `002-box-agent-messaging` (the spool
mailbox that replaced the markdown inbox).

## 1. The owner's request, verbatim (2026-09-28)

> we need to make sure that the harness around the claude code , agy , grok and quen are fully replicated in the csi-spl project

> becuase we would want anyone clonging the repo to have the same setup

> for the ai cli tools the harness should be used from the csi-spl project from now own - mark the ysg-box as frozen

## 2. What was measured before any change

2.1 Reference: the private box engine's `spawn-agents` feature at its freeze
commit (`844b088`, FROZEN.md at its root). Fork: this repo's
`csi-spl-orc/src/bash/features/spawn-agents` at `392f7201`. n = every file of
both trees.

| count | what |
|---|---|
| 109 | files in the reference |
| 44 | files in the fork |
| 100 | files only in the reference: every skill and slash command template, the qwen adapter, restore/inject/close-window scripts, the fleet views, their tests |
| 35 | files only in the fork: the spool-native pieces (spool-agent, spool-harness, spool-send/notify, the mirror, the notice strip) |
| 9 | common files, all 9 differ (the fork adapted them to the spool) |

2.2 `grep -c qwen csi-spl-orc/src/bash/features/spool-install/install.sh` -> 0.
`spool-agent.sh` refused qwen (`*) exit 2`) = SPL-1148.

2.3 Most of the 100 are NOT drift. The fork replaced the markdown inbox
(`MSGS_ROOT`, `inbox-send.sh`) with the spool (`spool send`, `spool-send.sh`)
on purpose, and its hygiene test forbids the reference's paths and users. So
"parity" means **the same capabilities for every agent kind**, not the same
bytes.

## 3. Design decisions

### 3.1 One source of truth: csi-spl (OWNER DECISION, 2026-09-28)

csi-spl is canonical for the AI CLI harness; the box engine is FROZEN
(`844b088`) and is read-only history. A fix that keeps a running fleet alive
may still land there only with `frozen-exception: <csi-spl sha>`.

How the two stay honest: `harness-parity.tsv` in the spawn-agents feature maps
**every** file of the frozen reference to exactly one disposition:

| disposition | meaning |
|---|---|
| `ported <path>` | the same capability lives at `<path>` in this repo |
| `replaced <path>` | a spool-native equivalent does the job (e.g. `inbox-send.sh` -> `spool-send.sh`) |
| `excluded <reason>` | deliberately not shipped (box-only operations, one-off scripts, tests of an excluded piece) |

`tests/test-harness-parity.sh` fails when (a) a `ported`/`replaced` target is
missing, (b) any of the four kinds lacks its adapter, its id prefix, its
`spool-agent.sh` branch, its installer branch or its slash command, or (c)
with `HARNESS_REF_DIR=<the frozen reference>` set, a reference file has no
row. (c) is the check that would have caught the 100-file gap; it runs where
the private reference exists (`./run -a do_check_harness_parity`), while (a)
and (b) run in CI on every push. Since the reference is frozen, (c) can only go
red if this repo loses a row.

### 3.2 Public-repo hygiene

Everything shipped is parameterised: no user, box, host or home literal. The
skill and command templates carry placeholders that `install.sh` renders:

| placeholder | rendered from |
|---|---|
| `{{HARNESS_DIR}}` | the clone's `csi-spl-orc/src/bash/features/spawn-agents` |
| `{{SPOOL_ROOT}}` | `$SPOOL_ROOT`, default `/var/spool-hub` |
| `{{AGENT_CEILING}}` | `$SPOOL_AGENT_CEILING`, default 40 |

The feature's `tests/test-hygiene.sh` (no literal users, boxes, homes, no path
into the reference, no `MSGS_ROOT`) also covers `assets/`, and
`./run -a do_check_dist_hygiene` runs before every push.

### 3.3 Install path

`install.sh --cli claude,grok,agy,qwen`:

- claude, grok, agy: each vendor's own installer (unchanged, spec 037).
- qwen: `npm install --prefix <prefix> -g @qwen-code/qwen-code@latest` (Node
  20+; a missing npm is NAMED, never installed with sudo), then the vendored
  ripgrep gets its execute bit (the 0.24.6 tarball ships it without one, so
  every session warned "Ripgrep not available ... EACCES").
- the skills and slash commands: rendered from `assets/` into
  `~/.claude/commands/<name>.md` and `~/.claude/skills/<name>/SKILL.md`. Each
  rendered file ends with a marker line carrying the sha256 of what was
  written; a re-run rewrites a file only while it still hashes to its marker
  (untouched since the last install). A hand-edited file is left alone and
  NAMED (`--force-skills` overwrites it, keeping a `.bak-spool-install`). A
  same-named file install.sh did not write is never touched.
- the tmux badge snippet `assets/tmux-agent-status.conf` is copied to
  `<data>/tmux-agent-status.conf` and the one `source-file` line to add is
  printed; `~/.tmux.conf` is never edited.

### 3.4 The four kinds

| kind | id prefix | binary var | adapter | trust store |
|---|---|---|---|---|
| claude | CLE | `CLAUDE_BIN` | `spawn-claude.sh` | `~/.claude.json` |
| grok | GRK | `GROK_BIN` | `spawn-grok.sh` | `~/.grok/trusted_folders.toml` |
| agy | AGY | `AGY_BIN` | `spawn-agy.sh` | `~/.gemini/antigravity-cli/settings.json` |
| qwen | QWN | `QWEN_BIN` | `spawn-qwen.sh` | `~/.qwen/trustedFolders.json` |

qwen flags (pinned at 0.24.6): `--yolo`, `--prompt-interactive`, `--resume`,
`--continue`; it cannot name a session, so the tmux window carries the name.
qwen reads its auth from `~/.qwen/settings.json` + `~/.qwen/.env`, set once by
a human; the launcher never passes a key.

### 3.5 Switch-over

Only once the parity test is green: this box (and its peers) run the harness
from the csi-spl checkout (skills, commands, spawn scripts, tmux hooks), with a
rollback line; announced to the orchestrator before flipping, since it affects
every live agent. Then FROZEN.md in the reference is rewritten per its §1.4.

## 4. Out of scope

- the box engine's box-only operations (ACL normalisation, mode-churn repair,
  the claude-sessions/login features); listed as `excluded` in the manifest.
- a hub-side join token (037 T005).
