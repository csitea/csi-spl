# Alerts fix round - plan (8 rows)

Epic: SPL-2364  
Spec: csi-spl-doc/specs/146-reliability-round  
Issues: SPL-3193 .. SPL-3198 (one per problem type), this plan SPL-3259.  
Source: the owner's ask, step 5 ("create a panel of discussion for how to fix
those problems and start on the actual fixing of them"), t1 1164741e msg
8bdcbccb. Steps 1-4: [alerts-triage-20261024.md](alerts-triage-20261024.md).  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps,
R1 disjoint files, R7 cross-vendor review), linked here, not copied.

**Status: v0.1** (editor c-122@sat, claude, `specs_and_docs`; agy, the main
for plans, is out of quota).  
Reviewer: one cross-vendor seat, placed by the dispatcher (R7). v1.0 folds its
findings and lands after the seat signs in its own commit.

**One sha:** every file:line below is on **`74c87e0dd`** (`origin/master`,
2026-10-24T22:19:54Z), read on sat. n=1 per command unless a row says so.
The incident counts are the triage report's (14 days to 2026-10-24T09:13Z),
not re-measured here.

---

## 1. How to read this

- One row = one logical change at the sites named, with a **red control**: a
  test case that fails on `74c87e0dd` and passes with the fix.
- **Terraform rows** (01, and 03 if the owner picks (B) in Q2): the lane
  writes and tests the change only. Each `terraform apply` is the owner's go
  for that apply, `dev` first, then `prd`, through the tf-runner path
  (`ENV=<env> STEP=070-gcp-monitoring make do-tf-plan`, then
  `make do-provision`). Without that go the row is "landed, not live".
- **Vendor**: every coding row is claude. `LANE_MIX_KIND=simple_coding ./run
  -a do_spl_lane_mix` -> `pick=grok` (main claude, backup grok), but grok is
  out of limits (owner, 2026-10-24) and mistral writes no code or tests
  (owner, 2026-10-17). The R7 reviewer of each row is agy when it has quota,
  else mistral (reviews are allowed to mistral).
- **Box**: no pin; the placer picks. Row 07's follow-up measurement is the
  one step that must run on box-2 (section 5).
- **Subject** (R6 reads it): `fix(ar1-NN-<slug>, SPL-<row issue>): ...`.
- **Docs**: each row names its doc file; a row with none carries
  `Docs: none (<why>)`.

---

## 2. Root causes, measured on `74c87e0dd`

### 2.1 G1 at-max-instances pages an idle hub (SPL-3193)

- Policy `instances_at_max`:
  `csi-spl-iac/src/terraform/070-gcp-monitoring/05-policies.tf:188-217`. One
  condition: `run.googleapis.com/container/instance_count` (:196)
  `COMPARISON_GT var.hub_max_instances - 1` (:197-198) for
  `var.instances_at_max_seconds` (:199), `ALIGN_MAX` + `REDUCE_SUM` per
  revision (:200-205), `combiner = "OR"` (:190), every email and SMS channel
  (`local.channels`, :191).
- cnf: `instances_at_max_seconds: 3600` (`csi-spl-cnf/csi-spl/all.env.yaml:317`,
  no env override); `hub.cloud_run.min_instances: 1`, `max_instances: 2`
  (`all.env.yaml:397-398`), so "at max" = min + 1.
- Nothing in step 070 reads CPU: `grep -c 'cpu/utilizations' 05-policies.tf`
  -> 0; `grep -c 'combiner *= "AND"' 05-policies.tf` -> 0.
- The triage's one measured episode (10-23 19:50Z, 140 min): 2 instances,
  CPU p99 max 0.06, concurrency p99 24..32 of 1000 per instance. Each
  instance served requests the whole time, so a `metric.labels.state =
  "active"` filter would very likely still count both (I believe, unchecked:
  the box and WUI WebSockets keep a request open on each instance).
- **Cause:** the condition measures instance count only, and 2 warm instances
  is the normal state of a 1..2 service.

### 2.2 G2 a planned DB apply pages error-log (SPL-3194)

- Log metric `hub_errors` (`05-policies.tf:113-123`, filter :116: severity
  >= ERROR or zerolog level error/fatal/panic) and policy `error_logs`
  (:125-154): `> error_logs_per_5min - 1` (:135-136, cnf 10,
  `all.env.yaml:308`), `duration = "0s"` (:137), 300 s `ALIGN_DELTA`.
- No snooze anywhere: `git grep -n -i snooze` -> only the triage report.
- The hub's relay tick (every 5 s, `SPOOL_HUB_QUEUE_RELAY` default,
  `csi-spl-api/src/go/spool-hub-api/internal/config/config.go:349`) logs one
  ERROR per failing call per tick, paths under
  `csi-spl-api/src/go/spool-hub-api/`: `internal/hub/relay.go:129`
  ("relay unheard posts"), `:209` ("relay reescalatable posts"), `:231` and
  `:254` ("relay queue"), `internal/hub/commit.go:59` ("unacked rows"),
  `internal/hub/live_ack.go:68` ("relay nacked posts"). A DB restart of
  about a minute is 12 ticks x 6 sites, against a threshold of 10.
- The 040 apply runs through `make do-provision`
  (`csi-spl-orc/src/make/tf-tasks.func.mk:80`), whose per-step `case`
  (:82-88) is where a step-specific pre-step already lives;
  `grep -c snooze tf-tasks.func.mk` -> 0.
- No test pins `error_logs` or `hub_errors` (git grep over the iac and orc
  tests).
- **Cause:** an owner-approved apply has no alert snooze, and every hub loop
  logs ERROR on each tick of a connection refusal that lasts seconds.

### 2.3 G3 a non-uuid task_id gets a 500 and floods ERROR (SPL-3195)

Paths under `csi-spl-api/src/go/spool-hub-api/`:

- `internal/msg/msg.go:185` only requires `task_id` to be non-empty; the uuid
  regex `uuidRe` (:68) is applied to `ref_task_id` (:197) and `accepts`
  (:200), never to `task_id` or `msg_id`.
- `messages.task_id` is `uuid NOT NULL`
  (`csi-spl-rdb/src/sql/postgres/spool-hub/0001_hub_core.sql:60`), so the
  insert fails with 22P02 and `internal/hub/ws.go:660-661` logs ERROR
  `store message` and answers `internal` 500. The second ERROR line is
  `internal/hub/channels.go:145` (`topic channel`, from `boxLevel`).
- The box client retries every 5xx on its next flush and parks every 4xx
  (`internal/hubclient/flush.go:230-234`), flush every 10 s: the ~9 tries a
  minute of 10-13.
- The fleet relay already maps a task NAME to a uuid v5 since 2ea249ff8
  (2026-10-03, `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-fleet-relay.sh:142-144`);
  which sender bypassed it on 10-13 is still not known (triage section 1).
- **Cause:** the hub treats a client error as a server error. A 400 makes the
  box park the message after one try.
- Not in `msg.Validate`: local same-box sends compose with `dispatch-<8hex>`
  task ids (`internal/spool/spool.go:235-251`) and must keep working.

### 2.4 B1 one hub stall fans out into box alerts (SPL-3196)

- Bench and back lines: `spl_fleet_bench_tick`,
  `csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh:1336-1412`. Verdicts
  come from the hub's box beats, judged by
  `csi-spl-orc/lib/bash/funcs/spl-box-health.func.sh:73-101`. A stall
  stops every box's beats at once, so every box goes `degraded`; with no
  healthy box the poster is `-` and the bench is recorded as not delivered
  (:1404); the back line then carries "the benched alert could not be
  delivered" (`spl_fleet_back_line`, :1388-1396).
- NO-LOCAL-AGENT: `spl_fleet_nolocal`, same file :2145-2165, after
  `spl_fleet_fresh_other` (:2131) finds no healthy box.
- "no live orchestrator": `spl_asks_orch_alert`,
  `csi-spl-orc/src/bash/run/spl-asks-tick.func.sh:359-374`, reads only the
  age of the holder's lease renewals (`fleet.orch.age`).
- None of the three checks the hub first. A signal to reuse already exists:
  `spl_wd_hub_reachable` (`csi-spl-orc/src/bash/run/spl-watchdog.func.sh:1697-1707`,
  `/version` with a 5 s cap, seam `WD_HUB_PROBE_CMD`) and the watchdog's
  `$LEASE_DIR/wd/held` marker (:1594-1597: the hub answers, its beat path
  fails), which the lease code never reads.
- `csi-spl-orc/src/bash/tests/fleet-lease.tst.sh:1037-1044` asserts today's
  "could not be delivered" back line for two benched boxes.
- **Cause:** each box alert reads a fleet-wide gap as a per-box failure, and
  posts it through the hub that caused it.

### 2.5 B2 box-2 heartbeat gaps (SPL-3197)

- The beat is sent by the watchdog tick: `spl_wd_beat`
  (`spl-watchdog.func.sh:1791-1806`) via `spl_wd_beat_call` (:1821-1827,
  `WD_BEAT_TIMEOUT` 10 s), called late in each tick (after the peers,
  self-update, ps, tmux and agent steps, :186-198); `WD_TICK` 30 s (:145),
  3 instances.
- The bench rule is bash, not Go: `spl-box-health.func.sh:92`, gap from cnf
  `env.box.health.max_gap_s` (120 s).
- A beat that succeeds leaves no record: only a failure logs `BEAT ... no
  ack` (:1802); `wd/beat.ack` keeps the last ack only (:1796).
- **Cause: not known.** Nothing on the box can say which tick step ate the
  2 minutes. Row 07 adds that record; the fix follows the measurement.
- Out of scope: the self-contradicting bench text ("33 beats in 10m < 30",
  `spl-box-health.func.sh:100`) is SPL-1998 (wip), not this round.

### 2.6 B3 disk WARN re-fires at the 85 % line (SPL-3198)

- `csi-spl-orc/src/bash/scripts/check-disk-headroom.sh` (wrapper
  `csi-spl-orc/src/bash/run/check-disk-headroom.func.sh`). Limits
  `SPL_BOX_DISK_HIGH_PCT=85`, `SPL_BOX_DISK_CRIT_PCT=92`
  (`csi-spl-orc/lib/bash/funcs/spl-box-disk.func.sh:29-30`).
- `note` (:109-120) sends only for a key not in the last state (:113). A
  key enters `now[]` only at or above the limit (:146-154), and the state
  file is rewritten from `now[]` (:158-160), so 85 -> 84 -> 85 % is two
  notes.
- **Cause:** no hysteresis: the key re-arms the first time the mount reads
  1 point under the limit.

---

## 3. The 8 rows

| # | problem, issue | fix (policy vs code) | files (only these) | red control (fails on `74c87e0dd`) | vendor, kind, reviewer | batch |
|---|---|---|---|---|---|---|
| 01 `ar1-01-iac-at-max-cpu` | G1, SPL-3193 | **Alert policy (terraform 070).** Per Q1 (recommended A): add a second condition to `instances_at_max`, CPU `run.googleapis.com/container/cpu/utilizations` p99 per revision `>` cnf `instances_at_max_cpu_p99` (proposed 0.6) for the same duration, and `combiner = "AND"`. Owner go per apply, dev then prd. | `csi-spl-iac/src/terraform/070-gcp-monitoring/05-policies.tf` (:188-217 only), `.../02-variables.tf` (one variable + validation), `csi-spl-cnf/csi-spl/all.env.yaml` (one key beside :317), the rendered `csi-spl-cnf/csi-spl/{dev,prd}/tf/070-gcp-monitoring.vars.tfvars`, `csi-spl-iac/src/bash/tests/monitoring-capacity-070.tst.sh`, doc `csi-spl-doc/doc/md/hub-capacity-alerts.md` | New case in `monitoring-capacity-070.tst.sh`: the `instances_at_max` resource has `combiner = "AND"` and a `cpu/utilizations` condition whose threshold is the variable. Today `grep -c 'combiner *= "AND"' 05-policies.tf` -> 0, so the case FAILs. Control: the existing "GT max" and "no channels" cases (:58-63) stay green. Plus `ENV=<env> ./run -a do_tpl_gen` then `git diff --exit-code`. | claude, simple_coding, agy (else mistral) | 1 |
| 02 `ar1-02-api-relay-log-once` | G2, SPL-3194 (hub part) | **Code fix.** A relay-loop call site that keeps failing logs its first failure at ERROR, the repeats at WARN while it keeps failing, and one INFO when it recovers. | `csi-spl-api/src/go/spool-hub-api/internal/hub/relay.go` (:129, :209, :231, :254), `.../internal/hub/commit.go` (:59), `.../internal/hub/live_ack.go` (:68), one new helper file `.../internal/hub/loop_log.go`, `.../internal/hub/relay_test.go` | New case in `relay_test.go`: a store that fails every call, 12 relay ticks, zerolog captured to a buffer (the pattern of `channels_test.go:121-139`); count `"level":"error"` lines per message. Today 12 per site, so a "<= 1 per site" assertion FAILs. Control: a store that fails once then recovers logs 1 ERROR and 1 INFO. `go test ./internal/hub/...` green. Docs: none (log level of a failing loop; row 03's doc names it). | claude, simple_coding, agy (else mistral) | 1 |
| 03 `ar1-03-iac-apply-snooze` | G2, SPL-3194 (apply part) | **Per Q2.** (A, recommended) a named action `do_gcp_alert_snooze` (new `csi-spl-iac/src/bash/run/gcp-alert-snooze.func.sh`, `--account` pinned SA, dry run unless `DRY_RUN=0`) that `make do-provision` calls for `STEP=040-cloud-sql-postgres` before the apply: one snooze over `error_logs` and `sql_down` for the apply + 15 min, ended after it. No terraform change; the snooze is created only inside an apply the owner already approved. Whether the SA may create snoozes (`monitoring.snoozes.create`) is unchecked: a missing permission is reported, never worked around with the owner account. (B) the policy instead needs the rate for 600 s (`duration`), a terraform 070 change in `05-policies.tf` + `all.env.yaml`: then this row moves to batch 2, after row 01. | (A) new `csi-spl-iac/src/bash/run/gcp-alert-snooze.func.sh`, new `csi-spl-iac/src/bash/tests/gcp-alert-snooze.tst.sh`, `csi-spl-orc/src/make/tf-tasks.func.mk` (the `case` at :82-88), new doc `csi-spl-doc/doc/md/planned-apply-alert-snooze.md` | (A) `gcp-alert-snooze.tst.sh` with a stub `gcloud` on `PATH`: a `make -n do-provision ENV=dev STEP=040-cloud-sql-postgres` plan names `do_gcp_alert_snooze` before the apply. Today `grep -c snooze csi-spl-orc/src/make/tf-tasks.func.mk` -> 0, so it FAILs. Controls: `STEP=070-gcp-monitoring` names no snooze; `DRY_RUN` unset calls no `gcloud ... create` (stub log empty). | claude, simple_coding, agy (else mistral) | 1 (A), 2 (B) |
| 04 `ar1-04-api-task-id-400` | G3, SPL-3195 | **Code fix.** The hub refuses a non-uuid `task_id` or `msg_id` with 400 `bad_json` before any store call: an exported `msg.IsUUID` beside `uuidRe`, called in the box send path (`ws.go`, after `env.Inner()` at :617-621) and the WUI send path (`wui.go` at the `bad_json` answer, :700-701). `boxLevel` treats a non-uuid task id as "no channel" without an ERROR line. `msg.Validate` stays as is (local sends). | `csi-spl-api/src/go/spool-hub-api/internal/msg/msg.go` (helper only), `.../internal/msg/msg_test.go`, `.../internal/hub/ws.go`, `.../internal/hub/wui.go`, `.../internal/hub/channels.go` (:143-146), `.../internal/hub/channels_test.go`, doc `csi-spl-doc/specs/003-spool-message-bus/contracts/error-envelope.md` | New case in `channels_test.go`: a box send with `TaskID: "dispatch-832da496"` must fail with `bad_json`. Today the Memory store takes it (`internal/store/memory.go` does not type-check), the send succeeds, so the case FAILs. Second case in `msg_test.go`: `msg.IsUUID("dispatch-832da496") == false`, `IsUUID(sample().TaskID) == true` (FAILs today: no such function). Control: a uuid task id still sends. Re-run `go test ./internal/hub/... ./internal/msg/...`; fixtures that use `task_id:"t"` through the box send path get real uuids, nothing else. | claude, simple_coding, agy (else mistral) | 1 |
| 05 `ar1-05-orc-bench-hub-stall` | B1, SPL-3196 (bench + NO-LOCAL) | **Code fix.** A common-mode gate in `spl_fleet_bench_tick` and `spl_fleet_nolocal`: when every judged box is degraded with overlapping last-beat gaps, or `$LEASE_DIR/wd/held` exists, or `spl_wd_hub_reachable` fails, the tick records one `fleet.hub-stall` state (start time) and posts no bench, back or NO-LOCAL line. When the hub answers again it posts one line, `Hub stall <start>..<end>: box alerts held` (the GCP policies already paged the stall). One box degraded alone is benched as today. | `csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh` (:1336-1412, :2145-2165), `csi-spl-orc/src/bash/tests/fleet-lease.tst.sh` (sections 25-26 incl. :1037-1044, 30), doc `csi-spl-doc/doc/md/PRINCIPLES-role-failover.md` | New section in `fleet-lease.tst.sh`: two boxes beat every 10 s, both stop for 180 s at the same time, then resume. Assert 0 bench posts, 0 "could not be delivered" lines, 0 NO-LOCAL-AGENT and exactly 1 "Hub stall" line. Today: one bench record per box, then the back line with the suffix, so it FAILs. Control: only one box stops: it is still benched and back as today. The :1037-1044 case changes to the new expectation, in the same commit. | claude, complex_coding, agy (else mistral) | 1 |
| 06 `ar1-06-orc-orch-alert-hub-stall` | B1, SPL-3196 (no live orchestrator) | **Code fix.** `spl_asks_orch_alert` holds the "no live orchestrator" ALERT while row 05's `fleet.hub-stall` state is set, and re-judges from the next renewal after it clears. | `csi-spl-orc/src/bash/run/spl-asks-tick.func.sh` (:359-374), `csi-spl-orc/src/bash/tests/asks.tst.sh` (beside :595-626) | New case in `asks.tst.sh`: `fleet.orch.age` older than `ASKS_ORCH_STALE` (600 s) AND a `fleet.hub-stall` file -> no ALERT. Today the function never reads that file, so it alerts and the case FAILs. Control: the same age with no stall file still alerts (the existing R2 case). Docs: none (row 05's doc section covers both). | claude, simple_coding, agy (else mistral) | 2 (reads row 05's state) |
| 07 `ar1-07-orc-beat-log` | B2, SPL-3197 (measure first) | **Code fix, diagnostic only.** Each beat appends one line `BEAT <inst> tick=<tick start> sent=<call start> ack=<call end or none> ms=<call ms>` to `$WD_DIR/beat.log` (kept to the last 2000 lines), plus the tick's step times when a tick runs past `WD_TICK`. No change to when or how the beat is sent. | `csi-spl-orc/src/bash/run/spl-watchdog.func.sh` (:186-198, :1791-1806), `csi-spl-orc/src/bash/tests/wd-fence.tst.sh`, new doc `csi-spl-doc/doc/md/box-beat-gaps.md` (what the log holds, how to read a gap) | New case in `wd-fence.tst.sh` (it already stubs `WD_BEAT_CMD`, :91) with a stub that answers `{"ok":true}` after a 2 s sleep: after 2 ticks `beat.log` has 2 lines with `ack=` and `ms=` >= 2000. Today no file is written (a successful beat leaves no record, :1795-1800), so it FAILs. Control: a stub with no answer writes `ack=none` and the existing `BEAT ... no ack` line in `wd.log`. | claude, simple_coding, agy (else mistral) | 1 |
| 08 `ar1-08-orc-disk-rearm` | B3, SPL-3198 | **Code fix.** Hysteresis: a key that is in the last state stays armed (no new note, no CLEAR) while the mount is at or above `limit - DISK_HEADROOM_REARM_PCT` (default 5: the WARN re-arms below 80 %, the CRITICAL below 87 %). | `csi-spl-orc/src/bash/scripts/check-disk-headroom.sh` (:109-160), `csi-spl-orc/src/bash/tests/check-disk-headroom.tst.sh` (after :89), doc `csi-spl-doc/doc/md/guides/incident-runbook.md` (the disk line) | New case after :89: `rows 85%` (sends), then `rows 84%`, then `rows 85%`: the send count rises by 1. Today it rises by 2 (the 84 % tick drops the key), so it FAILs. Controls: the existing 50 % -> 91 % re-cross (:82-89) still sends again; 79 % then 85 % sends again. | claude, simple_coding, agy (else mistral) | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** rows 01, 02, 03 (A), 04, 05, 07, 08. No path is in two rows:
  01 is step 070 + the 070 cnf; 02 is `relay.go`, `commit.go`,
  `live_ack.go`, `relay_test.go` + a new file; 03 is a new action, its test
  and `tf-tasks.func.mk`; 04 is `msg.go`, `msg_test.go`, `ws.go`, `wui.go`,
  `channels.go`, `channels_test.go`; 05 is `spl-dispatch-lease.func.sh` +
  `fleet-lease.tst.sh`; 07 is `spl-watchdog.func.sh` + `wd-fence.tst.sh`
  (row 05 calls `spl_wd_hub_reachable`, it does not edit that file); 08 is
  the disk check + its test. Each doc file is in one row only.
- **Batch 2:** row 06 (after row 05 lands: it reads row 05's state file),
  and row 03 if Q2 is (B) (after row 01: both edit `05-policies.tf` and
  `all.env.yaml`).
- `lane-map.sh --check` on 10 of the code paths (`05-policies.tf`,
  `tf-apply.func.sh`, `ws.go`, `relay.go`, `spl-dispatch-lease.func.sh`,
  `spl-asks-tick.func.sh`, `spl-box-health.func.sh`, `spl-watchdog.func.sh`,
  `check-disk-headroom.sh`, `all.env.yaml`) `--agent c-122` -> exit 3, one
  overlap: `csi-spl-cnf/csi-spl/all.env.yaml owned by c-999@sat
  (c-999-c002-spl1945-secret-default-limits)`. Row 01 rebases onto c-999's
  landing, or waits for it; the orchestrator re-runs R3 before each spawn.

---

## 4. Owner questions

Two rows change what pages the owner. Each is one form, for the dispatcher to
relay; nothing waits on them except the row they name. Each block passes
`pollProblems` (`csi-spl-wui/src/utils/poll.mjs`) with no problem.

**Q1 (row 01, G1).** The "hub at max instances" alert paged 7 times since it
went live on 10-21, each time on an idle hub (CPU p99 <= 0.06 in the measured
episode).

```poll
When should "hub at max instances" page you?
(A) Only when the hub is at max AND busy (CPU p99 above 0.6) for an hour
(B) Keep the rule, but only after 4 hours at max (it would not have paged last week)
(C) Keep it as it is, but by email only, no SMS
```

**Q2 (row 03, G2).** A planned database apply you approved paged the "hub
error log rate" alert 3 times in 14 days (10-18, 10-22 dev, 10-22 prd).

```poll
How should a database apply you approved stop paging you?
(A) The apply action mutes the error-log and database-down alerts for the apply plus 15 min
(B) The error-log alert pages only when errors last 10 minutes, for every cause
(C) Both
```

---

## 5. After the round (not rows)

- **B2 follow-up:** once row 07 has run on box-2 for 24 h, a read-only lane
  pinned to box-2 reads `beat.log` at each bench minute and names the step
  that ate the gap, in `box-beat-gaps.md`. The fix is an input row for the
  next round.
- SPL-1998 (the bench text) stays with its own issue.
- The triage's out-of-scope note (`do_gcp_tail_logs` needs `GCP_SA_KEY_FILE`)
  is not a row of this round.

---

## 6. Consensus

| seat | vendor | sha signed | verdict |
|---|---|---|---|
| c-122@sat (editor) | claude | v0.1 | author |
| a-132@sat (reviewer) | agy | 8074eae15 | PASS |
