# Drill record: the reboot path (spec 102 10.1, T014), 2026-10-08, the desk box

The section 5 results of the checklist
[drill-reboot-2026-10-07.md](drill-reboot-2026-10-07.md), run once (n = 1) on
the desk box (where the dispatcher seats c-002 / c-003 normally sit; the other
box is `sat`). The box was restarted on the owner's request (a forced restart
with 11 live agents), and the orchestrator (c-001@sat) ran it as the T014
drill.

Sources:

- c-001's section 5 table on the desk box: spool msg `646bea93` on task
  `9324b7b9`, also kept as `dispatch/c001-<box>-drill-section5-20261008.md`
  under the desk box's spool root.
- Dispatch lease timings: `dispatch/lease.log` on `sat` (the times below) and
  on the desk box.
- The orchestrator's hold note `c-001-<box>-restart-drill` lives on `sat` only,
  not on the desk box; c-001@sat sent its text inline (msg `36427943`).
- The before-list: the dispatcher's `dispatch/c002-<box>-restart-before.txt`
  under the desk box's spool root (11 agents: seats c-002 c-003, lanes c-566
  c-571 c-575..c-581).

## 1. Before the boot

- Desk-cron sha `25e37d31a` (`grep -c spl_wd_boot_pass` = 2). The cron had
  it; it was not pulled by hand before the boot.
- Old `@reboot` boot-restore line: **kept** (orchestrator's 2.2 decision:
  forced restart, 11 live agents, the fallback kept).
- Steps 2.1 (pull) and 2.3 (snapshot) were **not done**: the before-steps
  reached the desk box at 18:15:26Z and the box went down before they were
  acted on. The dispatcher's before-list stands in for the 2.3 snapshot.

## 2. Results (checklist section 5)

| field | value |
|---|---|
| box | the desk box |
| desk-cron sha | 25e37d31a (`grep -c spl_wd_boot_pass` = 2); not pulled by hand before the boot |
| old boot line | kept |
| reboot command (UTC) | not seen; btime is the bound |
| btime after | 1791483482 = 2026-10-08T18:18:02Z |
| agents running before (n, ids) | not snapshotted (2.3 not done); the dispatcher's before-list: 11 (c-002 c-003 c-566 c-571 c-575 c-576 c-577 c-578 c-579 c-580 c-581) |
| back after the boot | 13 claude sessions, all `--resume` (the OLD `@reboot` path): seats c-001 c-002 c-003 + c-545 c-566 c-571 c-575 c-576 c-577 c-578 c-579 c-580 c-581; exactly one claude per id (0 duplicates) |
| restarted by the watchdog (n, ids) | **0**: `BOOT 2026-10-08T18:18:02Z done: 0 restart(s) started (cause reboot)` at 18:21:12Z (+190 s after btime), logged by each of the 3 instances |
| left alone (id: why) | c-576..c-581: it runs (a window or a process carries it); g-095..g-102, g-108..g-113, g-197, g-205, g-229, g-234: done, workdir gone; g-104/105/106: not running at the boot (no verdict before it); g-432/433/434: not running (last verdict 140954 s before the box's last). Not named in the BOOT lines: c-545 c-566 c-571 c-575 (brought back by the old path first) |
| first `RS-SPAWN OK` after the boot (s) | n/a (no watchdog restart; 0 `-rs-` lines since the boot) |
| last `DONE OK` after the boot (s) | n/a |
| `--resume` processes after | 13 (expected with the old line kept) |
| second restart of any id | **no** (restart count still 0 after a 1-min wait, 18:23:49Z) |
| verdict | **pass on safety** (one session per id, no double restart, `boot.seen` = btime, count stable); **the new watchdog restart path is NOT proven** |

Watchdogs: 3 instances up at 18:18:08Z, heartbeats on git sha `25e37d31a`.

Dispatch lease (`sat`'s `lease.log`):

| UTC | event |
|---|---|
| 18:18:40Z | failover c-002@`<desk box>` -> c-002@sat (desk box silent 242 s) |
| 18:25:32Z | handback c-002@sat -> c-003@`<desk box>` |

The desk box's own `lease.log` records the same two moves at 18:19:07Z and
18:25:26Z, as its own watcher saw them.

## 3. Findings

1. **The old path resumed a finished lane.** The `--resume` line brought back
   c-566, whose worktree was already gone (the lane had finished); c-001 then
   closed it by hand. The new watchdog path would have left it alone with
   `done: workdir gone`, as it did for the g-0xx lanes. An argument for
   retiring the old line, after a drill that proves the new path.
2. **The next drill removes the old line first**, and needs the owner's go
   for the reboot itself. With the line kept, the old path wins the race
   (2.2 predicts this for "kept"), so the watchdog's boot branch only sees
   running agents and restarts 0. Removal, before that reboot:

   ```bash
   cd /opt/csi/csi-spl-desk-cron/csi-spl-orc && BOOT_CRON_ACTION=remove DRY_RUN=0 ./run -a do_spl_agent_boot_restore_install_cron
   ```
