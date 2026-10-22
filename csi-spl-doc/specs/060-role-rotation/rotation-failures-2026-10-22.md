# Rotation failures 2026-10-15..2026-10-22: one cause per kind

SPL-2891, epic SPL-2398. Investigation only, nothing built: each open kind
has a proposed fix and its red control, for the owner to approve first.

- Code read at `origin/master` 6a3056658.
- Box 1 is the box ranked first for both roles; box 2 is the other one.
  `<box-1>` and `<box-2>` stand in for their names in the quoted log lines.
- Sources, each read once on 2026-10-22 at about 14:15..14:50Z:
  - The prd hub, tenant t1:
    `SQL="select ts, from_id, task_id, body from messages where tenant_id='t1' and ts > now() - interval '8 days' and body like '%ROTATION FAILED%'" ./run -a do_spl_db_query`
    -> 46 rows, 19 of them notices.
  - Box 1: `dispatch/rotate.log` (38555 lines), `lease.log` (3257 lines),
    `registry.retired.tsv`.
  - Box 2: the same logs, grepped read-only by the orch holder there. It
    returned 110 lines plus the cron tree's reflog.
- All times are UTC.

## 1. The table

| # | kind | n | cause | fixed by / still open | proposed fix | its red control |
|---|---|---|---|---|---|---|
| 1 | orch ACK: no ack within 900s, seat switch back c-001 -> g-001 (box 2) | 12 in t1; 19 in box 2's rotate.log, hourly 10-19 17:23Z..10-20 12:22Z, plus 1 SPAWN 'Settings Error' at 08:07Z | The claude successor started in the box user's home dir. Claude read that home's `.claude/settings.json` as project settings. First the file was mode 0600, so the session stopped on the 'Settings Error' menu. Once the file was readable, its hook refused every Bash call. Either way the session could not run its ack. | **Fixed**: dc376ddd6 (the menu fails the start at once), 27cc7160c (the settings writer keeps the file mode), bbfd2c793 (a successor never starts in a home dir). The cron tree first had bbfd2c793 at 12:12:02Z, 7 min after the last failing run (12:05Z). The hub has had no orch notice since 12:22Z. | (A) for the 20 repeats, section 2 | - |
| 2a | master PROMOTE: the lease did not move to c-003 in 240s (box 2) | 2: 10-16 19:19Z, 10-22 10:19Z | Box 2 held dispatch only while box 1 was demoted after an outage. During box 2's HOLD, box 1 took the lease back (`<box-1> takes over from c-002@<box-2> (silent 63s, rank 1 -> 0)`, 23 s after the hold). Both FAIL lines read `(it is c-002@<box-1>)`. `spl_disp_wait_holder` accepts only `$f` or `$f@$ROTATE_BOX`. HOLD has no branch for a lease that moved to another box; RELEASE does (FR-044). The role was served the whole time. | **Open** | (B) HOLD: a lease now on another box ends the rotation as `HOLD SKIP standby (lease $LH)`, with no alert | `dispatch-rotate.tst.sh`: the stub lease reads `c-002@<other box>` after the hold. Today: `FAIL HOLD` + `do_spl_ask_put ... PROMOTE`. Fixed: `HOLD SKIP standby`, no `ask_put`. |
| 2b | master PROMOTE (box 1) | 1: 10-16 17:19Z | The hub was unreachable: `HUB-UNREACHABLE` at 17:14:21Z and 17:14:53Z, before `GATE OK` at 17:15:07Z. The lease read `none@unreachable` from 17:16:40Z. GATE does not check the hub. | **Open**. SPL-2865 (b475d1046) added the `fleet.<role>.hub-down` marker, but only `spl_fleet_switch_tick` reads it. | (C) GATE: `GATE SKIP hub-down` while `fleet.dispatch.hub-down` is younger than `LEASE_STALE` | `dispatch-rotate.tst.sh`: a fresh `fleet.dispatch.hub-down`. Today: GATE OK, then FAIL HOLD + `ask_put`. Fixed: `GATE SKIP hub-down`, no hold written. |
| 3 | dialog 'usage limit' (box 2, watchdog restart of c-002) | 1: 10-18 00:54Z | The watchdog restarted c-002 for a stall (`cause=S9 S9 input=609s`). The new claude session opened on the 'usage limit' dialog: the agent user's claude login was at its limit. `do_spl_agent_restart` checks no vendor limit before it spawns. The role rotation does (`claude cannot act (... kind=limit)`, rotate-lib). | **Open**, no commit since 10-18 in `spl-agent-restart` / `spl-watchdog` names it. **Unproven**: whether the limit also caused the stall (box 2's `wd.log` was not read). | (D) RS-GATE: a seat whose vendor has a fresh limit verdict is not restarted: `RS-GATE SKIP vendor limit`, the role failover's job, no alert | `agent-restart.tst.sh`: a fresh limit verdict for the id. Today: RS-SPAWN, then RS-SPAWN FAIL on the dialog + ALERT. Fixed: `RS-GATE SKIP`, no spawn. |
| 4 | dialog 'Settings Error' (box 2, orch SPAWN) | 1: 10-20 08:07Z | The same cause as row 1. That run already had dc376ddd6, so it failed in 2 min instead of 15. | **Fixed**, see row 1 | - | - |
| 5 | orch SPAWN: tmux refused to rename the pane (box 1) | 1 in t1: 10-19 15:10Z; box 1's log has 4 more lane ones (10-14 01:05Z, 10-16 10:04Z and 17:08Z, 10-19 18:00Z) | The old window was gone before SPAWN renamed it. Lanes: `registry.retired.tsv` retires c-950, c-279 and c-304 26..62 s before their FAIL (01:04:44 vs 01:05:46, 10:03:29 vs 10:04:11, 17:08:26 vs 17:08:52). Orch: 13 s after the FAIL, the S3 restart found no c-001 process. The rename's stderr goes to `/dev/null`, so no log names the reason. The notice's "old session kept: pid" names a pid that is gone. **Unproven** for c-492 (10-19), which has no retired row. | **Open** | (E) `spl_rotate_spawn`: on a failed rename, keep tmux's stderr. If the old pane or pid is gone: a lane's rotation ends `SPAWN SKIP retired`, no alert; a role leaves it to the S3 restart, with a note and no "old session kept" | `orch-rotate.tst.sh` + `lane-rotate.tst.sh`: a stub tmux whose rename-window fails, old pid dead. Today: FAIL SPAWN + `ask_put`. Fixed: SKIP, no `ask_put`. |
| 6 | master RELEASE: the lease did not come back (box 1) | 1: 10-19 19:25Z | The master was grok (g-002) and the failover claude (c-003). The fleet's vendor rank (6fe4a710a, same day) moved the lease to c-003 (`VENDOR dispatch: g-002@<box-1> (grok) -> c-003@<box-1> (claude)`, 19:16:18Z). After the release, a lower-ranked master gets it back only by `FALLBACK-WAIT`: 240 s of silence, logged at 19:22:39Z. RELEASE also waits 240 s, from 19:21:41Z, so it expired first, at 19:25:41Z. The lease was back on g-002 at 19:28:23Z. | **Open**. Rare: the only RELEASE FAIL in box 1's log since 10-19. | (F) RELEASE: a lease still on an able failover whose vendor ranks above the master's ends `RELEASE SKIP vendor rank`, no alert | `dispatch-rotate.tst.sh`: grok master, claude failover, the stub lease stays on c-003. Today: `RELEASE FAIL` + `ask_put ... RELEASE`. Fixed: `RELEASE SKIP`, no `ask_put`. |

The 19 notices are rows 1 (12), 2a (2), 2b (1), 3 (1), 4 (1), 5 (1) and 6 (1).

## 2. The one cross-cutting gap: no streak dedupe

Row 1 was one cause. It produced 20 FAIL runs in 19 hours, all naming the same
old pid 1044116, and 12 t1 notices. `spl_rotate_alert` (rotate-lib) puts an
ask and a notice on every failed run.

- **(A)** One alert per streak, keyed on role, phase and old pid. A repeat
  logs `ALERT SKIP repeat <n> of ask <id>`. The streak ends at the next
  `DONE OK`.
- **Red control**: `orch-rotate.tst.sh` runs two ACK failures with the same
  old pid. Today: 2 `do_spl_ask_put`. Fixed: 1.

## 3. Out of scope, not touched

The SPL-2865 code, the lease loop timings, the watchdog rules, the launchers,
the WUI and the hub. Fixes B..F change only the rotation's GATE, HOLD, SPAWN
and RELEASE outcomes and their alerts, never when the lease moves.
