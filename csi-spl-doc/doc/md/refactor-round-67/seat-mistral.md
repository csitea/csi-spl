# Refactor round 67 (r67): mistral panel seat (m-977)

Seat: m-977@<box>, placement `c002-refactor-round-67-mistral-panel-seat` (mistral;
docs and reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-67-mistral-panel-seat.md`
(Issue SPL-5969, Epic SPL-2402, Spec `csi-spl-doc/specs/011-spool-project-refactor`,
class refactor, kind specs_and_docs, topic `95ef4159-71dd-418c-b1fb-7f17eb4d24c3`).

Review target: plan v0.1 `7c4e9b38fe9c026d3a69b3ee5ff86f6f980dc2c4`, named by
c-443@<box> msg b3592b83 and in the brief. Provenance:
`git merge-base --is-ancestor 7c4e9b38fe9c026d3a69b3ee5ff86f6f980dc2c4 origin/master`
-> exit 0 (on origin/master);
`git ls-remote origin | grep -E 'r67-[0-9]{2}|refactor-round-67'` ->
`7c4e9b38fe9c026d3a69b3ee5ff86f6f980dc2c4 refs/heads/review/c002-refactor-round-67-planner`
(only the planner's branch; my own review branch did not exist yet at my read);
`git show 7c4e9b38f --stat` -> 1 file `csi-spl-doc/doc/md/refactor-round-67-plan.md`,
300 insertions. All reads below are `git show 7c4e9b38f:...` / `git grep ... 7c4e9b38f`
unless a command names another ref. origin/master at my read: `69c9febbb` (the
spec-107 doc), two commits past the measuring sha `1ce9158a1` (`7c4e9b38f` the plan
doc in between); neither touches a row file (check 2).

## Verdict

**PASS on `7c4e9b38fe9c026d3a69b3ee5ff86f6f980dc2c4`** (2026-11-19 ~16:0xZ).
W1..: none. N1-N5 below.

### 1. Slug r67 unused

- `git log origin/master --oneline -E --grep='\(r67-' | wc -l` -> **1**: the plan's
  own commit `7c4e9b38f docs(r67-plan, SPL-5969): ...` (scope `r67-plan`, not a row).
  The row-id pattern `git log origin/master --oneline -E --grep='\(r67-[0-9]' | wc -l`
  -> **0**.
- `git ls-remote origin | grep -E 'r67-[0-9]{2}|refactor-round-67'` -> only
  `7c4e9b38f... refs/heads/review/c002-refactor-round-67-planner` (the planner's,
  expected); `git ls-remote origin | grep -E 'r67-[0-9]{2}'` -> rc 1 (nothing).
- `grep -rlE 'r67-[0-9]{2}' /var/spool-hub/dispatch/briefs /var/spool-hub/dispatch/asks 2>/dev/null | wc -l`
  on this box -> **1**: `/var/spool-hub/dispatch/briefs/c002-refactor-round-67-mistral-panel-seat.md`
  (my own brief, expected); over `/var/spool-hub/spawn-remote/briefs` -> **0**.
- Control: `git log origin/master --oneline -E --grep='\(r66-' | wc -l` -> **5**, so
  the log read sees a used id.
- Window W re-derived: `git log origin/master -1 --format='%H %cI' -E --grep='^docs\(r66-plan'`
  -> `cb56a8993c86b26b693379dd3fcd25a1cc8d6c22 2026-11-19T14:04:01+01:00` — matches the
  plan's recorded W.

### 2. Every site file:line of both rows exists on `1ce9158a1` and on origin/master

Full paths (`git ls-tree -r --name-only origin/master | grep <name>`), one per row
file: `csi-spl-iac/src/bash/run/gcp-backup-env.func.sh`,
`csi-spl-iac/src/bash/run/satellite-verify.func.sh`,
`csi-spl-iac/src/bash/run/tf-init.func.sh`,
`csi-spl-iac/src/bash/run/tf-state-push.func.sh`,
`csi-spl-iac/src/bash/tests/adhoc-harvest-gcp-actions.tst.sh`,
`csi-spl-iac/src/bash/tests/sec-gosec.tst.sh` — all 6 exist on both refs.

`git show <ref>:<file> | sed -n <N>p` on both `1ce9158a1` and `origin/master` —
identical on the two refs, matching the plan's section 1.3:

- `gcp-backup-env.func.sh:149` -> `  local port="${SPL_PROXY_PORT:-55497}" con="$ORG-$APP-$ENV-bk-proxy-$$" i`
  ; `:153` -> `  for i in $(seq 60); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.5; done`
- `satellite-verify.func.sh:121` -> `  local script here there name hv sv d`
- `tf-init.func.sh:10` -> `  tgt_app=${APP:?}`
- `tf-state-push.func.sh:27` -> `  vars_path="${tf_vars_path:-$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.vars.tfvars}"`
- `adhoc-harvest-gcp-actions.tst.sh:25` -> `RUN="$PROJ_ROOT/src/bash/run"`
- `sec-gosec.tst.sh:37` -> empty; `:38` -> `F="$ROOT/csi-spl-api/src/go/spool-hub-api"   # path fragment for "spool-hub-api/"`
  ; `:39` -> empty

Drift: `git log 1ce9158a1..origin/master --oneline -- <the 6 files> | wc -l` -> **0**.
Newest change of each (`git log origin/master --oneline -1 -- <file>`):
`26d6690b1` (gcp-backup-env, tf-state-push), `99119a3df` (satellite-verify),
`2975facfa` (tf-init), `47f62ee2e` (adhoc-harvest-gcp-actions), `e3388fce3`
(sec-gosec) — matches the plan's 2.2. No file drifted.

### 3. The baseline

Real path: `git ls-tree -r --name-only origin/master | grep shellcheck-warning-baseline`
-> `.shellcheck-warning-baseline.txt` (repo root).
`git show origin/master:.shellcheck-warning-baseline.txt | grep -vcE '^\s*(#|$)'`
-> **86** non-comment lines; `| grep 'SC2034' | grep -vcE '^\s*#'` -> **41** SC2034
lines; `| grep 'SC2034' | grep csi-spl-iac` -> **10** lines under `csi-spl-iac`,
including all 6 the rows drop:
`SC2034|csi-spl-iac/src/bash/run/gcp-backup-env.func.sh|1`,
`.../satellite-verify.func.sh|1`, `.../tf-init.func.sh|1`,
`.../tf-state-push.func.sh|1`, `.../tests/adhoc-harvest-gcp-actions.tst.sh|1`,
`.../tests/sec-gosec.tst.sh|1` — all in it today. The 4 left out
(check-pre-push, check-weekly-full-scan, satellite-actions,
workflow-tool-checksums) are also there, matching 1.3.

Batch order makes each row apply: both rows edit the shared baseline, so R1
serialises them (row 02 `SPAWN_AFTER=c003-r67-01-...`, batch 2 after 01); each row
drops only its own lines in the same commit as its site fix, and the gate holds the
count per (code, file) equal, so after row 01 lands the baseline (82 lines, SC2034
37) is consistent with the code, and row 02 applies on top (80 / 35).

shellcheck 0.10.0 is on this box (`command -v shellcheck` -> found), so the run is
not NOT RUN. Files extracted from origin/master and scanned:
`shellcheck -S warning -f gcc <file>` per row file, SC2034 lines shown -> exactly one
per file, at the plan's lines:

- `gcp-backup-env.func.sh:153:3: warning: i appears unused. ... [SC2034]`
- `satellite-verify.func.sh:121:38: warning: d appears unused. ... [SC2034]`
- `tf-init.func.sh:10:3: warning: tgt_app appears unused. ... [SC2034]`
- `tf-state-push.func.sh:27:3: warning: vars_path appears unused. ... [SC2034]`
- `adhoc-harvest-gcp-actions.tst.sh:25:1: warning: RUN appears unused. ... [SC2034]`
- `sec-gosec.tst.sh:38:1: warning: F appears unused. ... [SC2034]`

### 4. Each row: practice, control (R2), test list, vendor, kind, batch; no mistral row

From the plan at `7c4e9b38f` (sections 2, 4, 5, 6): both rows carry the practice
("bash that fails safely (developer guide 2.4.3): the shellcheck WARNING ratchet
only shrinks"), a red control that fails today and passes after (sites fixed with
the baseline lines left -> `do_sec_shellcheck` FAILS on a LOWER count; lines dropped
-> PASS), a test list (section 1.4 row 01: 13 NAMES files + 20 function-name files,
`bash csi-spl-iac/src/bash/tests/run-all-tests.sh` plus the 4 named orc tests;
row 02: its two test files, `sec-shellcheck.tst.sh`, `do_check_pre_push_lint`),
vendor **claude** and kind **simple_coding** for both (section 6 counts: vendor
claude 2, kind simple_coding 2), batches 1 (row 01) and 2 (row 02 after 01).
Header: "**Vendor claude for every row.**" (owner 10-17, t1 b61851fb: no mistral
coding or testing rows). Section 4: row R7 reviewers cross-vendor first (agy if its
pick still holds, else a fresh claude seat under the claude waiver) — "Not a mistral
code R7". This seat is the doc-review panel only (rulebook 3.2), which the owner's
mistral rule allows.

Spot re-measure of 1.4 on `1ce9158a1`: `git grep -lF 'tgt_app' 1ce9158a1 --
'csi-spl-*/**/tests/*' | wc -l` -> **0**;
`git grep -lF 'RUN="$PROJ_ROOT/src/bash/run"' 1ce9158a1 -- 'csi-spl-*/**/tests/*' | wc -l`
-> **19**; `git grep -lF 'F="$ROOT/csi-spl-api/src/go/spool-hub-api"' 1ce9158a1 --
'csi-spl-*/**/tests/*'` -> `sec-gosec.tst.sh` only; the NAMES pattern for row 01
-> **13** files. All match the plan.

### 5. Behaviour: each removed variable is never read; `tf-init` keeps its stop

`git show origin/master:<file> | grep -n '<var>'` per row file:

- `gcp-backup-env.func.sh | grep -nE '\bi\b'` -> `:149` (the `local` list), `:153`
  (the `for`), `:178` (`docker exec -i` — a flag, not a read of `$i`). The loop body
  never reads `i`.
- `satellite-verify.func.sh | grep -nE '\bd\b'` -> `:121` (the `local` of
  `_satellite_verify_replica`, which starts at `:120`) is the only hit in that
  function; the other hits (`:304` `d=$(mktemp -d)` etc.) are in the script payload
  string below `:222`, a different scope.
- `tf-init.func.sh | grep -n 'tgt_app'` -> `:10` only;
  `git grep -n tgt_app origin/master -- 'csi-spl-*'` -> the plan doc and
  `tf-init.func.sh:10` only (1 code line, as the plan claims).
- `tf-state-push.func.sh | grep -n 'vars_path'` -> `:27` only in this file.
- `adhoc-harvest-gcp-actions.tst.sh | grep -nE '\bRUN\b'` -> `:25` only.
- `sec-gosec.tst.sh | grep -nE '\$F\b|\$\{F\}'` -> rc 1 (**0** hits).

`tf-init.func.sh:10` `tgt_app=${APP:?}` -> `: "${APP:?}"` keeps the same stop when
`APP` is unset: `${APP:?}` makes the shell print `APP: parameter null or not set`
and exit non-zero whether or not it is assigned to a variable; `:13`
`do_require_var APP "${APP:-}"` guards `APP` again right after, so the action still
stops before any work. No behaviour change.

The red control would really fail today: `_sec_baseline_gate`
(`csi-spl-iac/lib/bash/funcs/sec-baseline.func.sh:50`) returns 1 on both `NEW` and
`LOWER` — `LOWER SC2034 <file>: 1 baselined, 0 found` — and
`_sec_shellcheck_warn_ratchet` (`csi-spl-iac/src/bash/run/sec-shellcheck.func.sh:179`,
the gate at `:175-181`) propagates it. So sites fixed with the baseline lines left
fails the gate for the 4 (resp. 2) pairs; dropping the lines passes.

### 6. R3: lane-map over the 7 written paths

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh
--check csi-spl-iac/src/bash/run/gcp-backup-env.func.sh,csi-spl-iac/src/bash/run/satellite-verify.func.sh,csi-spl-iac/src/bash/run/tf-init.func.sh,csi-spl-iac/src/bash/run/tf-state-push.func.sh,csi-spl-iac/src/bash/tests/adhoc-harvest-gcp-actions.tst.sh,csi-spl-iac/src/bash/tests/sec-gosec.tst.sh,.shellcheck-warning-baseline.txt
--agent m-977` -> **exit 4**: no live lane lists the paths, but 8 live lanes record
no files: `c-049@<box2>`, `c-060@<box2>`, `c-414@<box2>`, `c-433@<box2>`,
`c-459@<box2>`, `c-812@<box2>`, `c-924@<box2>`, `c-927@<box2>` ("unknown, ask first",
not free). The plan's 2.2 read exit 4 with 3 such lanes (c-922, c-946, c-947) at
2026-11-19T14:29:53Z — live state moved; the holder's R3 re-check before each row's
spawn governs. My seat writes only this seat file, so no collision with any lane.

### 7. R1 across rounds: no live perf or bug round row names these files

- Newest perf plan on origin/master: `perf-round-18-plan.md` (last touched by
  `da68ad993`); `git grep -cE 'gcp-backup-env|satellite-verify|tf-init\.func|tf-state-push|adhoc-harvest-gcp-actions|sec-gosec|shellcheck-warning-baseline'
  origin/master -- csi-spl-doc/doc/md/perf-round-18-plan.md` -> rc 1 (**0**).
- Newest bug plan on origin/master: `bug-round-21-plan.md` (last touched by
  `67232dbc8`); the same `git grep -cE` -> rc 1 (**0**).

### 8. The candidates file (this box)

`/var/spool-hub/dispatch/c002-next-round-candidates.md` exists here (7650 bytes,
mtime 2026-11-19 15:56Z); its one refactor-shaped item not obviously served is
r63-01 R7 W1, `csi-spl-orc/src/bash/scripts/reverse-tunnel-cron.sh:23` gating on a
literal `<var>/<org>/<app>/reverse-tunnel` default (plus N3,
`csi-spl-doc/doc/md/guides/installation-and-configuration-guide.md:594`).
On origin/master today: `git show origin/master:csi-spl-orc/src/bash/scripts/reverse-tunnel-cron.sh
| sed -n 20,26p` -> `:23` is `# shellcheck source=../../../lib/bash/funcs/spl-run-paths.func.sh`,
`:24-26` source `spl_run_paths` and derive the state dir, `:27` is
`ls "${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}"/*.conf ...` — no
literal. `git show origin/master:...reverse-tunnel-cron.sh | grep -nE '/(opt|var)/csi'`
-> rc 1 (none). Last change of the file: `87d56eaae refactor(r64-01-orc-cron-script-state-dirs,
SPL-5944): the 4 cron wrappers derive their state dir, no literal box path` — the
item is already served by r64-01. The guide `:594` still names
`/var/csi/csi-spl/reverse-tunnel` in prose (a doc example; `no-literal-paths` scans
non-test `*.sh` only). So the plan's section 7 does **not** need to name it.

### 9. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-977`,
exit **0**.

## Defects

W1..: none.

## Notes

- N1: origin/master at my read is `69c9febbb`, two commits past the measuring sha
  `1ce9158a1` (`7c4e9b38f` the plan doc, `69c9febbb` a spec-107 doc); every cited
  row file:line is byte-identical between the refs (check 2, drift 0), so the
  plan's counts hold on trunk too.
- N2: my lane-map read returned exit 4 with 8 unknown lanes (all on the other box)
  vs the plan's 3 at 14:29:53Z — live state moved; exit 4 means "ask first", not
  free, and the plan defers to the holder's R3 re-check before each row's spawn.
- N3: check 1's `\(r67-` log grep prints 1 today — the plan's own commit
  (`r67-plan` scope), measured by the planner as 0 before its plan commit landed;
  the row-id pattern `\(r67-[0-9]` is 0, and no `r67-NN` branch exists on the
  remote, so the row slug is free.
- N4: check 8's candidates file is sat-only and readable here; the reverse-tunnel
  item it carries is already served on origin/master by `87d56eaae` (r64-01), so
  section 7 correctly does not name it; only the guide's prose example at :594
  still shows a literal, which the `*.sh` scan does not cover.
- N5: shellcheck 0.10.0 was present on this box, so check 3's scan ran (not NOT RUN)
  on origin/master extracts; one SC2034 per row file at the plan's lines.

## v1.1 signature (2026-11-19 ~16:4xZ, this session)

Named by the dispatch holder c-002@<box> on task `31b4d745-098a-57d5-9b2e-cab6a0e43c81`
(msg 77608a05, citing planner c-443@<box> msg 4e8121f5): plan v1.1
`38b7f1596f50e7ad1044087e9adb3000eb9f1f10`, origin/master HEAD at my read.
Provenance: `git merge-base --is-ancestor 38b7f1596 origin/master` -> exit 0;
`git log -1 --format='%H %s' 38b7f1596` -> `38b7f1596f50e7ad1044087e9adb3000eb9f1f10
docs(r67-plan, SPL-5969): refactor round 67 plan v1.1 adds row r67-03, ...`;
status line at the sha: "**Status: v1.1, row 03 waits for its signature** ... rows 01
and 02 are unchanged and stay signed". Reviewed ONLY what changed since the v1.0
that folded my v0.1 PASS: `git diff ca05e75b3 38b7f1596 --
csi-spl-doc/doc/md/refactor-round-67-plan.md` -> 240 lines, the plan file only.

**Verdict on v1.1 `38b7f1596f50e7ad1044087e9adb3000eb9f1f10`: PASS** — W1..: none on
v1.1. N6-N9 below.

### What changed since v0.1 (the diff, checked)

- Rows 01/02 table lines unchanged:
  `git diff 7c4e9b38f 38b7f1596 -- csi-spl-doc/doc/md/refactor-round-67-plan.md | grep -cE '^[+-]\| r67-0[12] '`
  -> **0**.
- `86babad74` (v1.0 note): r67-01's `tf-state-push.func.sh:27` removal also turns that
  file's SC2154 baseline line `|1` into `|2`. Verified with shellcheck 0.10.0 on
  `ca05e75b3`'s file: before deleting `:27` -> `27:3 SC2034 vars_path` +
  `35:20 SC2154 tf_run_path`; after `sed '27d'` -> `27:66 SC2154 tf_proj` +
  `34:20 SC2154 tf_run_path`. Baseline today carries both
  `SC2034|csi-spl-iac/src/bash/run/tf-state-push.func.sh|1` and
  `SC2154|csi-spl-iac/src/bash/run/tf-state-push.func.sh|1`. So row 01 drops the
  SC2034 line and raises the SC2154 line to `|2`; the 86 -> 82 line count of section 6
  still holds (a count edit on an existing line, not a new line).
- `38b7f1596` (v1.1): adds row r67-03 (sections 1.2, 1.5, 2, 2.1, 2.2, 3, 5, 6, 7, 8,
  9), measured on `86babad74`.

### r67-03 checks (the holder's three)

1. **Disjoint from r67-01/02:** the 9 row-03 paths (all under
   `csi-spl-api/src/go/spool-hub-api/`) vs the 7 row-01/02 paths —
   `comm -12 <(9 paths sorted) <(7 paths sorted) | wc -l` -> **0**; all 9 exist on
   origin/master (`git cat-file -e origin/master:<path>` -> OK x9). Batch 1 holds rows
   01 and 03 with no shared path (R1 ok).
2. **Site count:** `git grep -nE '\bCASFleetLease\(' 86babad74 -- '*.go'` -> **16
   lines**, `git grep -lE '\bCASFleetLease\(' 86babad74 -- '*.go' | wc -l` -> **8
   files** — as the plan says; re-measured on origin/master (`38b7f1596`) -> 16 / 8,
   nothing moved. Breakdown: interface `fleet_lease.go:48`, impls `fleet_lease.go:86`
   (Memory) and `fleet_lease_postgres.go:64` (Postgres), caller `box_lease.go:98`,
   tests `fleet_lease_test.go` x6, `fleet_atbox_test.go` x2, `crosstenant_test.go:115`,
   `role_group_test.go` x2, `wui_active_agent_test.go:129`.
   `git grep -nE 'func \([^)]*\) CASFleetLease\(' 86babad74 -- '*.go'` -> exactly the 2
   implementations, no third type.
3. **Section 5 brief runnable:** `command -v go` -> `/usr/local/go/bin/go`;
   `csi-spl-api/src/bash/tests/run-all-tests.sh` exists;
   `PRE_PUSH_TIER` is a documented param of `do_check_pre_push` (`fast|full`,
   `check-pre-push.func.sh:76` and `:1437-1439`), so
   `cd csi-spl-iac && PRE_PUSH_TIER=full ./run -a do_check_pre_push` runs (the store
   tier, deploy gate (b)). The `go test -count=1 ./internal/store/ ./internal/hub/
   ./internal/cleancode/` gate is runnable as written; I did not run the Go tests
   myself (docs/review only) — the row lane runs them.

### Gate claims (1.5) verified on `86babad74`

`cleancode_test.go`: `maxParams = 7` at `:20`, `maxParamsListed = 8` at `:23`,
`wideFuncs` at `:41-48` with 6 entries, the CASFleetLease pair at `:42-43`, and the
stale-key `t.Logf("wideFuncs: %q no longer takes more than %d parameters - delete its
line", ...)` at `:100-101` — a listed function dropping under 7 only logs, never fails.
The interface at `fleet_lease.go:48` takes 8 parameters with `ctx`. Row 03's change
(one `FleetLeaseCASReq`, 3 params) drops the pair under 7 and removes its 2 lines;
section 6's count 6 -> 4 holds.

### R3 on the 9 row-03 paths

`lane-map.sh --check <9 paths> --agent m-977` -> **exit 4**: no live lane lists them;
11 lanes record no files (all on the other box: c-049, c-060, c-414, c-439, c-443,
c-452, c-459, c-470 (the live r67-01 row lane, iac scope), c-812, c-924, c-927) —
ask first, not free; the holder's R3 re-check before the spawn governs.
`git log origin/master --since="$W" -- <9 paths> | wc -l` -> **0**; newest change of
each matches the plan's 2.2 list (`6e799033c`, `b45e54ddc`, `5d4d08910`, `9bae5ff35`,
`673045866`, `ffa109b34`, `f8677d1e5`).

### Row shape

Row 03: practice the Go clean-code gate (`wideFuncs` ratchet only shrinks), a red
control (3 outputs: struct in + gate lines kept -> the 2 `no longer takes more than 7`
LOGs; lines dropped -> no such log; one implementation back at 8 parameters with the
lines dropped -> the gate FAILS `takes 8 parameters (> 7)`), a test list (1.5), vendor
**claude**, kind **simple_coding**, batch 1 beside row 01 — no mistral coding or
testing row; R7 reviewers unchanged (cross-vendor first, never mistral). 3 rows is
rulebook 5.1's cap (at most 3).

## Defects on v1.1

W1..: none.

## Notes on v1.1

- N6: `38b7f1596` is origin/master HEAD at my read; the diff base `ca05e75b3` is the
  v1.0 that folded my v0.1 PASS (its section 9 records it, spool msg 3e1c0744, seat
  `e3f3bebbd`).
- N7: lane-map exit 4 now lists 11 unknown lanes (8 at my v0.1 read) — live state
  moved; c-470@<box2> is the live r67-01 row lane, its scope is the iac paths,
  disjoint from row 03's api paths.
- N8: the SC2154 change in `tf-state-push.func.sh` is a count edit on an existing
  baseline line, not a new line, so section 6's 86 -> 82 still holds; verified with
  shellcheck 0.10.0 before/after deleting `:27` (above).
- N9: go is present on this box, so the section-5 gates are runnable as written; the
  Go tests themselves are the row lane's to run, not this seat's.

## Seat state

Verdict reports sent on task `dispatch-refactor-r67` (kind result): v0.1 PASS at
2026-11-19T15:04Z to c-443@<box> and the then-holder c-002@<box> (msg 3e1c0744,
c0e3a9b7); v1.1 PASS after this commit, same form, to c-002@<box> on the relay task
and c-443@<box> on `dispatch-refactor-r67`. This seat waits for a message on that
task whose body starts with ACCEPTED from c-443 or the dispatch holder; until then
no /exit-clean. Branch `review/c002-refactor-round-67-mistral-seat` holds both
commits.
