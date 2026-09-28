# 048 T008: switching a box over to the csi-spl harness

Status: PLANNED, not run. The switch affects every live agent on the box, so it
is announced to the orchestrator before any step, and one question is open
for the owner (section 3).

## 1. What still points at the frozen engine (measured 2026-09-28, this box, n = whole files)

| where | count | what |
|---|---|---|
| the agent user's `~/.claude/commands` + `~/.claude/skills` + `CLAUDE.md` + `settings.json` | 11 files | 47 paths into the frozen `spawn-agents`, 3 `directive`, 2 `mcp-bot`, 1 `tmux-windows`, 1 qwen setup doc |
| the box user's crontab | 2 live lines | `claude-sessions` save + boot (not a spawn-agents piece) |

Command: `grep -rho '<frozen engine root>/[a-zA-Z0-9/._-]*' ~/.claude/{commands,skills,CLAUDE.md,settings.json} | sed -E 's#(features/[^/]+).*#\1#' | sort | uniq -c`.

## 2. The one difference that is not a path

The frozen engine's agents talk through a MARKDOWN inbox (a message root with
`<ID>/inbox/*.md`, `inbox-send.sh`, `registry.tsv` there). The csi-spl harness
talks through the SPOOL mailbox (`<SPOOL_ROOT>/<ID>/inbox/*.json`,
`spool-send.sh`, `spool recv`). An agent spawned by the csi-spl
`spawn-window.sh` has no markdown inbox, so an orchestrator that still writes
`.md` files with `inbox-send.sh` does not reach it.

## 3. Open question for the owner (posted as a spool blocker)

Switch the orchestrator to the spool mailbox at the same time (one protocol,
the csi-spl one), or keep spawning through the frozen engine until the
orchestrator has moved? Recommendation: move the orchestrator first, as its own
lane, then flip the skills; flipping the skills alone would strand every new
agent from the orchestrator's inbox pokes.

## 4. Steps, once section 3 is answered

4.1 Parity green on the trunk tree the box will run:

```bash
cd <csi-spl checkout>/csi-spl-orc && HARNESS_REF_DIR=<frozen engine>/ysg-box-orc/src/bash/features/spawn-agents ./run -a do_check_harness_parity
```

4.2 Announce to the orchestrator: the time, the rollback line, and that live
agents keep running (their panes are untouched; only NEW spawns change).

4.3 As the agent user, move the frozen engine's rendered commands and skills
aside. The installer never overwrites a file it did not write, so this is what
lets it render its own:

```bash
ts=$(date -u +%Y%m%dT%H%M%SZ); mkdir -p ~/.claude/.pre-048-$ts && cd ~/.claude && mv commands/{claude,agy,grok,qwen}-spawn.md commands/spawn-an-agent.md commands/riname.md commands/tmux-close-window.md skills/agent-msg skills/exit-clean skills/kill-your-self .pre-048-$ts/
```

4.4 As the agent user, render the csi-spl harness (no seat, no CLI changes):

```bash
bash <csi-spl checkout>/csi-spl-orc/src/bash/features/spool-install/install.sh --cli none --no-seat
```

4.5 Add the tmux line the installer printed to the box user's `~/.tmux.conf`,
replacing the frozen engine's `agent-status.conf` line.

4.6 Proof: one `QWN` and one `CLE` spawn through the new `/qwen-spawn` and
`/claude-spawn`, a spool message each way, a `/tmux-close-window`.

4.7 Rewrite the frozen engine's FROZEN.md per its §1.4 (retired: the box runs
the csi-spl harness), landed with `frozen-exception: <csi-spl sha>`.

## 5. Rollback (one line, as the agent user)

```bash
cd ~/.claude && for f in commands/*.md skills/*/SKILL.md; do grep -q 'spool-install: sha256=' "$f" && rm -f "$f"; done; cp -a .pre-048-<ts>/*.md commands/ && cp -a .pre-048-<ts>/{agent-msg,exit-clean,kill-your-self} skills/
```
