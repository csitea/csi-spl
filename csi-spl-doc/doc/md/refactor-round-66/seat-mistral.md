# Refactor round 66 (r66): mistral panel seat (m-391)

Seat: m-391@<box>, placement `c002-refactor-round-66-mistral-panel-seat` (mistral;
docs and reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/spawn-remote/briefs/ba9947db-cc9c-48ce-9637-df324feaecc5.md`
(Issue SPL-5961, Epic SPL-2402, Spec `csi-spl-doc/specs/011-spool-project-refactor`,
class refactor, kind specs_and_docs, topic `aa7d4c84-8dc1-47ea-b286-db4e2f0e992a`).

Review target: plan v0.1 `3bfe87d48ce7f256ba9c036674b7ef3586b791c2`, named by
c-379@<box> msg 0f9771c7 and in the brief. Provenance: `git ls-remote origin | grep -E
'r66-[0-9]{2}|refactor-round-66'` -> `3bfe87d48ce7f256ba9c036674b7ef3586b791c2
refs/heads/review/c003-refactor-round-66-planner` (only that branch; my own review
branch did not exist yet at my read);
`git log --oneline -3 3bfe87d48` -> `3bfe87d48 docs(r66-plan, SPL-5961): ...` on
`e178584df` on `80c903ddc`;
`git show --stat 3bfe87d48` -> 1 file `csi-spl-doc/doc/md/refactor-round-66-plan.md`,
313 insertions. All reads below are `git show 3bfe87d48:...` / `git grep ... 3bfe87d48`
unless a command names another ref. origin/master at my read: `67232dbc8` (the b21 plan
v1.0), one commit past the measuring sha `e178584df`.

## Verdict

**PASS on `3bfe87d48ce7f256ba9c036674b7ef3586b791c2`** (2026-11-19 ~13:0xZ).
W1..: none. N1-N5 below.

### 1. Slug r66 unused

- `git log origin/master --oneline -E --grep='\(r66-' | wc -l` -> **0**.
- `git ls-remote origin | grep -E 'r66-[0-9]{2}|refactor-round-66'` -> only
  `3bfe87d48... refs/heads/review/c003-refactor-round-66-planner` (the planner's,
  expected). Nothing else.
- `grep -rlE 'r66-[0-9]{2}' /var/spool-hub/dispatch/briefs /var/spool-hub/dispatch/asks
  /var/spool-hub/spawn-remote/briefs 2>/dev/null | wc -l` on this box -> **1**:
  `/var/spool-hub/spawn-remote/briefs/ba9947db-cc9c-48ce-9637-df324feaecc5.md` (my own
  brief, expected). The other box's briefs are not readable from this box; c-002@<box2>
  ran that grep on the other box (msg 3d08cf29, 2026-11-19T12:37:50Z): `grep -rlE
  'r66-[0-9]{2}' /var/spool-hub/dispatch/briefs /var/spool-hub/dispatch/asks | wc -l`
  -> **1**: `briefs/c002-refactor-round-66-mistral-panel-seat.md` (my own brief).
  No row brief.
- Control: `git log origin/master --oneline -E --grep='\(r65-' | wc -l` -> **5**, so the
  log read sees a used id.

### 2. Every site file:line of both rows exists on `e178584df` and on origin/master

Full paths (`git ls-tree -r --name-only origin/master | grep <name>`), one per row file:
`csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh`,
`csi-spl-orc/src/bash/tests/spl-run-paths.tst.sh`,
`csi-spl-orc/src/bash/run/spl-cmd-guard-mode.func.sh`,
`csi-spl-orc/src/bash/tests/spl-cmd-guard-mode.tst.sh`,
`csi-spl-utl/src/bash/run/fleet-logrotate-install.func.sh`,
`csi-spl-utl/src/bash/tests/fleet-logrotate.tst.sh`,
`csi-spl-orc/src/bash/tests/no-literal-paths.baseline` — all 7 exist on both refs
(`git ls-tree -r --name-only e178584df | grep -E 'spl-run-paths.tst.sh|...'` -> the 3
test files; the rest via the origin/master ls-tree).

`git show <ref>:<file> | sed -n <N>p` on both `e178584df` and `origin/master` — identical
on the two refs, matching the plan's section 1.2:

- `spl-run-paths.func.sh:13-16` -> the 4 `@description` lines (`SPL_ORG_DIR <base>/<org>`,
  `SPL_VAR_APP_DIR <var>/<org>/<app>`, `SPL_WT_ROOT`, `SPL_DESK_DIR`); `:62-73` -> the
  `spl_run_paths` comment + function, with `:69` `: "${SPL_VAR_APP_DIR:=${base%/*}/var/${org##*/}/${main##*/}}"`
  and `:72` `export SPL_ORG_DIR SPL_VAR_APP_DIR SPL_WT_ROOT SPL_DESK_DIR`.
- `spl-cmd-guard-mode.func.sh:20` -> `# @param SPL_RUST_HOME /mnt/data/var/csi/rust when
  /mnt/data is mounted, else /var/csi/rust`; `:36` -> `    rh=/var/csi/rust`; `:37` ->
  `    mountpoint -q /mnt/data 2>/dev/null && rh=/mnt/data/var/csi/rust`.
- `fleet-logrotate-install.func.sh:7` -> `# @description box-disk-sweep/box-disk-sweep.log
  under /var/csi/csi-spl once they`; `:24` -> `# @param FLEET_LOGROTATE_VAR_DIR (optional)
  - default /var/csi`; `:70` -> `  FL_VAR="${FLEET_LOGROTATE_VAR_DIR:-/var/csi}"`;
  `:89,:96` -> the `$FL_VAR/...` lines (no literal, unchanged by the row).
- `spl-file-erase.func.sh:31,120` (the left-out item) -> `:31` `#   /var/csi, /opt)` and
  `:120` `printf '%s\n' /root /var/spool-hub /var/tmp /tmp /var/csi /opt`.
- `utl:run/orphan-process-reap.func.sh:58` (the plan's "utl already reaches the orc lib")
  -> `declare -F spl_run_paths >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../../csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh"`.

Drift: `git log e178584df..origin/master --oneline -- <the 7 paths>` -> empty (the one
commit between them, `67232dbc8`, is the b21 plan doc only). No file drifted.

Counts re-measured: `git grep -nE '/(opt|var)/csi($|[^A-Za-z0-9_-])' e178584df -- '*.sh'
':!**/tests/**'` -> exactly the 3 files / 8 lines the plan claims
(`spl-cmd-guard-mode.func.sh:20,36,37`, `spl-file-erase.func.sh:31,120`,
`fleet-logrotate-install.func.sh:7,24,70`); the same scan on `origin/master` -> the same
3 files. Newest changes: `git log origin/master --oneline -1 --
csi-spl-orc/src/bash/run/spl-cmd-guard-mode.func.sh` -> `071685209 fix(orc, SPL-5487)...`;
`-- csi-spl-utl/src/bash/run/fleet-logrotate-install.func.sh` -> `8ca138a3b feat(hyg-01-fleet-logrotate, SPL-2233)...`
— both match the plan's 1.2.

### 3. The baseline

`git show origin/master:csi-spl-orc/src/bash/tests/no-literal-paths.baseline` ->
**3 files, 8 lines**: `3 csi-spl-orc/src/bash/run/spl-cmd-guard-mode.func.sh`,
`2 csi-spl-orc/src/bash/run/spl-file-erase.func.sh`,
`3 csi-spl-utl/src/bash/run/fleet-logrotate-install.func.sh`. The 2 lines r66-02 drops
(the `spl-cmd-guard-mode` 3 and the `fleet-logrotate-install` 3) **are in it today**.
The gate fails a stale entry: `git grep -n 'STALE baseline'
origin/master -- csi-spl-orc/src/bash/tests/no-literal-paths.tst.sh` -> `:55,:56`.
Batch order makes each row apply: row 01 touches only `spl-run-paths.func.sh` +
`spl-run-paths.tst.sh` (baseline stays 3/8, per plan section 6), row 02 runs after row 01
(`SPAWN_AFTER=c003-r66-01-orc-run-paths-var-org-dir`) and drops its 2 lines in the same
commit -> 1 file / 2 lines (`spl-file-erase` only).

### 4. Each row: practice, control (R2), test list, vendor, kind, batch; no mistral row

From the plan at `3bfe87d48` (sections 3, 5, 6): both rows carry the practice (section 3
per-row "what the lane does"), a control that fails today and passes after (row 01: the
new case-1 assertion on the unchanged lib RED then on the change GREEN, both outputs in
the body; row 02: derived path = old literal on the box, env override wins,
`SPL_RUN_PATHS_TOP=` -> rc 1, both dry runs print the same before and after, never
`DRY_RUN=0`), a gate/test list (row 01: `spl-run-paths`, `no-literal-paths`,
`spl-file-stream-follow`, `wd-login-snapshot`, `install-box-crons`, `run-eager-files`;
row 02: `spl-cmd-guard-mode`, `no-literal-paths`, `spl-run-paths`, `run-eager-files`,
`fleet-logrotate`, plus `do_check_pre_push`), vendor **claude** and kind **simple_coding**
for both (section 6 counts: vendor claude 2, kind simple_coding 2), batches 1 (row 01) and
2 (row 02 after 01). No mistral coding or testing row: plan header "**Vendor claude for
every row.**" and section 4 "Not a mistral code R7". R7 reviewers (section 4):
cross-vendor first (agy if its pick still holds), else a fresh claude seat under the
claude waiver — never mistral. This seat is the doc-review panel only (rulebook 3.2),
which the owner's mistral rule allows.

### 5. Behaviour: the control proves it, and `<var>/<org>` = `/var/csi` on this box

The plan states how each lane proves no behaviour change (its control, section 2 row 02:
derived = old literal on the box, override wins, `SPL_RUN_PATHS_TOP=` rc 1, both dry runs
identical, never `DRY_RUN=0`). On this box, sourcing the lib from the main checkout
with the vars unset (`env -u APP_PATH -u PROJ_PATH -u SPL_VAR_APP_DIR -u SPL_ORG_DIR -u
SPL_WT_ROOT -u SPL_DESK_DIR bash -c 'source
/opt/csi/csi-spl/csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh; spl_run_paths; ...'`)
-> rc 0, `SPL_ORG_DIR=/opt/csi`, `SPL_VAR_APP_DIR=/var/csi/csi-spl`, so the new
`SPL_VAR_ORG_DIR` = `<var>/<org>` = `${SPL_VAR_APP_DIR%/*}` = **/var/csi** — the value both
row-02 literals hold. `mountpoint -q /mnt/data` -> rc 1 and `/var/csi/rust` exists, matching
the plan's box note. A new export in a lib every action sources is safe:
`git grep -n SPL_VAR_ORG_DIR origin/master | wc -l` -> **0** (the name is free; no existing
user it would shadow).

### 6. R3: lane-map over the 7 written paths

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh
--check csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh,csi-spl-orc/src/bash/tests/spl-run-paths.tst.sh,csi-spl-orc/src/bash/run/spl-cmd-guard-mode.func.sh,csi-spl-orc/src/bash/tests/spl-cmd-guard-mode.tst.sh,csi-spl-utl/src/bash/run/fleet-logrotate-install.func.sh,csi-spl-utl/src/bash/tests/fleet-logrotate.tst.sh,csi-spl-orc/src/bash/tests/no-literal-paths.baseline
--agent m-391` -> **exit 4**: no live lane lists the paths, but 3 live lanes record no
files: `c-922@<box2>`, `c-926@<box2>`, `m-923@<box2>` ("unknown, ask first", not free). The plan's
2.2 read the same check at 2026-11-19T12:25:49Z -> exit 4 with 5 such lanes (c-852, c-912,
m-923, c-922, c-926) and reasoned from their scopes (b21 planner/panel, WUI lanes) that
none writes a row path; the holder's R3 re-check before each row's spawn governs. My seat
writes only this seat file, so no collision with any lane.

### 7. R1 across rounds: no live perf or bug round row names these files

- Newest perf plan on origin/master: `perf-round-18-plan.md`;
  `git grep -cE 'spl-run-paths\.func|spl-cmd-guard-mode|fleet-logrotate-install|no-literal-paths'
  origin/master -- csi-spl-doc/doc/md/perf-round-18-plan.md` -> no output, rc 1 (**0**).
- Newest bug plan on origin/master: `bug-round-21-plan.md` (origin/master head is
  `67232dbc8`, the b21 plan v1.0, so master's copy is that sha); the same `git grep -cE`
  -> rc 1 (**0**). The b21 plan's rows (its lines 53-54) write
  `csi-spl-orc/src/bash/run/spl-review-go.func.sh`,
  `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`,
  `csi-spl-doc/specs/157-dispatch-automation/spec.md`,
  `csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push`,
  `csi-spl-orc/src/bash/tests/lane-wip-push.tst.sh`,
  `csi-spl-doc/doc/md/pre-push-gate.md` — disjoint from the 7 r66 paths.
- `git log origin/master --since="2026-11-19T10:50:02+01:00" --oneline -- <the 7 paths>`
  -> 3 commits, all on `no-literal-paths.baseline` and all landed: `b2ac50a07` (r64-02),
  `80c903ddc` (r65-01), `e178584df` (r65-02) — matches the plan's 2.2.
- `git ls-tree --name-only e178584df csi-spl-doc/doc/md/ | grep -c 'round-66'` -> **0**
  (the plain plan name is free, rulebook 5.3).

### 8. The dispatcher's candidates file (the other box only)

`/var/spool-hub/dispatch/c002-next-round-candidates.md` does not exist on this box
(`ls` -> No such file or directory); c-002@<box2> read it on the other box (msg 3d08cf29,
2026-11-19T12:37:50Z): 33 lines, mtime 2026-11-19T10:33Z; its refactor-shaped literal-path
items are (a) 2026-11-17 r34-05 R7 N3: `spl-watchdog.func.sh:72,:1311` (LOGIN_STATE_DIR
default) and `spl-lane-rotate.func.sh:112`; (b) 2026-11-18 r63-01 R7 W1:
`csi-spl-orc/src/bash/scripts/reverse-tunnel-cron.sh:23` (REVERSE_TUNNEL_STATE_DIR default);
the 11-19 additions are bug-shaped (b20/b21). My verification on origin/master:
`git show origin/master:csi-spl-orc/src/bash/run/spl-watchdog.func.sh | sed -n 72p` ->
`# @param LOGIN_STATE_DIR (optional) - login-check's state dir, default
spl_claude_login_state_dir (<SPL_VAR_APP_DIR>/agent-login-check)` (no literal);
`... spl-lane-rotate.func.sh | sed -n 112p` -> `  if [[ -z "${ROTATE_LANE_LOGIN_CACHE:-}" ]]; then`;
`... reverse-tunnel-cron.sh | sed -n 23p` -> `# shellcheck source=../../../lib/bash/funcs/spl-run-paths.func.sh`;
and the non-test `*.sh` literal scan on origin/master still returns exactly the same
3 files / 8 lines as on `e178584df`. So (a) and (b) do **not** stand as open literal-path
items today, and no refactor-shaped item added since r65 is missing from the plan's
section 7 — section 7's left-out table covers the remaining literal (`spl-file-erase`)
with a measured reason.

### 9. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-391`,
exit **0**.

## Defects

W1..: none.

## Notes

- N1: origin/master at my read is `67232dbc8` (b21 plan v1.0), one commit past the
  measuring sha `e178584df`; every cited row file:line is byte-identical between the two
  refs (check 2), so the plan's counts hold on trunk too.
- N2: my lane-map read returned exit 4 with 3 unknown lanes (c-922@<box2>, c-926@<box2>,
  m-923@<box2>) vs the plan's 5 at 12:25:49Z — live state moved; exit 4 means "ask first",
  not free, and the plan defers to the holder's R3 re-check before each row's spawn.
- N3: check 8's file is other-box-only; I am on this box, so the file read is
  c-002@<box2>'s (cited as such above); the on-tree verification of its named lines is
  mine, on origin/master.
- N4: check 1's other-box briefs grep is c-002@<box2>'s (1 file, my own brief); on this
  box the same grep over `dispatch/briefs`, `dispatch/asks`, `spawn-remote/briefs` -> 1
  (my own brief).
- N5: window W re-verified: `git log origin/master -1 --format='%H %cI' -E
  --grep='^docs\(r65-plan'` -> `8c6ea882515f1e2c475c9d3ed40edda5029fbf53
  2026-11-19T10:50:02+01:00` — matches the plan's W.

## v1.0 signature (2026-11-19 ~13:0xZ, this session)

Editor c-379's msg 868439ea (task `dispatch-refactor-r66`, 2026-11-19T13:00:22Z) named
v1.0 `3d48fd2c4727b7049ba3debb7e41395c86e28803`. Verified:
`git ls-remote origin | grep refactor-round-66` ->
`3d48fd2c4727b7049ba3debb7e41395c86e28803  refs/heads/review/c003-refactor-round-66-planner`
(the head) and `de0023e4a...  refs/heads/review/c002-refactor-round-66-mistral-seat`
(my branch);
`git merge-base --is-ancestor 3bfe87d48ce7f256ba9c036674b7ef3586b791c2
3d48fd2c4727b7049ba3debb7e41395c86e28803` -> exit 0 (v0.1 is the only parent:
`git log --oneline 3bfe87d48..3d48fd2c` -> one commit, the v1.0);
`git diff --stat 3bfe87d48 3d48fd2c` -> 1 file, +17/-3, hunks only at `@@ -30,7 +30,8 @@`
(the status line) and `@@ -303,11 +304,24 @@` (sections 8/9);
`git diff 3bfe87d48 3d48fd2c -- <plan> | grep -cE '^[+-]\| r66-0[12] '` -> **0**
(rows unchanged). My N1-N5 are folded in section 8 and section 9 records the v0.1 PASS
(spool msg 500404e5, task `dispatch-refactor-r66`) with "v1.0: to be signed by m-391".

Re-read on the current origin/master `ea431c511` (landed since my v0.1 read):
`git log origin/master --oneline -E --grep='\(r66-' | wc -l` -> **0** (slug still free);
`git log e178584df..origin/master --oneline -- <the 7 row paths> | wc -l` -> **0** (no
drift); baseline `git show origin/master:.../no-literal-paths.baseline | grep -vE
'^\s*(#|$)'` -> still 3 files / 8 lines; spot-checked site lines identical
(`spl-cmd-guard-mode.func.sh:36` -> `    rh=/var/csi/rust`,
`fleet-logrotate-install.func.sh:70` -> `  FL_VAR="${FLEET_LOGROTATE_VAR_DIR:-/var/csi}"`,
`spl-run-paths.func.sh:69,72` -> the `SPL_VAR_APP_DIR` default and the 4-var export);
`lane-map.sh --check <the 7 paths> --agent m-391` -> exit 4, now 2 unknown lanes
(c-922@<box2>, c-926@<box2>; m-923@<box2> records files now).

**Verdict on v1.0 `3d48fd2c4727b7049ba3debb7e41395c86e28803`: PASS** — rows unchanged from
v0.1, my notes folded, no drift onto `ea431c511`. W1..: none on v1.0. N1-N5 stand.

## Seat state

Verdict reports sent on task `dispatch-refactor-r66` (kind result): v0.1 PASS at
2026-11-19T12:59:25Z to c-379@<box> and the then-holder c-002@<box2> (msg 500404e5,
47005f77); v1.0 PASS after this commit, same form, same recipients. This seat waits for a
message on that task whose body starts with ACCEPTED from c-379 or the dispatch holder;
until then no /exit-clean. Branch `review/c002-refactor-round-66-mistral-seat` holds both
commits.
