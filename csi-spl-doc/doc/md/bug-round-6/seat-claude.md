# Bug round 6: reviewer seat verdict (claude, c-887)

Plan: `csi-spl-doc/doc/md/bug-round-6-plan.md` v0.1, rows from `b10a41180`, measured on
`50743edbb`; read at `b10a41180` and the later diff to `6f464849e` (status and reviewer lines only, no row change).
Seat: c-887 (claude), review only. **same-vendor exception owner msg db9963e2**
(the editor is claude too; mistral spent its 2 tries, grok and agy have no quota).
Session log: `~<HARNESS_USER>/.claude/projects/-opt-csi-csi-spl-wt-c-887/0c177e91-dcf1-4213-b87e-9216dc9e8ea9.jsonl` on `<box>`.
Every rc below was printed with `echo rc=$?` in that session; n=1 per command unless stated.

## 1. Verdicts

| item | verdict |
|---|---|
| Row 01 `b06-01-orc-dispatch-lag-grace` | **agree with changes** (60 is sound; 4 text changes, none blocks the lane) |
| (b) placer note to the sender only | **agree**: by design, not a row |
| (c) self-sent QUEUE task | **agree**: not reproduced |
| (d) fresh desk seat 401 | **not re-checked by this seat** (the brief asks for (b) and one of (c)/(d)); I take the plan's "not reproduced" as stated, unchecked |

## 2. Row 01

### 2.1 Start state

`git rev-parse HEAD origin/master` -> `7fea63f1d264c2a12362820e497a739f155da89b` twice, rc 0; `git status --short` -> empty, rc 0.

### 2.2 Red controls (plan 3.2), re-run

Scratch dir under /tmp, `git archive 50743edbb csi-spl-orc/src/bash/run/spl-dispatch-deploy-lag.func.sh | tar -x`, both scripts copied from the editor's red-control dir.

| control | output on `50743edbb` | rc | with `:-30` -> `:-60` (sed on the scratch copy) | rc |
|---|---|---|---|---|
| `bash zz-b06-01.sh <func>` | `\| deploy lag dev hub \| current grace=30 \| ok \|`, `FAIL b06-01 default grace is not 60 min (want grace=60)` | 1 | `… current grace=60 \| ok \|`, `PASS b06-01 default grace is 60 min` | 0 |
| `bash zz-b06-01b.sh <func>` | `\| deploy lag dev hub \| age=41m grace=30m \| GAP trunk input not served after 30 min: …`, `gaps=1`, `FAIL b06-01b …` | 1 | `\| deploy lag dev hub \| pending age=41m grace=60m \| ok \|`, `gaps=0`, `PASS b06-01b …` | 0 |

Both controls fail today and pass with the fix (n=1 each). The plan's controls also hold on the fixed copy,
by my own script `ctl.sh`: `DISPATCH_LAG_GRACE=30` with the 41-min probe -> `GAP …`, `gaps=1`; `DISPATCH_LAG_GRACE=45`
-> `| deploy lag dev hub | current grace=45 | ok |`; rc 0.

Baseline suite: `git archive 50743edbb csi-spl-orc` into scratch, `bash csi-spl-orc/src/bash/tests/spl-lane-lifecycle-actions.tst.sh`
-> `ALL PASS`, rc 0 (n=1, as `<HARNESS_USER>`).

### 2.3 Baseline, measured by this seat

`gh run list --workflow 20_hub-build-deploy.yml --status success -L 100 --json headSha,createdAt,updatedAt,event,headBranch`
(rc 0), commit time from `git show -s --format=%ct <sha>`, minutes from commit time to run `updatedAt`, nearest-rank percentiles:

| set | n | window (run created) | p50 | p90 | p95 | max | > 30 | > 45 | > 60 |
|---|---|---|---|---|---|---|---|---|---|
| all green runs | 100 (95 push, 5 workflow_dispatch, all master) | 2026-10-16T09:12Z..2026-10-23T08:20Z | 29.1 | 45.8 | 51.8 | 128.2 | 49 | 14 | 3 |
| push only | 95 | same | 29.0 | 46.0 | 54.5 | 128.2 | 44 | 13 | 3 |

The 4 runs over 55 min: `6b02b7ac2` 63.5 (run 57.4), `e84ba03aa` 59.8, `5e7537547` 110.0 (run 91.0), `c89143908` 128.2 (92.2 before the run started).
Last 100 runs of workflow 20, any state: 90 success, 8 cancelled, 2 failure.

### 2.4 Sites, printed from `50743edbb`

- `git show 50743edbb:csi-spl-orc/src/bash/run/spl-dispatch-deploy-lag.func.sh | sed -n '1,75p'` (rc 0):
  `:6` `# @description DISPATCH_LAG_GRACE minutes (30) and is still not live is a GAP`;
  `:20` `# @param DISPATCH_LAG_GRACE (optional) - minutes, default 30`;
  `:40` `  local grace="${DISPATCH_LAG_GRACE:-30}" sha e out line comp verdict rest app state_root`;
  `:10-12` `… Built for the` / `2026-10-01 case: both hubs served one commit for ~50 min while` / `every 20 run stood down, and nobody was told.`
- `git show 50743edbb:csi-spl-orc/src/bash/run/check-deploy-lag.func.sh | sed -n '32,35p;61p'` (rc 0): `:32-35` the "a normal pipeline (build, deploy, propagate) is never reported as lag" rule; `:61` `  local grace="${GRACE_MINUTES:-45}"`.
- `git show 50743edbb:csi-spl-orc/src/bash/run/spl-dispatch-check.func.sh | sed -n '38,42p'` (rc 0): `:40-41` names `DISPATCH_LAG_GRACE`, no number.
- `git show 50743edbb:csi-spl-orc/src/bash/tests/spl-lane-lifecycle-actions.tst.sh | sed -n '231,236p;277,282p'` (rc 0): `:231` `# 4. do_spl_dispatch_deploy_lag`, `:233` `deploy_lag() {`, `:277-280` the "ENV, SHA and GRACE_MINUTES reach the probe" case with `DISPATCH_LAG_GRACE=45`.
- `git grep -n DISPATCH_LAG_GRACE 50743edbb` (rc 0) -> 5 lines in 3 files: exactly `spl-dispatch-check.func.sh:41`, `spl-dispatch-deploy-lag.func.sh:6,20,40`, `spl-lane-lifecycle-actions.tst.sh:277`. The plan names every one; no other site.
- Escalation: `git grep -n DISPATCH_GAP_ESCALATE 50743edbb -- csi-spl-orc` (rc 0) -> `spl-dispatch-tick.func.sh:35` `default 3600`.

### 2.5 Judgement

One defect (the dispatch rows' default undercuts the probe's own rule at `check-deploy-lag.func.sh:32-35`), one lane, the named sites only, red controls that really fail today. **60 is a sound default**: a stuck deploy stays a GAP until it is served, so it is still noted (at 60 min instead of 30) and escalated (at 120 min instead of 90, grace + 3600 s); 45 would still note 13 of 95 healthy push deploys, 60 notes 3.

Changes I ask the editor to fold (text, not scope):

1. **Say the trade-off in the header.** `:10-12` says the action was built for a ~50 min stuck-deploy case. With 60 a 50-min stall is no GAP. The fix's header line should say that a stall is now noted after 60 min, and why (healthy p95 52..55 min), so the next reader does not "fix" it back.
2. **60 still notes some healthy deploys.** My n=100 has 3 over 60, one of them newer than the plan's window (`6b02b7ac2`, 2026-10-23T08:20Z, 63.5 min). The plan's reason line ("so a lower grace notes healthy deploys") should not imply 60 notes none: about 3 in 100.
3. **Section range.** The plan gives section 4 of the `.tst.sh` as `:231-282`; it runs to `:285` (`grep -n '^# [0-9]\. '` -> section 5 at `:287`). Cosmetic.
4. **Green runs only.** The metric counts green runs; a commit whose own run was cancelled (8 of the last 100) is served by a later run and waits longer. That makes the tail an under-estimate, which argues for 60, not against it. Note only.

## 3. Candidate (b), re-checked

- `spl-spawn-placed.func.sh` `:2-8` (header: "its sender is told on its task") and `:29` (`spl_spawn_q_reply "$row" "$2" "placed: $3"`), `spl-spawn-queue.func.sh:116-134` (`spl_spawn_q_reply` sends to the row's `.from`) and `:142` (`ask_closed` -> `return 3`), all printed from `50743edbb`, rc 0.
- `internal/store/fleet_ask.go:97` (`queue` is `open|acked|queued -> queued`) and `:361-374` (the queue op sets state, `enqueued_at`, placement, class, flag; `FlagBy` only for a flag); `internal/hub/box_ask.go:63-92`: `AskRow` has no enqueuer field (`grep -n -i 'enqueued_by\|EnqueuedBy\|queued_by'` -> rc 1, no line).
- Hub, read only: `ENV=prd SQL="select ts, from_id, to_id, left(body,80) from messages where ts >= '2026-10-23T05:55Z' and ts < '2026-10-23T07:00Z' and (body like '%placed: m-855%' or …)" ./run -a do_spl_db_query` -> 7 rows, rc 0, among them `06:26:30 c-001 -> c-140 placed: m-855` and `06:29:42 c-001 -> c-941 placed: m-856`, and the two `queued, position 3 of 3` notes from c-002 (06:00, 06:01:55). All 4 notes reached their sender (n=4).

Agree: by design; telling the enqueuer too is a feature (a new hub field), not a round-6 row.

## 4. Candidate (c), re-checked

- `grep -nE '6699be06|1b4fb524' /var/spool-hub/asks/journal.log` (rc 0): `05:15:44Z open 6699be06 … c-002`, `05:15:54Z … queued`; `05:23:14Z open 1b4fb524 … c-002`, `05:23:21Z … queued`; each later `acked`, then `done`.
- `git show 50743edbb:csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh | sed -n '432,436p'` (rc 0): `:434` `if [ -n "$_ak" ] && [ -n "$MSGID" ] && [ "$FROM" != "$TO" ]; then`: a self-send journals no ask.

Agree: both took the same path (send, separate put, queue); only the delay before the put differed. Not a queue defect.

## 5. Lane map

`lane-map.sh --check csi-spl-doc/doc/md/bug-round-6/seat-claude.md,csi-spl-doc/doc/md/bug-round-6-plan.md --agent c-887` -> rc 4: no live lane lists either path; 9 lanes record no files (rotation seats, an s150 reviewer, an s151 store lane, c-411, c-423, c-499). None names bug round 6; this file is the one the brief assigns to this seat.
