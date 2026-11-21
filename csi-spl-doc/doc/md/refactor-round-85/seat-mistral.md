# Refactor round 85 — panel seat mistral (m-919@<box>)

Issue: SPL-6197 (epic SPL-2402). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/spawn-remote/briefs/cceac7cb-665b-4abe-94be-5a00420cfd06.md`
(`grep -rlE 'r85-[0-9]{2}|refactor-round-85' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote/briefs`
-> this file and the planner's `d1f9f143-9eee-44b2-8c39-0f3c91218fdf.md`; nothing in
`dispatch/briefs`).

Review target: `csi-spl-doc/doc/md/refactor-round-85-plan.md` on branch
`review/c002-refactor-round-85-planner` at the sha the planner named in its spool note
(msg `63305f3b-15b6-4a0d-b830-7b844dae2eb9`, task `dispatch-refactor-r85`,
2026-11-21T17:00:15Z, from c-918):
**`08c524dd59d0b9d70bbd0d7841c796d0f65a3a88`**.

- `git cat-file -t 08c524dd59d0b9d70bbd0d7841c796d0f65a3a88` -> `commit`;
  `git log -1 --format='%H %cI %s' 08c524dd...` ->
  `08c524dd59d0b9d70bbd0d7841c796d0f65a3a88 2026-11-21T17:58:59+01:00 docs(r85-plan, SPL-6197): refactor round 85 plan v0.1 for the panel: r85-01 one peer cron body, r85-02 one _id_from_ancestry; both heads built and run on 4dd74b366, red controls RED, behaviour probes 24 + 8 cases 0 differ, R3 and R7 checked`.
- `git ls-remote origin | grep -E 'r85-[0-9]{2}|refactor-round-85'` ->
  `08c524dd59d0b9d70bbd0d7841c796d0f65a3a88  refs/heads/review/c002-refactor-round-85-planner`
  (head == the named sha; `git log origin/master..<branch>` -> exactly 2 commits:
  v0.0 `4ed8415cc`, v0.1 `08c524dd`).
- The plan's measured base is `4dd74b366` (plan header). `origin/master` at review time
  is `15eb398c8` (one commit past base: `refactor(r84-02-orc-desk-readers-one-kv, SPL-6196)`);
  `git diff --name-only 4dd74b366 origin/master -- <the 9 row paths>` -> **empty**.
- Every file:line cited below was checked with `git show 4dd74b366:<file> | sed -n <N>p`
  (and the same at `origin/master`; the drift diff above is empty, so they are identical).

**Verdict: PASS on `08c524dd59d0b9d70bbd0d7841c796d0f65a3a88`. No W defects.**

## 1. Slug r85 unused since the plan's W

- `git log origin/master -1 --format=%cI -E --grep='^docs\(r84-plan'` ->
  `2026-11-21T16:01:28+02:00` (commit `c314d1ac1`) — matches the plan's `Window: W=`.
- `git log origin/master --since="2026-11-21T16:01:28+02:00" --oneline -E --grep='\(r85-' | wc -l`
  -> **0**; over all history -> **0**. Control: the same read with `(r84-` -> 5 lines.
- `git ls-remote origin | grep -E 'r85-[0-9]{2}|refactor-round-85'` -> only
  `refs/heads/review/c002-refactor-round-85-planner` (the planner's own; my review branch
  is pushed after this read). Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r85-[0-9]{2}|refactor-round-85'` -> no match;
  content grep over `dispatch/briefs` + `spawn-remote/briefs` -> the planner's brief and mine
  (expected).
- `git ls-tree origin/master csi-spl-doc/doc/md/ --name-only | grep -c refactor-round-85` -> **0**
  (the plain name is free on trunk; the plan lives on the review branch only).

## 2. Every row site file:line exists on base and on origin/master

Row paths (9): `orc:src/bash/scripts/peer-cron.inc.sh` (new), `peer-distill-cron.sh`,
`peer-ensure-cron.sh`, `peer-restart-cron.sh`, `orc:src/bash/tests/peer-restart.tst.sh`,
`orc:src/bash/features/mcp-bot/lib/id-from-ancestry.inc.sh` (new),
`mcp-bot/scripts/mcp-start.sh`, `mcp-start-chrome.sh`,
`mcp-bot/tests/test-id-from-ancestry.sh` (new).

- `wc -l` at `4dd74b366` and at `origin/master` (identical): the three wrappers 53/53/53,
  `peer-restart.tst.sh` 443, `mcp-start.sh` 226, `mcp-start-chrome.sh` 324. The three new
  files do not exist on base/master — expected, the rows create them.
- `git diff --name-only 4dd74b366 origin/master -- <the 9 paths>` -> **empty**: no drift
  (the only commit past base is r84-02's, which touches none of them).
- Cited lines read at base: wrappers `:2-5`, `:10` (header), `:36`, `:42`, `:50`, `:52`
  (name in messages), `:51` (`distill`/`restart`: `( cd "$ORC" && env DRY_RUN=0 ./run -a do_spl_peer_<x> )`;
  `ensure`: `env ./run`, no `DRY_RUN`) — `diff` of distill against ensure and against restart
  shows exactly those hunks and nothing else. `peer-restart.tst.sh:33` (item-11 header),
  `:328` (`for n in restart distill ensure; do cp "$PROJ_ROOT/src/bash/scripts/peer-$n-cron.sh" "$SC/"; done` —
  the sandbox copies the wrappers alone, so the head must copy the inc too, as the plan says),
  section 11 at `:429-439`. `mcp-start.sh:66-97` = `_id_from_ancestry() { ... }`, caller
  `:102` (`AGENT_ID="$(_id_from_ancestry || true)"`); `mcp-start-chrome.sh:54-83` = the body,
  caller `:88` (same line); both scripts `set -euo pipefail` (`:54`, `:41`).
  `spool-install/steps/y1-mcp-bot.sh:22-31` = the symlink install with
  `not a symlink: left alone`. `.github/workflows/10_ci-quality.yml:1344` = the comment
  above the orc FEATURE-tests block that runs every
  `csi-spl-orc/src/bash/features/*/tests/test-*.sh` via `run-ci-tests.sh`.
  `sa:lib/spool-env.inc.sh:125` = `SPOOL_AGENT_ID_NEW_RX='[acgmoqu]-[0-9]{3}'`; the function
  body uses `^[acgmq]-[0-9]{3}$` — the two letter sets differ, as the plan's 1.2(b) says.

## 3. Red controls, run on the plan's base in a scratch copy (n=1)

Scratch: `git archive 4dd74b366 | tar -x -C /tmp/r85-base`. Control files at base, `sha256sum`:

```
d0b24bf8285c52b052fc0b9fb6df0f26c7758e8cfcf9c2dc77a2360106f3af90  csi-spl-orc/src/bash/tests/peer-restart.tst.sh
40f746f1085253dfc42fcb4e47f049179cb7171a5e942d6fba66b5ed59130ffd  csi-spl-orc/src/bash/features/mcp-bot/tests/run-all-tests.sh
4aaf48a653b4c09f9e00f9a4096ffe26cb6c8a8dd0bccca250a7faa830c3e469  peer-distill-cron.sh
fc76a702a227ce1d8141082621b83b9b934777771b33f10cbb704f19a3dff20f  peer-ensure-cron.sh
c525b70ad2b5a151d1adf5b4705a7da14eb06e179920a73bd4f7683bc13df394  peer-restart-cron.sh
ab9c8b0e47b8c29c04de12d4ff758e8da4c6cc2d66d991d634e1074e3afce9e6  mcp-start.sh
1d3b664543cbc3a505757e3fda7aaeafbcdaf8cbdbb5a6251abd925ae57d0201  mcp-start-chrome.sh
```

Base runs (green, matching the plan's 1.5):

- `SPOOL_TEST=1 bash csi-spl-orc/src/bash/tests/peer-restart.tst.sh` -> rc **0**, 35 pass /
  0 fail, last line `peer-restart: all passed`.
- `SPOOL_TEST=1 bash csi-spl-orc/src/bash/features/mcp-bot/tests/run-all-tests.sh` -> rc **0**,
  89 pass / 0 fail, 5 suites, last line `ALL mcp-bot TESTS PASSED`.
- `SPOOL_TEST=1 bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` -> rc **0**, 15 pass,
  last line `PASS: all bash-cleancode.tst.sh assertions`.
- `shellcheck -S warning -x` on the 3 wrappers + 2 mcp-bot scripts + `peer-restart.tst.sh`
  -> rc **0**, 0 findings.

Red controls (the head's test on base; the head test files are not on the plan branch, so the
cases were rebuilt in the scratch copy exactly as the plan's 1.3/1.4 describe — one `cp` line
after `:328` and one case in section 11 for row 01; the 6 assertions of the new test for
row 02):

- Row 01: `SPOOL_TEST=1 bash peer-restart.tst.sh` (head's test on base) -> rc **1**, 35 pass /
  1 fail, last line `peer-restart: 1 failure(s)`, FAIL line
  `FAIL: 11. defined once (want 'peer-cron.inc.sh ', got 'peer-distill-cron.sh peer-ensure-cron.sh peer-restart-cron.sh ')`
  — byte-identical to the plan's quoted red. Fails for the plan's reason (the functions are
  defined three times in the wrappers and the inc does not exist on base), not for an
  environment reason.
- Row 02: the new test's assertions on base -> rc **1**, last line
  `test-id-from-ancestry: 5 failure(s)`; `bash -c '_id_from_ancestry'` on base -> rc **127**
  (command not found, the lib is not there); `grep -rlE '^_id_from_ancestry\(\) *\{'` over
  `scripts`+`lib` -> `mcp-start-chrome.sh mcp-start.sh ` (want the lib alone); both wrappers
  sourcing the lib -> 0 of 2. Fails for the plan's reason, not an environment reason.
- Live state: both suites run under `SPOOL_TEST=1` in a `mktemp -d` sandbox with stubbed
  `./run`, tmux, /proc, crontab (test header: "Nothing real is touched"); my scratch copy is
  under `/tmp`. Neither control touches live state.

## 4. Equivalence of each row

- Row 01: `diff` of the three wrappers (base) shows they differ only in the header
  (`:2-5`, `:10`), the name in the messages (`:36`, `:42`, `:50`, `:52`) and the `./run`
  line (`:51`). The head moves `:15-30` + `:32-53` into `peer-cron.inc.sh` parameterized by
  `NAME` and `VAR=VALUE...`, so each wrapper keeps its own name in the messages and its own
  `env` word (`DRY_RUN=0` for distill/restart, none for ensure) — no output, exit code
  (2 unknown argument, 3 missing tool, 0 `--check-tools`), path or default changes. The
  control catches a difference: section 11 asserts the exact `cronrun.log` content
  (`-a do_spl_peer_restart DRY_RUN=0`, `-a do_spl_peer_distill DRY_RUN=0`,
  `-a do_spl_peer_ensure DRY_RUN=`) and the missing-tool exit 3, and the new case asserts
  the functions are defined once in the inc.
- Row 02: `diff` of the two `_id_from_ancestry` bodies (base) -> exactly 3 lines: two
  comments the chrome copy lacks and `local ... prev _` vs `local ... prev`; `grep '\$_'`
  over both bodies -> no match, so `_` is only the loop variable and nothing reads it. My
  probe: sourcing each base copy and calling the function under the same parent -> both
  return the same id (`m-919`, rc 0). The lib holds mcp-start.sh's copy verbatim and prints
  nothing when sourced (the body is only the function definition); both wrappers call it
  once (`:102`, `:88`) with `|| true`. No exit code, message, path or default changes. The
  control catches a difference: the new test asserts the returned id for the ancestor cases,
  defined-once in `lib/`, and that both wrappers source the lib.

## 5. Per row: R2 control, tests, vendor, kind, batch, R7, R1

- Both rows have a control that fails today (section 3: rc 1 with the plan's quoted FAIL
  lines) and passes after (the planner's head runs: 36 pass row 01, 96 pass row 02; after the
  row the greps return the inc/lib alone, so the new cases pass — the row heads are not on
  the plan branch, see N2).
- Test lists (plan section 2): row 01 `peer-restart.tst.sh`, `bash-cleancode.tst.sh`,
  `do_check_pre_push`; row 02 `mcp-bot/tests/run-all-tests.sh`, `bash-cleancode.tst.sh`,
  `do_check_pre_push`. R2 test-name greps at base: row 01 -> `boot-cron-gate.tst.sh`,
  `peer-restart.tst.sh`, `wd-ensure.tst.sh` (the first two name `spl-peer-crons.func.sh`,
  which row 01 does not change); row 02 -> the mcp-bot tests plus
  `spool-install/tests/test-install.sh`, `check-ysg-box-deps.tst.sh`,
  `spl-skills-refresh.tst.sh`, `spl-spool-refresh-shared.tst.sh`, `spl-spool-refresh.tst.sh`
  (they make/check `mcp-start*.sh` as symlinks or fixture names; none runs the scripts) —
  matches the plan's 1.5 list.
- Vendor `claude`, kind `simple_coding`, batch 1 for both rows; **no mistral coding or
  testing row**. R7 reviewer: the plan names a fresh claude waiver seat (1a7c70da) because
  `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` printed `pick=hold` — I re-ran it at review
  time: `pick=hold reason=every box that could take this lane is in its recovering hold
  (<box> healthy for 1488s < hold 1800s): queue the lane, spawn nothing`. Cross-vendor or
  claude-waiver, never mistral: satisfied.
- R1: row 01's 5 files and row 02's 4 files share no path
  (`comm -12` of the two basename sets -> 0 lines); both in batch 1.

## 6. R3: lane map, queue, branches

- `lane-map.sh --check <the 9 row paths, comma-separated> --agent m-919` -> **exit 4**:
  `WARN no live lane lists <the 9 paths>, but 9 live lane(s) record no files` — the
  `unknown:` lanes are c-782@sat (rotate), c-809@<box> (b34-01), c-880@<box> (r84-01),
  c-893@sat (b35-01), c-894@sat (spec 184 H1), c-898@sat (spec 123 L4), g-888@sat and
  g-889@sat (rotates), m-896@sat (spec 033 T026); by slug none is a peer-cron or mcp-bot
  lane. No live lane lists a row path. (r84-02 c-906@<box> is no longer in the unknown list:
  it landed as `15eb398c8`.)
- `git log origin/master --since="2026-11-21T16:01:28+02:00" -- <the 9 paths>` -> **0**.
- Every non-master remote branch, `git diff --name-only $(git merge-base origin/master <b>) <b> -- <the 9 paths>`
  -> **0 hits**.
- `do_spl_spawn_queue` at review time: **11 queued** (b35-01 claude waiver reviewer,
  s123-l4 grok reviewer, WUI google-verify, spl6174 gct locales, s123 L5/L6/L7, s123 L3w,
  spl5882 T3, csi-rel home lede, s154 B7) — none is an orc scripts or mcp-bot lane.
  Share line: refactor 5 of 22 known live lanes, 22% (band 10-20%: OVER).
- The brief's listed live/queued lanes (r84-01 c-880@<box>, r84-02 c-906@<box>, b34-01 c-809@<box>,
  b35-01 queued, spec 184 A1/C1/L1, SPL-6182 c-806@<box>, SPL-6188 c-851, spec 190): none
  touches a row file (lane map + the two scans above).

## 7. Inputs accounted for; one logical refactor per row

- `/var/spool-hub/dispatch/c002-next-round-candidates.md` is **not on this box**
  (`find /var/spool-hub -iname '*next-round*'` -> nothing; the only candidates file here is
  the 2026-10-11 `c002-a8000a91-candidates.txt`, 62 rows, whose refactor-shaped rows are old
  perf/ui/clean-code candidates served by earlier rounds). Per the plan's 1.2(a) the holder
  inlined the same 8 refactor/test-shaped lines r84 judged; I read r84's section 7 on
  `origin/master` and checked each item against r85's section 7: `parse-metadata.func.sh`
  `${1:?}` (bug row), `spl-lane-mix.func.sh` (candidates `:104`, behaviour),
  `workspace-rules.md`/wf 10 job name (candidates `:105`, doc text),
  `_spool_desk_root_key` (behaviour), the agent-id regex literal (two letter sets, over the
  cap), `usage`/`say`/... (not one fact), `topic_loop_fire.go` + the argmax test (test rows),
  spec 011 T001-T008 etc. (owner-deferred) — **all accounted for** in r85 section 7, which
  also lists its own G4 left-outs (`check_tools` in the other 15 wrappers, `as_root`/`as_owner`,
  `tf_get`). No refactor-shaped input is neither served nor accounted for.
- Each row is ONE logical refactor with no behaviour change: row 01 changes no exit code
  (2/3/0), message, path, cron line or default (section 4); row 02 changes no id returned,
  no exit code, no path (section 4). Neither is a bug row.

## 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-919`, rc **0**.

## Defects

None. **PASS**.

## Notes

- N1: the lane-map check exits 4 (9 `unknown:` lanes that record no files, all on the other
  box) — the same class as the planner's own 2.2 read; no live lane lists a row path. The
  row lanes re-run R3 at spawn, as the plan says.
- N2: the row heads (and the head test files) are not on the plan branch; the red controls
  were reproduced on a fresh `git archive 4dd74b366` copy as the plan's own assertions, and
  row 01's FAIL line came out byte-identical to the plan's quote. The "passes after" side is
  the planner's head runs (36 / 96 pass) plus the after-state reasoning in section 5.
- N3: the candidates file named in my brief is on the other box; check 7 was done against
  r84's section 7 on `origin/master` (the same 8 lines the holder inlined) and the old
  candidates file present here.
- N4: r84-02 landed (`15eb398c8`) after the plan's base; `git diff --name-only 4dd74b366
  origin/master -- <the 9 row paths>` is empty, so no row site drifted. The section-7 row
  about `desk-root.inc.sh` stays out for the behaviour reason regardless.
- N5: `BOX_PICK_KIND=grok do_spl_box_pick` at review time printed `pick=hold` (<box> in its
  recovering hold), so the claude waiver R7 seat stands; the holder re-runs the pick when it
  places the rows. Never a mistral code R7.
- N6: the plan's 2.2 queue read said 9 queued at 16:54Z; at review time 11 — live state,
  carries its own time; none on a row path.
