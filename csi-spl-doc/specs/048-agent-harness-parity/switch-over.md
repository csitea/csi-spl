# 048 T008: switching a box over to the csi-spl harness

Status: **DONE on this box 2026-09-29 12:19Z** (owner: "ok, do it now",
ahead of the confirmed 19:00Z). Old files in `~/.claude/.pre-048-20260929T121954Z`.
Owner answered **A** (2026-09-29): the orchestrator moves to the spool
mailbox FIRST, through a bridge that keeps every older agent reachable; then
the spawn skills flip. The one hard rule: never break a live agent's
reachability. Section 4 runs only after the proof in 4.1 and the orchestrator's
confirmation of the announced go-time.

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

## 3. Decision A: the orchestrator first, through a bridge

3.1 **Send** - `scripts/agent-send.sh`, a drop-in for the frozen engine's
sender (same arguments: `--from`, `<ID>`, text or `--file`, `--subject`,
`--no-poke`). It picks the mailbox the target was SPAWNED with:

| target | route |
|---|---|
| in `$SPOOL_ROOT/registry.tsv` (spawned by the csi-spl harness) | spool: `spool-send.sh`, spool's safe poke |
| has `$SPOOL_LEGACY_INBOX_ROOT/<ID>/inbox` (spawned by the frozen engine, even if the desk also gave it a spool dir) | legacy: runs `$SPOOL_LEGACY_SEND` (the frozen engine's own sender) with the same arguments - the same file, the same shell-inert poke, the same exit codes as today |
| only `$SPOOL_ROOT/<ID>/inbox` | spool |
| none | exit 3, nothing delivered |

3.2 **Receive** - `scripts/agent-inbox.sh --as <ORC-ID>` lists what the
orchestrator has not seen yet: its spool inbox (`*.json`) and, with
`SPOOL_LEGACY_INBOX_ROOT`, every older agent's `outbox/*.md`. Nothing is
moved; a seen-mark per id makes the next call show only newer reports
(`--peek` leaves the mark).

3.3 **One spool root: `/var/spool-hub`**, the harness default. It is mode
2770, group `spool-agents`, which holds both the box user and the agent user,
so an agent running as the agent user and the orchestrator share it. The
desk's own root (`<box user home>/.local/share/csi-spl/cloud/<env>/desk/...`)
is NOT usable for this: it is 0700 to the box user because it holds the box
key (measured 2026-09-29), so an agent could neither read its inbox nor
answer there. The orchestrator gets a mailbox in it once
(`next-agent-id.sh --claim <ORC-ID>`, done for CLE-001 on 2026-09-29), spawns
with `SPOOL_ORCHESTRATOR_ID=<ORC-ID>`, and reads reports with
`agent-inbox.sh --as <ORC-ID>`. Its desk seat (the web UI leg) is unchanged.

3.4 Tests: `tests/test-agent-send.sh` (29 checks: both routes, an old agent
with a desk spool dir still goes legacy, pass-through exit codes, no mailbox
= 3, the inbox listing and its mark).

## 4. Steps

4.1 PROOF, before any flip (touches no live agent):
- a throwaway agent spawned by the csi-spl harness into the desk root; the
  orchestrator id -> it (`agent-send.sh`, via spool, pane poked), it -> the
  orchestrator (its seed tells it to reply with `spool-send.sh`), seen with
  `agent-inbox.sh`
- an older agent (spawned by the frozen engine) reached through
  `agent-send.sh` (via legacy), poke shown in its pane

PROOF RUN 2026-09-29 (n=1 each, trunk `49e0401a`, this box's tmux server):
- throwaway `CLE-9048` spawned by the csi-spl `spawn-window.sh claude` into
  `/var/spool-hub` as the agent user, orchestrator CLE-001: it sent
  `hello from CLE-9048` at 06:02:19Z; `agent-send.sh --from CLE-001 CLE-9048`
  printed `via: spool (CLE-9048 is in /var/spool-hub/registry.tsv)`,
  `poke: %202`, rc 0 at 06:02:26Z; it answered `pong 3e775b3b...` on the SAME
  task at 06:02:35Z; `agent-inbox.sh --as CLE-001` listed both (`new: 2
  spool`); closed with `tmux-close-window.sh --agent CLE-9048`
- an older agent (CLE-35090, spawned by the frozen engine):
  `agent-send.sh --from CLE-001 CLE-35090` printed `via: legacy`, the frozen
  sender wrote the `.md` file and poked the pane ("prompt verified clear"),
  rc 0, and the agent read it. The frozen sender still writes the sender as
  `CLE-01` for `CLE-001` (its two-digit normalising, unchanged from today)

4.2 Parity green on the trunk tree the box will run:

```bash
cd <csi-spl checkout>/csi-spl-orc && HARNESS_REF_DIR=<frozen engine>/ysg-box-orc/src/bash/features/spawn-agents ./run -a do_check_harness_parity
```

4.3 Announce the go-time and the rollback line to the orchestrator (inbox) and
in the blocker topic; wait for its confirmation. Quiet window: after 19:00Z.

4.4 The orchestrator switches its sends to `agent-send.sh` and its report
reads to `agent-inbox.sh`, with this env in its session:

```bash
export SPOOL_ROOT=/var/spool-hub SPOOL_ORCHESTRATOR_ID=<ORC-ID> SPOOL_LEGACY_INBOX_ROOT=<legacy message root> SPOOL_LEGACY_SEND=<frozen engine>/ysg-box-orc/src/bash/features/spawn-agents/scripts/inbox-send.sh
```

4.5 As the agent user, move the frozen engine's rendered commands and skills
aside. The installer never overwrites a file it did not write, so this is what
lets it render its own:

```bash
ts=$(date -u +%Y%m%dT%H%M%SZ); mkdir -p ~/.claude/.pre-048-$ts && cd ~/.claude && mv commands/{claude,agy,grok,qwen}-spawn.md commands/spawn-an-agent.md commands/riname.md commands/tmux-close-window.md skills/agent-msg skills/exit-clean skills/kill-your-self .pre-048-$ts/
```

4.6 As the agent user, render the csi-spl harness for the desk root (no seat,
no CLI changes):

```bash
SPOOL_ROOT=/var/spool-hub SPOOL_ORCHESTRATOR_ID=<ORC-ID> bash <csi-spl checkout>/csi-spl-orc/src/bash/features/spool-install/install.sh --cli none --no-seat --no-hooks
```

4.7 Add the tmux line the installer printed to the box user's `~/.tmux.conf`,
replacing the frozen engine's `agent-status.conf` line.

4.8 After the flip: the orchestrator spawns one small real agent through the
new `/claude-spawn` and completes a round trip. Any failure: section 5.

4.9 Rewrite the frozen engine's FROZEN.md per its §1.4 (retired: the box runs
the csi-spl harness), landed with `frozen-exception: <csi-spl sha>`.

FLIP RUN 2026-09-29 (n=1, trunk `2db3a7fe`):
- 4.5 moved 7 commands + 3 skills to `~/.claude/.pre-048-20260929T121954Z`
- 4.6 install.sh rc 0: `skills: 20 written`, spool 1.1.3 built into the
  agent user's tools, a new `spool-agent` shim + config (none existed); the
  rendered `/claude-spawn` runs `SPOOL_ROOT=/var/spool-hub
  SPOOL_ORCHESTRATOR_ID=CLE-001 ... spawn-window.sh`; the running session
  listed the new skills without a restart
- 4.7 first held back (agent-top was not ported), then DONE 2026-09-29 12:32Z
  once it was (`ebf90cd8`, SPL-1160):
  - the box user's `~/.config/spool-agent/env` gives agent-top
    `SPOOL_ROOT=/var/spool-hub`, `SPOOL_ORCHESTRATOR_ID=CLE-001`,
    `SPOOL_LEGACY_INBOX_ROOT=<legacy message root>`, `SPOOL_BOX_TAG=<tag>`
    (tmux run-shell starts it with a bare environment)
  - the snippet rendered to `~/.local/share/spool-agent/tmux-agent-status.conf`;
    the one `source-file` line in `~/.tmux.conf` points at it (backup
    `~/.tmux.conf.bak-048-20260929T123211Z`)
  - checks before the swap: the status line from both copies identical
    (`agents 9 >0 ?0 !8 .1 orc=0`), and the new badge rules wanted 0 renames
    on the 9 live window names
  - the frozen copy's badge loop (pid 1372) stopped, the snippet sourced: the
    new loop runs from the csi-spl checkout on the same pidfile; 2 passes, 0
    window names changed
  - 2026-09-29 14:42Z, the window sorter too (SPL-1160 `693b85af`): a dry
    run of the csi-spl sorter against the live server wanted 0 swaps (it
    agrees with the frozen one); the snippet now carries the four sort hooks
    and prefix+S; `~/.tmux.conf`'s `window-sort.conf` line is commented out
    (backup `~/.tmux.conf.bak-048-20260929T144209Z`); after several
    hook-firing passes: 0 swaps wanted, no attached client moved
- 4.8 round trip through the rendered command: `CLE-35098` (auto id) sent
  CLE-001 a hello at 12:20:33Z, `agent-send.sh` went via spool with a pane
  poke, it answered pong on the same task at 12:20:51Z, `agent-inbox.sh`
  listed both; window closed with `tmux-close-window.sh`
- running agents: no restart needed; they keep their markdown inbox and are
  reached through `agent-send.sh`'s legacy route

## 5. Rollback (one line, as the agent user)

```bash
cd ~/.claude && for f in commands/*.md skills/*/SKILL.md; do grep -q 'spool-install: sha256=' "$f" && rm -f "$f"; done; cp -a .pre-048-20260929T121954Z/*.md commands/ && cp -a .pre-048-20260929T121954Z/{agent-msg,exit-clean,kill-your-self} skills/
```

The tmux line, as the box user (restores the frozen copy's status line and
badge loop):

```bash
cp -p ~/.tmux.conf.bak-048-20260929T123211Z ~/.tmux.conf && kill "$(cat /tmp/agent-top-badge-loop.pid)"; rm -f /tmp/agent-top-badge-loop.pid; tmux source-file ~/.tmux/agent-status.conf
```

The window sorter, as the box user:

```bash
cp -p ~/.tmux.conf.bak-048-20260929T144209Z ~/.tmux.conf && tmux source-file ~/.tmux/window-sort.conf
```

The orchestrator's side needs no rollback step of its own: `agent-send.sh`
reaches older agents through the frozen engine's own sender, so going back to
calling that sender directly is always safe. Agents spawned by the csi-spl
harness in between stay reachable through `agent-send.sh` (or `spool-send.sh`).
