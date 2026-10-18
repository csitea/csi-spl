# sat alone panel — reviewer seat grok (g-400)

Plan: [sat-alone-panel-plan.md](../sat-alone-panel-plan.md) v0.1
(`327fd855901927a9d8eb090673a0dc670e1ca322`). Issue: SPL-2472 (the plan's
build rows stay on SPL-2471). Rules: [rounds-rulebook.md](../rounds-rulebook.md).
Task: `dispatch-721ad6e4`.

**Verdict: change.** Not a reject. The inventory classes are usable. The
frozen ids, the runbook's two posts, the single drill pass line, and two
batch-1 file overlaps have to be edited before v1.0.

**Tally on the numbered rows: 28 agree / 20 change / 0 reject.**
Inventory 18 / 10, runbook 3 / 4, way back 3 / 2, build 4 / 4.
The drill block, the section 6 chaos count, and section 7.1 are three more
changes. Section 7's cannot-list agrees.

`<pc box>` is the plan's placeholder. This file does not name that box.

## 0. How this was measured

Read-only on sat, 2026-10-18T02:03Z to 02:10Z, n=1 per command unless a row
says otherwise. Nothing was started or stopped. No prd mutation. The desk
probe was not run (`DRY_RUN=0` posts). The directive key check was not run
(it stops the agent that holds the keyring).

- Plan bytes: `git diff --stat 327fd855901927a9d8eb090673a0dc670e1ca322 origin/master -- csi-spl-doc/doc/md/sat-alone-panel-plan.md` is empty.
- Master tip at the read: `b423835875907150a0f22b65da3f97dfee579d3f`. That tip adds the other seat's file and, via `e3655cac9`, moves two line cites. The plan's own baseline remains `7b5ce46a4`. Line cites below are the worktree at `327fd855` unless a row says master.
- Code was read in this worktree. Live state was read on sat.

## 1. Inventory

| # | verdict | class | evidence |
|---|---|---|---|
| 1 | change | covered now | `LEASE_CMD=show` at 02:03:39Z prints `g-002@sat`. `LEASE_CMD=fleet-show` prints `orch c-001@sat` and `dispatch g-002@sat`. The plan freezes `dispatch c-003@sat`. Re-read the id at T+0. Sat does hold both at this read. |
| 2 | agree | covered | `lease.conf` has 3 priority lines. The bare line is `<pc box>,box-desk,sat`. Both per-role lines are `sat,<pc box>,box-desk`. The per-role lines rank sat first. |
| 3 | agree | covered | `lane-map.sh` at 02:07Z: 6 role rows `@sat` and 6 `@<pc box>` (ids `c-001`..`c-003` and `g-001`..`g-003`). |
| 4 | change | can | Same map, 39 lines: 21 `@sat`, 13 `@<pc box>`, 5 with no box. The plan freezes 16 vs 18 at 01:20Z. Re-read at T+0. The class stands: without leave, a lane on `<pc box>` stays there. `c-423` is still on `<pc box>`. |
| 5 | change | can | `do_spl_box_pick` rc 0 at 02:08Z: `pick=sat`, sat load5 8.29 of 16 cpus, 51%, band 50..85, one BOX line. An earlier read at 01:58Z also picked sat and listed `<pc box>` as DEGRADED (last beat 329 s, `max_gap_s` 120). The plan's frozen proof is the opposite moment (`pick=<pc box>`). `dispatch/box.leave` and `dispatch/cordon` are absent. `grep -rniE 'cordon\|offline.window' csi-spl-orc/src` is 1, a comment in `spl-box-presence-watch.func.sh:8`, not an action. No `do_spl_box_cordon`. The rule agrees; the frozen snapshot and the "grep -> 0" do not. |
| 6 | agree | covered | `all.env.yaml:1119-1124`: `window_min` 10, `min_beat_pct` 50, `beat_s` 10, `max_gap_s` 120, `hold_min` 30. Pick loads that cnf at `spl-box-pick.func.sh:106` and takes the verdicts at 107; degraded is 172. On master tip the same keys sit a few lines lower (`e3655cac9`); the values match. |
| 7 | agree | waits | `spl-spawn-place.func.sh:307` on master (`:300` on this worktree) logs `hold: ask ... is pinned to ...; it stays queued` and returns. Live pinned count was not measured. |
| 8 | agree | cannot | Lane map at 02:07Z still has `c-423` on `<pc box>` and not on sat. |
| 9 | agree | can | `spawn-remote.sh:20` and `:91`: `SPAWN_REMOTE_WAIT` default 300. A cordon (row 01) is what stops a new request. The action is not built (row 5). |
| 10 | agree | waits, can with row 03 | The issue-close tag is absent from sat's crontab. The state dir `issue-close-landed/prd-t1` exists; `ls` of it is 0 files (`ls -la` is 3 lines). `issue-close-landed-cron.sh:7-10` is one cursor, one box. The script header says hourly; the manifest row is `*/5` (`box-crons.manifest:28`). The plan's `*/5` matches the manifest. |
| 11 | change | covered | The class holds: the tunnel exists to reach `<pc box>`, and `fleet-show` answered via the hub. The proof does not. `ss -ltn` at 02:06Z has no `:2222` listener (also none at 01:55Z and 01:56Z). `reverse-tunnel` is not in sat's crontab. Do not treat one `ss` line as "the listener is up". |
| 12 | agree | waits | Tag absent. Manifest daily 16:37 local is after today's 07:00-10:00 local window. Which box runs it today was not measured. |
| 13 | agree | waits | Tag absent. Monday 06:53 local; 2026-10-18 is a Sunday, so it is not due inside today's window. |
| 14 | agree | gap on sat | Tag absent. 02:41 local is outside today's window (the slot already passed; the next is the following night). This is sat's own missing copy, plus row 06, not a `<pc box>` binary. |
| 15 | agree | no row | Both graft tags absent. `command -v graft` rc 1. |
| 16 | agree | covered | Sat crontab: 40 `# csi-spl:` tags, rc 0. The 7 the plan names are exactly the absent ones (rows 10-15). Present includes `desk-reconcile`, `desk-reconcile-prd`, `wd-start`, `wd-start-boot` (the plan's words are "watchdog start"), and `done-claim-check` (per box, not a second single-cursor closer). The account the scratch-sweep installer targets has 1 tagged line. |
| 17 | change | covered only while sat holds the lease | `cron-prd.out` at 02:06Z: 46 `OK responder sweep (prd, holder)` lines, 8 lines with `standby`, 8 `sends nothing`. Last standby is the sweep after `2026-10-18T01:47:44Z`, lease held by `c-002@<pc box>`, log text `this machine's responder sends nothing`. Latest holder is the sweep after `2026-10-18T02:02:42Z`, `1/1`. `ps` count of `spool hub-run` is 9. `spl_rsp_role` (`spl-responder-sweep.func.sh:104-109`) is standby when the holder box is not this machine and the lease is fresh; standby does not answer (`:63-65`). Unknown (stale or unreachable, `LEASE_STALE` default 180 at `spl-dispatch-lease.func.sh:54`) still answers. A holder line is not a Seen reply (`RESP_SEEN_REPLY` defaults off). |
| 18 | change | can | Class stands. Exact `FATAL Command 'do_spl_desk_up_tenants'` in `/var/csi/csi-spl/desk-reconcile/cron.out` is 928 at 02:06Z (the plan's 913 is an earlier window). `FAIL could not seat` is 60176. The log line is `spl-desk-up-all.func.sh:133`. `spl-desk-up.func.sh:125` (not announced) was not the line in that stdout, so the cause of the non-zero return is still unread. Dev hub-run tails checked earlier this session show an older upload-token warning, not this seat failure. |
| 19 | agree | can | `no sat-rsp desk seated` is 7167 of 7167 dev sweep lines. `OK responder sweep (dev, holder)` is 0 and the standby form is 0 (`grep -c` rc 1). |
| 20 | change | covered | Class stands. This seat's `ENV=dev` and `ENV=prd` `do_check_deploy_lag` at 02:08Z, rc 0, tree `327fd855`: both hubs `served=9c4397b6` `n=0`; both wui `served=e3655cac` (this commit or a later one). The plan freezes wui `7b5ce46a`. `do_spl_api_smoke` was not re-run. |
| 21 | change | covered while the variable holds | `gh variable list --repo csitea/csi-spl`: `SPOOL_CI_RUNNER` = `ubuntu-latest`, updated 2026-10-12T15:53:41Z. Repo runners 0, org runners 0. `10_ci-quality.yml:2-6` and the `runs-on` expression (16 jobs, first at line 163): input, else `vars.SPOOL_CI_RUNNER`, else `[self-hosted, spool-ci]` on this repo, else `ubuntu-latest`. Jobs queue when the runner is offline (header lines 24-27). If the variable is cleared, the gate falls back onto a box, and sat has no runner. `ci_overflow.enabled` is true (`all.env.yaml:1159-1160`): the cnf text says a long hosted queue points that variable at the local runners. `ci_busy` (`:1125-1134`) still describes a self-hosted job lowering the pick band; dormant while the variable forces `ubuntu-latest`. `99_runner-smoke.yml:18` hardcodes `[self-hosted, spool-ci]` and is not the quality gate. This seat did not re-read job runner names for run `39085580284` (an earlier read had null names) and does not restate them. |
| 22 | agree | covered | `docker ps --format '{{.Names}}'` is the three infra containers only. `lde` and `cloud-sql-proxy` were not among them. Applies stay owner-gated. |
| 23 | agree | covered for headless | `command -v google-chrome` rc 0. A browser on the owner's screen still cannot move. |
| 24 | agree | covered | Name list on sat at this read: exactly two, `key-csi-spl-dev` and `key-csi-spl-prd`. Names only. |
| 25 | agree | waits | `grep` of `csi-spl-orc` cron scripts for the relay and backup key names: no matches. Nothing in that cron path needs them for this window. |
| 26 | agree | cannot | Owner order, as the plan states. This seat did not go looking for the keys. |
| 27 | change | waits, and the sat half is unverified | `directive/README.md:48-54` matches: a box without the key verifies and cannot issue. `gpg --list-secret-keys --with-colons` on the default keyring: `sec:` count 0, rc 0. `directive-verify.sh:173-177` stops the key agent, so `--check-key` was not run. "The owner can type at sat" is unverified. Do not write that the signer is absent. |
| 28 | change | risk, number not shown | `/var/csi/csi-spl/agent-login-check/cron.log`: `grep -c -i weekly` is 0. Last line `2026-10-18T02:06:01Z login-check@sat: probe=ok stuck_login=0 stuck_limit=0 ... alerted=0`. The plan's "96% on 10-17" is not in this log. The pick rule the plan does not name: `quota.weekly_max_pct` 90 (`all.env.yaml:1145-1146`); at or over that, `do_spl_box_pick` does not place that vendor. This seat did not read a `wk=` row, so it does not say sat is over 90. |

## 2. Runbook

Times are ordered: T+0, T+1 (3.2 and 3.3 together), T+8 (3.4 and 3.5), T+9, T+10. Two of the seven steps are posts, and 3.2 cannot run today.

| step | verdict | evidence |
|---|---|---|
| 3.1 | change | A topic reply, not a `./run` action. Say so. The proof is the post. |
| 3.2 | change | `do_spl_box_cordon` does not exist (row 5). Today's window cannot run this step. The plan already says "not built"; section 7.1 must say the same, or the window reads as if the step were available. |
| 3.3 | agree | `do_spl_box_leave` exists (`spl-box-leave.func.sh:46`). `spawn-window.sh:151` exits 6 while `dispatch/box.leave` exists. The marker is absent on sat now. |
| 3.4 | agree | `do_spl_spawn_enqueue` exists (`spl-spawn-enqueue.func.sh:31` here, `:32` on master). The step still needs 3.3's table. |
| 3.5 | agree | Same command as row 1. At 02:03:39Z both ids were `@sat`. |
| 3.6 | change | Deploy lag is green on both envs at 02:08Z (row 20), not "expected red". The dev desk probe is the expected red (row 18). This seat did not re-run `do_spl_api_smoke`. Split the proof. |
| 3.7 | change | A topic post, not a `./run` action. The proof is the post. Naming rows 8 and 26 is right. |

## 3. Way back

| step | verdict | evidence |
|---|---|---|
| 4.1 | agree | `do_spl_box_join` exists (`spl-box-join.func.sh:21`). |
| 4.2 | change | Same missing action as 3.2. |
| 4.3 | agree | Per-role lines rank sat first (row 2). A move would be a finding. |
| 4.4 | change | The closer's cron is not installed on sat (row 10). Catch-up on `<pc box>` is the waits class. The measure-after "done within 10 min while `<pc box>` is off" needs row 03 to install the cron on the holder, not only to move the cursor. |
| 4.5 | agree | The hold log is row 7. |

## 4. Drill

D1-D9 each have a pass count. Prd is in D3, D6, D7. Dev is in D4, D6, D7. Those nine rows agree as checks.

**Change** the one line "Pass = D1..D9 all pass", and the sentence "read-only except the probes".

- The soft cut runs 3.2, 3.3, and `LEASE_CMD=stop` for real. That is not read-only. The next sentence ("steps 3.2-3.4 run for real") is the one to keep.
- D1 is 30 samples at 60 s and D2 is 10 samples at 3 min. Each is one 30 min run, not a claim about the whole 04:00-07:00Z window.
- Hard cut, before rows 01 and 04: record D1, D3, D5, D6, D7, D9. D4 is expected 0 of 3 until row 04. D8 does not apply until a leave table exists ("nothing to switch"). D2 passes only while `<pc box>` stays silent past `max_gap_s` or is cordoned. At 02:08Z the pick is already sat, so D2 is not automatically red; if beats resume before the lid closes, the pick can move back until row 01 exists.
- Soft cut, after rows 01 and 04: D1-D9 all pass, and D2's 10 of 10 require the cordon because `<pc box>` stays up.

`do_spl_sat_alone_drill` does not exist. No D10. The local-hub check in section 6 can stay a candidate.

## 5. Section 6

The fit table agrees. Re-opened on this tree: `box-hardening-round-1.md:8-12`, `secrets-round-1.md:8-12`, `security-baselines.md` (`do_check_baseline_growth` at line 30; the plan's `:14-30` covers that table). The six named actions exist: `do_spl_db_restore_drill`, `do_spl_security_round_queue`, `do_spl_local_hub_harden_check`, `do_spl_secret_age_report`, `do_check_baseline_growth`, `do_spl_sshd_harden` (and `do_spl_box_ports_loopback`). The restore drill refuses prd at `spl-db-restore-drill.func.sh:36`.

**Change** the chaos sentence. The same grep on this worktree returns 4 files, not 3: `perf-round-5/m1.md`, `reliability-round-plan.md`, `sat-alone-panel-plan.md`, `refactor-round-1-plan.md`. The two extras were not line-checked, so this seat does not say what they claim, only that the count is 4.

## 6. Section 7

The six cannot-items agree (finance keys, `c-423`, the owner's screen, undrained lanes, dev desks, the closer and the rates).

**Change 7.1.** "Both leases are on sat, so prd answers continue" was false for the standby sweep after 01:47:44Z and true again after 02:02:42Z (row 17). It is true while the dispatch lease is on sat, which it is at 02:03:39Z (`g-002@sat`). It is false while a fresh lease sits on `<pc box>`: sat's prd responder sends nothing until the lease moves or goes stale (`LEASE_STALE` default 180). The placer already skipped a silent `<pc box>` at 01:58Z and picked sat at 02:08Z, and it can pick `<pc box>` again if beats resume, until row 01. Lanes already on `<pc box>` do not move until 3.3. Dev desks do not answer (row 18).

## 7. Build rows

Implementation subjects stay `SPL-2471`. This review does not retitle them. `e3655cac9` matches the vendor column (docs and reviews only for that vendor). Not a change to request.

| # | verdict | evidence |
|---|---|---|
| 01 | agree | New cordon file plus pick and place. The action is absent today (row 5). The red control (a cordoned box is picked, on master) is the right shape. |
| 02 | agree | Needs 01. New file. Wraps 3.2-3.4. |
| 03 | change | Moving the cursor is not enough: the cron tag is absent on sat, so the measure-after fails until the holder installs it. The install list is `box-crons.manifest`, which row 06 also edits (`:21`, `:30`, `:35`; issue-close is `:28`). R1: those two cannot both be batch 1. Put the manifest line in row 03 and move 06 to batch 2, or one row owns every manifest edit. |
| 04 | change | Name the file before batch 1. The live fail line is `spl-desk-up-all.func.sh:133`, after `do_spl_desk_up` returns non-zero. The cause is still unread (row 18), and other desk work touches `do_spl_desk_up`, so disjointness is not shown. The red control (dev desk probe fails from sat today) agrees. |
| 05 | change | Needs 01 and 04. The "9 of 9 PASS" measure-after is the soft cut only. The hard-cut line is the one in section 4 of this file. |
| 06 | agree on the sites, change the batch | The cron files and the manifest lines are real. Not batch 1 together with row 03 once row 03 edits the manifest. |
| 07 | agree | Needs 01. `lane-map.sh` is not a file row 01 touches. |
| 08 | agree | Docs, batch 3. The runbook's one home is the path the plan names. |

Batches as written (01, 03, 04, 06 in batch 1) fail R1 on the manifest (03 vs 06) and are unproven for row 04 until its file list is closed. 01's files are otherwise disjoint from 06.

## 8. Lines the inventory did not carry

- `lde` and `cloud-sql-proxy` are absent on sat (row 22's docker list; no process by those names in that list). Spec 064's local-dev row. Not needed for the cloud dev and prd window. Not a reject.
- `quota.weekly_max_pct` 90 and `ci_overflow.enabled` true are the two cnf facts rows 28 and 21 should name (section 1).
- `done-claim-check` is already on sat and is per box. It is not a missed sibling of the issue closer.

`lane-map.sh --check csi-spl-doc/doc/md/sat-alone-panel/seat-grok.md --agent g-400` exited 4 at 02:07Z: no live lane lists this path; 6 lanes record no files, so their scope is unknown. None of those titles is this panel. The brief assigns this one file. Not a plan defect.

## 9. The other seat

`seat-mistral.md` on master tip `b42383587` still ends **GOOD**, after correcting its own rows 1, 18, and 20. This seat does not adopt that. Where both seats measured, the dispatch id (`g-002@sat`), the exact FATAL count (theirs 925 at 01:57Z, this seat 928 at 02:06Z), and the dev wui sha (`e3655cac`) match. Their row 20 command is `ENV=dev` only. The runbook, the single drill pass line, and batch 1 are the changes above.

signed: g-400, plan `327fd855901927a9d8eb090673a0dc670e1ca322`, measured 2026-10-18T02:03Z to 02:10Z

<!-- seat: g-400 grok, reviewer of plan v0.1 327fd855901927a9d8eb090673a0dc670e1ca322 -->

## 10. Sign of plan v1.1

Plan v1.0 `18bd10bba7ac5f5096cab19d40a4258e43bf1d7b` is not signed. Four proof lines were wrong. Plan v1.1 `263a368a310f384d605b09a346347ebb5f086be3` corrects them. Checked 2026-10-18T02:32Z to 02:34Z.

1. Row 5 keeps DEGRADED on the 01:58Z read and the 02:19Z read, and says the 02:08Z read was `pick=sat` with one BOX line and no DEGRADED line. That is this seat's 02:08Z read (n=1).
2. Section 6 says the chaos grep on `18bd10bba` returns 5. `git grep -rliE 'pen.?test|chaos|game.?day' 18bd10bba7ac5f5096cab19d40a4258e43bf1d7b -- csi-spl-doc/specs csi-spl-doc/doc/md` returns 5 paths. The same command on `263a368a310f384d605b09a346347ebb5f086be3` returns the same 5. `refactor-round-1-plan.md:41` is the `open.test` hit. `reliability-round-plan.md:79` and `perf-round-5/m1.md:201` are the two notes that chaos is not done.
3. Row 21 on run `39085580284`: `gh api repos/csitea/csi-spl/actions/runs/39085580284/jobs` gives n=18. Conclusion success with a runner name is 13. Conclusion skipped with `runner_name` null is 5. Label `ubuntu-latest` is on all 18.
4. Row 29: `uptime -s` prints `2026-10-18 04:36:56` (+0300, so 2026-10-18T01:36:56Z). `journalctl --list-boots` previous boot last entry is `2026-10-18 04:36:02 EEST` (2026-10-18T01:36:02Z). Boot-restore log contains `2026-10-18T01:37:11Z` (n=2) and its last timestamp is `2026-10-18T01:37:45Z`.

The v0.1 verdict in sections 1-9 stays change. This section signs v1.1 only.

signed: g-400, plan `263a368a310f384d605b09a346347ebb5f086be3`, checked 2026-10-18T02:32Z to 02:34Z

<!-- seat: g-400 grok, signs plan v1.1 263a368a310f384d605b09a346347ebb5f086be3 -->
