# Bug round 18 (b18): mistral panel seat (m-557)

Seat: m-557, placement `c002-bug-round-18-mistral-panel-seat` (mistral; docs and
reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/dispatch/briefs/c002-bug-round-18-mistral-panel-seat.md`
(Issue SPL-5900, Epic SPL-2402, Spec `csi-spl-doc/specs/157-dispatch-automation`,
class bug, kind specs_and_docs, topic `da398927-00f9-45c7-8337-0c7ff5431647`).

Review target: plan v0.1 `bc559b2f6851ab04b6871676ed4bb469470d5260`, named in the
brief. Provenance: `git ls-remote origin | grep bug-round-18` ->
`bc559b2f6851ab04b6871676ed4bb469470d5260  refs/heads/review/c002-bug-round-18-planner`;
`git merge-base --is-ancestor bc559b2f6851ab04b6871676ed4bb469470d5260 origin/master`
-> exit 0 (on trunk); `git show bc559b2f6 --stat` -> 1 file, +131,
`csi-spl-doc/doc/md/bug-round-18-plan.md` (131 lines, read in full at that sha).
origin/master at my read: `b9b22d2f9` (moved past the plan sha during the read, N1).
No later plan version was named to me (inbox empty at 2026-11-18T17:00Z:
`SPOOL_ROOT=/var/spool-hub spool recv --as m-557` -> `[]`), so I sign v0.1.
Plan v1.0 `232902108` was named by the editor c-871@<box2> at 2026-11-18T17:25:50Z
(msg 0b34404e, task dispatch-bug-r18); it is signed in the last section.

## Verdict

**PASS on `bc559b2f6851ab04b6871676ed4bb469470d5260`** (plan v0.1, 0 rows: nothing
live, unowned and red-controllable on `8de1d37b1`). Defects W1..: none. Notes
N1..N7 below.

## Checks (each with the command run and what it printed, 2026-11-18 16:2x-17:0xZ)

### 1. Slug b18 unused

- `git log origin/master --oneline -E --grep='\(b18-' | wc -l` -> `1`; the hit is
  `bc559b2f6 docs(b18-plan, SPL-5900): ...` — the plan's own version commit (scope
  `b18-plan`), exactly what the plan's own slug bullet predicts.
- `git log origin/master -E --grep='\bb18-[0-9]{2}-' | wc -l` -> `0` (no row slug).
- `git ls-remote origin | grep -cE 'b18-[0-9]{2}'` -> `0`;
  `git ls-remote origin | grep bug-round-18` -> one line, the planner's
  `review/c002-bug-round-18-planner` at `bc559b2f6` (expected).
- `grep -rlE '(^|[^0-9a-f])b18-[0-9]{2}-' /var/spool-hub/dispatch/briefs /var/spool-hub/asks /var/spool-hub/spawn-remote/briefs | wc -l`
  -> `0`; `grep -rl 'bug-round-18'` over the same dirs -> 5 files (the planner's
  brief, this seat's brief, two ask jsons, `.place.slugs`; no row slug).
- `git branch -a | grep -cE 'b18-[0-9]{2}'` -> `0`.

### 2. The plan's five sources re-run

- **CI (source 2):** `cd csi-spl-iac && sudo -u <DEV_USER> env CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate`
  -> `== 10_ci-quality.yml on master -- last 100 run(s), 2026-11-17T23:45:19Z .. 2026-11-18T16:01:26Z: 55 success, 35 cancelled, 10 failure`;
  every timeout-headroom line `ok` (highest p90 56 %); per-job red table:
  `orc 3/4` red 5 (1 stopped, 2 repeat), `orc 1/4` red 4 (1 repeat), hub / 2/4 / 4/4
  stopped only. Last green per failed job: 1/4 and 4/4 on `44342341521 bc559b2f
  2026-11-18T16:01:26Z` (the r62-01 fix `4ca86a9c3` is inside the plan sha, so 1/4 is
  green on it); 3/4 last green `44330856293 897e67e1 15:01:48Z`.
  Signatures: (a) `orc 3/4 FAIL: 11. no hook after spl_spawn_placed_close` on runs
  44284888667, 44287478217, 44288340441, 44289475051 (10:23Z..10:52Z) — green since,
  as the plan says; (b) `orc 1/4 FAIL: 1. real manifest (rc 0: PLAN cron: ...)` on
  44329803276 (`b36b20577`), 44330856293 (`897e67e13`), 44335971661 (`04772cfe5`),
  44338309387 and 44339312435 (both `8de1d37b`) — the r62-01 red, owned (SPL-5898,
  now done), green on `bc559b2f6`; (c) new since the plan's window closed:
  `orc 3/4 FAIL: 2 noon differs from origin/master` on 44338309387 (`8de1d37b`) and
  44342341521 (`bc559b2f`) — see N2.
  `gh run list --workflow 10_ci-quality.yml --branch master -L 15` -> newest first:
  44342341521 failure on `bc559b2f6` (the plan's own push), 44341219662 cancelled
  (`4ca86a9c3`), 44340607063 cancelled, 44339312435 failure (`8de1d37b`),
  44338309387 failure (`8de1d37b`), 44335971661 failure (`04772cfe5`),
  44330856293 failure (`897e67e13`), 44329803276 failure (`b36b20577`), then
  successes; 44322111931 success on `e1c6f870e` (b17-01's quality gate, as the plan
  says).
  Cited runs, `gh run view <id> --json databaseId,headSha,conclusion,startedAt`:
  44287478217 / 44288340441 / 44289475051 -> failure, 10:39:34Z / 10:45:09Z /
  10:52:34Z; 44330856293 -> failure on `897e67e13`, 15:01:48Z; 44329803276 ->
  failure on `b36b20577`, 14:56:16Z; 44335971661 -> failure on `04772cfe5`,
  15:28:08Z, and `gh api .../actions/jobs/134918724305` -> run 44335971661,
  `orc: hermetic action tests ... 1/4`, failure; 44322111931 -> success on
  `e1c6f870e`; 44292290079 -> success, headSha `07102fb7ea4155d8e571256489e47e3eed9dd4f4`,
  workflow `30 ci-cd: spool WUI build + deploy`, 11:10:46Z..11:20:45Z (the 11:17:20Z
  burst sits inside it — N4); 40329116513 -> success, 2026-10-26T13:16:10Z..13:24:57Z;
  44098957255 -> success, started 2026-11-17T14:03:21Z (ended 14:16:21Z).
- **Skips (source 3):** `for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$d: "; git grep -n -E "(t\.Skip|test\.skip|\.skip\(|ci-skip\.txt)" 8de1d37b1 -- "$d" | wc -l; done`
  -> `csi-spl-api: 199, csi-spl-wui: 18, csi-spl-orc: 10, csi-spl-iac: 21, csi-spl-utl: 0`
  — exactly the plan's counts, identical on origin/master;
  `git diff 43d8e1325 8de1d37b1 -G '(t\.Skip|test\.skip|\.skip\(|ci-skip\.txt)' --stat`
  -> only `csi-spl-wui/tests/unit/e2e-shard-pack.test.mjs` (+23/-3), the p17-01 commit
  `b97a764ff` — as the plan says.
- **Cron logs (source 4, this box):** 39 `/var/csi/.../cron.{out,log}` files changed
  in the last 24 h; the plan's awk (error pattern, keyed by the last ISO timestamp
  above each line, `spool-env` WARN lines skipped, only lines whose timestamp >=
  2026-11-17T16:56Z) -> **0 lines**. This box's crons are clean in the window. The
  plan read <box2>'s logs, not re-readable from here; its fixed items check out in
  git: `git merge-base --is-ancestor 0a5a8fbb3 origin/master` -> yes (b14-02 landed),
  and `git show 8de1d37b1:csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh | grep -n cmdline`
  -> `:612` reads `... < "$root/$d/cmdline" 2>/dev/null || true` — guarded as the
  plan says.
- **Owner/member posts (source 1):** the plan's count query re-run on prd ->
  `t1 84 (36 [spool-probe], 12 regex hits), csitea 70 (1 hit), three other
  workspaces 7 (0 hits each; their names are hidden-workspace literals, withheld
  per the hygiene sweep)` (counts moved with the posts since 16:00Z; the
  plan read t1 65 / csitea 67 / others 7). The 12 t1 regex hits read whole
  (`select msg_id, ts, left(body,110) from messages where tenant_id='t1' and ts >
  '2026-11-18T10:10:38Z' and from_id like 'HUM%' and body ~* '<pattern>' and body not
  like '[spool-probe]%'`): poll answers and the event-log / menu-kind feature
  requests (SPL-5882 etc.) — none a defect report.
- **WUI error log (source 5):** `select date_trunc('minute', received_at), human_id, count(*), left(min(message),100) from human_events where kind='error' and source='vue' and received_at > now() - interval '30 days' and (message like '%emitsOptions%' or message like '%insertBefore%') group by 1,2 order by 1 desc limit 10`
  -> `2026-11-18 11:17Z HUM-10 23` (emitsOptions / insertBefore), `2026-11-17 14:47Z
  HUM-10 12`, `2026-10-27 08:01..08:03Z HUM-23 45+14+8`, `2026-10-26 13:21Z HUM-23 15`
  — the F9 family as the plan describes (22 + 1 at 11:17:20Z).
- **Issues:** `select number, status, priority, left(title,55) from issues where tenant_id='t1' and number in (5751,5847,5874,5880,5882,5896,5897,5898,5900,5903,5904,5905)`
  -> SPL-5896 done, SPL-5880 done (the plan's claim), SPL-5898 done, SPL-5900 wip,
  SPL-5903 onhold, SPL-5904 done, SPL-5905 wip, SPL-5874 done, SPL-5897 wip,
  SPL-5751 todo, SPL-5847 wip, SPL-5882 wip — as the plan's section 6 reads them.
  Open t1 issues overall: 91.
- **Holder's candidate list:** `ls -la /var/spool-hub/dispatch/c002-next-round-candidates.md`
  -> 2967 bytes, mtime Nov 18 03:57 — as the plan says.
- **r62 off-limits paths:** `git cat-file -e origin/master:<f>` -> all 5 exist
  (`install-box-crons.func.sh`, `spl-box-state-backup.func.sh`,
  `external-api-health.func.sh`, `spl-spawn-place.func.sh`,
  `no-literal-paths.baseline`).
- **Spawn queue:** `sudo -u <HARNESS_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue`
  -> `10 queued, 0 placing`; none names this plan or a b18 row (1 refactor r62-02,
  2 bug, 7 feature).

### 3. Every cited file:line and sha exists as cited

- Plan sha and measurement sha: `git merge-base --is-ancestor bc559b2f6851ab04b6871676ed4bb469470d5260 origin/master`
  -> 0; `git merge-base --is-ancestor 8de1d37b1 origin/master` -> 0;
  `git log -1 --format='%H %cI' 8de1d37b1` -> `8de1d37b14baa7003f72e783038d0002f66d8776
  2026-11-18T16:31:34+01:00` (= 15:31:34Z, as the plan says).
- Window: `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b17-plan')`
  -> `W=2026-11-18T13:20:28+02:00` — exactly the plan's W.
- b17-01: `git merge-base --is-ancestor e1c6f870e origin/master` -> yes; subject
  `fix(b17-01-orc-box-link-watch-expired-is-no-refusal, SPL-5896): ...`.
- Other cited shas all resolve on origin/master (`git merge-base --is-ancestor <s>
  origin/master` -> 0 each): 897e67e13, b36b20577, 04772cfe5, 43d8e1325, b97a764ff,
  61bdcbd1c, ce765392c, 02386fae6, 6de08753e, 0a5a8fbb3. `07102fb7e` is NOT an
  ancestor — it is the pre-rewrite sha of p17-01 (rewritten as `b97a764ff` at
  2026-11-18T11:15:59Z); `gh run view 44292290079` confirms headSha
  `07102fb7ea415...`, so the plan cites that run's head correctly (N4).
- `csi-spl-wui/src/components/LiveFeed.vue` (510 lines): `:47` ->
  `<template v-for="it in drawnItems" :key="it.key">`; `:304` ->
  `const shown = computed(() => ... props.rows.filter((m) => !pendingDeleteId.value || ...))`
  (no dedupe); `:353-366` -> `const feedRows = computed<FeedItem[]>(() => { ...
  const card: FeedItem = { key: String(m.msg_id), msg: m, i } ... })` — all as the
  plan cites.
- `box-link-watch.py` at 8de1d37b1: `:4-5` relay docstring, `:74` ->
  `EXPIRED = re.compile(r"\bexpired\b.*\bnothing ran\b")`, `:151` / `:216` the
  EXPIRED guard lines — as cited.
- `grep -n LOGIN_STATE_DIR csi-spl-orc/src/bash/run/spl-watchdog.func.sh` -> `:72`
  (param) and `:1318` (`dir="$(spl_claude_login_state_dir)"`);
  `grep -n '/var/' csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh` -> no line.
  `git log origin/master --grep='(b14-01'` -> `ce765392c`;
  `git show 61bdcbd1c --stat` -> touches `spl-watchdog.func.sh` and
  `spl-lane-rotate.func.sh` (the r61-02 fix);
  `git diff --stat 43d8e1325 8de1d37b1 -- <the holder-list files>` -> only those two
  files changed (the section-4 fixes); the tf-* files and `tf-log-mask.func.sh`
  unchanged.
- No cited line drifted.

### 4. The watch item (plan section 5, the F9 Vue crash family)

Read the cited code and the stores that feed it:

- `LiveFeed.vue:47` keys each rendered row by `it.key`; `feedRows` (`:353-366`)
  sets `key: String(m.msg_id)` (`:363`); `shown` (`:304`) filters only
  `pendingDeleteId` — it does not dedupe, as the plan says.
- But every path into `props.rows` dedupes by msg_id first: `mergeById`
  (`csi-spl-wui/src/utils/feed.mjs:39-62`, "any other duplicate is dropped", a Map
  keyed by msg_id) is used by `rowsForRightPane` (`csi-spl-wui/src/utils/channel-feed.mjs:317-329`,
  the non-mock path of TopicPane's `paneRows`, `TopicPane.vue:122-123`), by the live
  store (`csi-spl-wui/src/stores/live.ts:96`), and the channel feed dedupes incoming
  rows with a `seen` Set (`csi-spl-wui/src/stores/channel.ts:306-307`) and merges
  pages by msg_id (`:384`).
- So two rows with one msg_id cannot reach LiveFeed through the stores today; a unit
  test that feeds LiveFeed a duplicate msg_id would fail on an input the stores
  cannot produce, not on a live defect. **No red control is possible today; the
  watch item stands and 0 rows is right on this point.** The crash family's real
  trigger remains unproven, as the plan says.

### 5. R3 (lane-map)

- `bash .../lane-map.sh --check csi-spl-orc/src/bash/tests/spl-spawn-place-supply.tst.sh,csi-spl-orc/src/bash/run/spl-spawn-place.func.sh --agent m-557`
  -> exit 4: no live lane lists them, 16 unknown no-file lanes (box qualifiers
  dropped per the hygiene sweep). No row proposed, so R3 does not block; exit 4 is
  not free (N3).
- `lane-map.sh --check csi-spl-doc/doc/md/bug-round-18/seat-mistral.md --agent m-557`
  -> exit 4 (14 unknown lanes); the file is new, no lane can list it yet.

### 6. Distribution hygiene

- `cd csi-spl-iac && sudo -u <DEV_USER> ./run -a do_check_dist_hygiene` ->
  `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-557`,
  exit 0. First run on this file (while still untracked it was not swept) flagged
  its own lines once tracked: the `sudo -u <user>` OS-user literal (3 lines) and
  the hidden-workspace names in the source-1 counts (2 lines); reworded to the
  plan's `<DEV_USER>` / "three other workspaces" convention, re-run: clean, exit 0.

## Defects

None. W1..: none.

## Notes

- **N1:** origin/master moved past the plan sha during my read: `bc559b2f6` ->
  `454edf844` (SPL-5904, wui) -> `b9b22d2f9` (`test(orc, SPL-5897)`, landed
  2026-11-18T16:48:05Z). The plan sha is still an ancestor and the plan file is
  unchanged since v0.1 (`git diff bc559b2f6 origin/master --
  csi-spl-doc/doc/md/bug-round-18-plan.md` -> empty).
- **N2:** the plan's CI window closed at 15:45:31Z with 3 runs still running; two of
  those completed after and show a third signature the plan did not list:
  `orc 3/4 FAIL: 2 noon differs from origin/master` on 44338309387 (`8de1d37b`) and
  44342341521 (`bc559b2f`). Reproduced: `bash csi-spl-orc/src/bash/tests/spl-spawn-place-supply.tst.sh`
  on a clone at `8de1d37b1` -> `FAIL: 2 noon differs from origin/master ... | master `
  (empty), rc 1; on this worktree at `bc559b2f6` -> same, 1 failure; on origin/master
  `b9b22d2f9` -> `all passed`. Mechanism: since `6de08753e` (SPL-5897, landed
  15:08:48Z) the placer sources `spl-spawn-after.func.sh` next to itself and calls
  `spl_spawn_after_unheld`; the test's case 2 copied only the placer into a temp dir,
  so the master side sent nothing. It is owned, not a row: `6de08753e` is the
  SPL-5874 follow-up lane's own commit (its body names R7 c-434 of SPL-5874; the
  plan's section 6 lists that follow-up, ask 1801656f, as owned and left out),
  SPL-5897 is wip, and the follow-up fixed it in `b9b22d2f9` (body: "Red on
  8de1d37b1: rc 1, FAIL: 2 ... Green on this tree: rc 0, 14 PASS"; "Refs: SPL-5874
  ... dispatch-spl5874-followup"). So on `8de1d37b1` the candidate was live and
  red-controllable but owned (R3) — 0 rows stands.
- **N3:** lane-map exits 4 (unknown no-file lanes) on every path checked, as in round
  17 and p18; no live lane lists any of them. Exit 4 is not free; no row was
  proposed, and this seat file is new.
- **N4:** `07102fb7e` (the prd WUI release the plan ties the 11:17:20Z burst to) is
  the pre-rewrite sha of p17-01; on master it is `b97a764ff`. `gh run view
  44292290079 --json headSha,conclusion` -> headSha
  `07102fb7ea4155d8e571256489e47e3eed9dd4f4`, success — the plan cites the run's head
  correctly.
- **N5:** source-1 counts moved with the posts after 16:00Z (t1 65->84, csitea
  67->70); the 12 t1 regex hits were read whole and are process/feature posts, none
  a defect.
- **N6:** this box's cron logs are clean in the last 24 h (39 files, 0 error lines);
  the plan's source-4 readings are from <box2>, not re-readable from here; its fixed
  items verify in git (b14-02 `0a5a8fbb3` is an ancestor; lane-rotate's cmdline read
  is guarded at `:612`).
- **N7:** in the plan's table cells the alternation prints as `\|` (the markdown
  escape); run literally it returns 0 counts. The plan says "type a plain `|`" under
  the table — documented, not a defect (same as b17's N3).

## v1.0 signature (2026-11-18 17:3xZ, this session)

The editor c-871@<box2> named plan v1.0 `232902108` (msg 0b34404e,
2026-11-18T17:25:50Z, task dispatch-bug-r18). Checks run by this session:

- `git rev-parse 232902108` -> `232902108ef40a1444957fb364f39752db96cf5d`;
  `git log -1 --format='%H %s' 232902108` -> `docs(b18-plan, SPL-5900): bug round 18
  plan v1.0, panel m-557 mistral PASS on v0.1 bc559b2f6, 0 rows unchanged`.
- `git merge-base --is-ancestor 232902108 origin/master` -> exit 0;
  `git branch -r --contains 232902108` -> `origin/master`,
  `origin/review/c002-bug-round-18-planner`.
- `git show 232902108 --stat` -> 1 file, +5/-3, `csi-spl-doc/doc/md/bug-round-18-plan.md`
  (133 lines at the sha).
- `git diff bc559b2f6 232902108 -- csi-spl-doc/doc/md/bug-round-18-plan.md` -> only the
  status line, section 8 (review history; folds this seat's PASS and N1..N7) and
  section 9 (consensus table). Section 3 rows unchanged.
- `git show 232902108:csi-spl-doc/doc/md/bug-round-18-plan.md | grep -cE 'b18-[0-9]{2}-'`
  -> `0`; line 1 -> `# Bug-fix round 18 - plan (0 rows)`; line 13 ->
  `**Status: v1.0**, panel PASS (m-557@sat, mistral, on v0.1 bc559b2f6); rows unchanged.`

**Verdict on v1.0 `232902108ef40a1444957fb364f39752db96cf5d`: PASS** — 0 rows stands;
the v1.0 delta touches no measurement, only status, review history and consensus.
W1..: none on v1.0 either.
