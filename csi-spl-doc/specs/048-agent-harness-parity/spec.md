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

## 5. Memory parity: what each vendor loads (SPL-2738, 2026-10-20)

Owner, 2026-10-20 (t1 5471b31d, msg b66130f6): "it is a smell that claude
keeps in his memory something the grok agents do not know, invesitate what
copy and apply".

### 5.1 What each vendor loads at session start

Measured 2026-10-20 on the two fleet boxes, as the agent user, n=1 each.

| vendor | loads | claude's auto-memory? |
|---|---|---|
| claude | `~/.claude/CLAUDE.md`, the repo `CLAUDE.md`, and `~/.claude/projects/<slug>/memory/MEMORY.md` (the index; a fact file is read when a line points to it) | yes, its own |
| grok 1.0.62 | `~/.claude/CLAUDE.md` (its claude-compat scan), the repo `CLAUDE.md` + `AGENTS.md`, every `*.md` in `~/.grok/rules/` (symlinks followed), its own memory only when `[memory] enabled` | no: `grok inspect` in a lane worktree lists 3 instruction files, none of them memory |
| agy | `~/.gemini/config/rules/*.md` (the lane rule, the exit rule, graft) | no |
| mistral | `~/.vibe/AGENTS.md` | no |

`<slug>` is the main checkout's absolute path with every non-alphanumeric
character turned into `-`; a worktree's sessions use the main checkout's
memory. Its size on the day: box one 311 files (`ls | wc -l`), `MEMORY.md`
170 lines, 23,771 bytes; box two 151 files, 150 lines, 27,467 bytes. Of box
one's 310 fact files, 170 are linked from `MEMORY.md` (3 of them "Area index"
files) and the other 140 from those area indexes, none orphaned; by
frontmatter type 51 feedback, 216 project, 40 reference, 3 untyped. The
owner rules and fleet traps sit in all three types, so the fix gives grok the
whole index, as claude has it, rather than a hand-picked subset.

### 5.2 The gap and the fix

grok sees none of it: no spool-install step pointed it there
(`grep -rl claude/projects` over the grok, agy and vibe rule files -> only
an unrelated session-move recipe). The fix copies nothing:
spool-install step Y18 (`steps/y18-grok-memory.sh`, `--fleet`, homes with
`~/.grok`) writes two home rules into `~/.grok/rules`:

- `fleet-memory-0-where.md`: where the index and its files are on this box,
  read the files a line names, check a lesson against the tree, never post
  or commit the text;
- `fleet-memory-1-index.md`: a symlink to the claude `MEMORY.md` itself, so
  a lesson claude saves is in the next grok session with no second copy.

Both users of a box: `cd csi-spl-orc && DRY_RUN=0 ./run -a do_spl_grok_memory_install`.
Test: `spool-install/tests/test-y18-grok-memory.sh` (red without the step;
with grok on PATH it drives `grok inspect` on a sandbox home: no memory rule
before, both rules after). The memory stays on the box, under the agent
user's home; the repo holds only the step.

agy has the same gap and the same kind of rules dir (every
`~/.gemini/config/rules/*.md`); mistral loads only `~/.vibe/AGENTS.md`, so it
needs a pointer line there. Neither is changed by SPL-2738.

## 6. Seed parity and per-vendor blocks (SPL-2176, 2026-10-25)

Every kind renders claude's seed, sentence for sentence, at most
`SEED_PARITY_MAX` (400) bytes over it and under the absolute cap (9135 B at
the live paths). An adapter (`spawn-agents/scripts/spawn-<kind>.sh`) may
declare two hooks of the core (`spawn-core.inc.sh`); a kind that declares
neither renders the shared seed byte for byte.

| hook | replaces / adds | grok |
|---|---|---|
| `spawn_scope_how` | the git lane's SCOPE block; keeps its header and rules (a)-(d) | tighter: "Your brief's scope only: no refactor, cleanup or extra feature beyond it." |
| `spawn_seed_note` | one sentence after SCOPE, rendered `HARNESS NOTE (<kind>): <text>` | brevity: answer and report in few words, never restate the brief, the seed or a tool's output |

Measured at the live paths on dea358a0f (n=1 render each), before -> after:
claude 8812 -> 8812, grok 8947 -> 8985 (+135 -> +173), agy 8946, qwen 8947,
mistral 9126, unchanged.

Guard: `spawn-agents/tests/test-spawn-seed-size.sh` (grok carries the note
and the tighter scope, the other kinds no note, every kind's SCOPE keeps
(a)-(d), parity outside the kind's own blocks, the caps).
`SEED_BASE_REF=<ref>` adds the check that claude's seed is byte-identical to
the one that ref's launcher renders; it is off by default, since a later
change to the shared seed rightly differs from its base.
