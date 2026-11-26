# Bug round 49: claude panel seat verdict on plan v0.1

Seat: **c-896@sat** (claude, cross-vendor panel, rulebook 3.2). Plan:
`csi-spl-doc/doc/md/bug-round-49-plan.md` v0.1 on
`review/c002-bug-round-49-planner`. Rules: [rounds-rulebook.md](../rounds-rulebook.md).
Task: `dispatch-bug-r49`. Issue: SPL-6554 (epic SPL-2402).

**Sha read:** `0dfecbb3ea8660d4789f6ba239f6b55e3adb3cd4` (`git ls-remote origin refs/heads/review/c002-bug-round-49-planner`
printed that sha; the editor a-895@sat named it v0.1, msg `5f0fb818`). Its parent is `874d1b2f4`
(`origin/master` at review time); its plan base is `0d5e0b252`. Every repo command below ran
on `0d5e0b252` (this seat's worktree HEAD) or on the plan sha, 2026-11-26 03:30Z..03:50Z, on sat,
as the seat's own OS user, n=1 per command unless stated.

## Verdict: **FAIL** on `0dfecbb3`

Rows b49-02 and b49-03 are real defects on the tree, and their red controls fail for the
reasons the plan gives. Row b49-01 is not: the colon-less pinned placement that its red control
plants cannot reach `spl_spawn_place_pin_hold`, because the hub's database, the hub API and the
enqueue action all refuse it (W1). Dropping b49-01 leaves 2 rows, which is what rulebook 5.1 aims at.
W2 is an R2 gap in two test columns. Fold W1 and W2 into v1.0 and this seat signs it.

## 1. Checks, with the command and what it printed

### 1.1 Slug `b49` unused since `W=2026-11-26T05:15:24+02:00`

- `git log origin/master -1 --format='%h %cI %s' -E --grep='^docs\(b48-plan'` ->
  `0d5e0b252 2026-11-26T05:15:24+02:00 docs(b48-plan, SPL-6544): bug round 48 plan records the round closed, rows 01-03 landed`: W is right.
  `git merge-base --is-ancestor 0d5e0b252 origin/master` -> rc 0.
- `git log origin/master --since="$W" --oneline -E --grep='\(b49-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'b49-[0-9]{2}|bug-round-49'` -> only
  `0dfecbb3... refs/heads/review/c002-bug-round-49-planner` (the planner's; this seat's branch did not exist yet).
- `git ls-remote origin 'refs/heads/review/b49-*' 'refs/heads/wip/*b49*' 'refs/heads/*-b49-*'` -> nothing, rc 0.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b49-[0-9]{2}|bug-round-49'` ->
  `c002-bug-round-49-claude-panel-seat.md`, `hand-sat-c002-bug-round-49-planner.md`: the two expected.

### 1.2 Sites exist on the base and on `origin/master`

- `git diff --name-only 0d5e0b252 origin/master -- <the 6 row files>` -> empty, rc 0
  (`origin/master` = `874d1b2f4`, one docs commit past the base). **0 drift.**
- Each cited line read with `git show 0d5e0b252:<file> | sed -n <N>p`; all match the plan:
  - `spl-spawn-place.func.sh:1444` `spl_spawn_place_pin_hold() {`; `:1448` `while IFS=$'\t' read -r id vendor slug; do`;
    `:1449` `mapfile -t ps < <(spl_spawn_place_slug "$slug")`; `:1451` `[[ -n "$box" ]] || continue`;
    `:1464` the `jq` line with `else "" end`. `:1384` and `:1508` are the sibling `IFS=$'\t'` loops; their `jq`
    lines (`:1540` for the second) select `test("^(mistral|agy):")`, as the plan says.
  - `spl-spawn-queue.tst.sh:2603` opens section 44 (SPL-6539); `:2668` is `seat_clear`, the section's end (the file has 2673 lines).
  - `spl-customer-box-role-check.func.sh:49` `local d="${CUSTOMER_BOX_ROLE_DIR:-...}"`; `:69`, `:115`, `:138` the three
    `${...#"$d"/}` strips; `:145` `spl_cbr_when_false`'s `grep -rniE "^[[:space:]]*when:..."`; `:151` `r4="$1/roles/04_desk_start_checks"`;
    `:154-156` the three `^[[:space:]]*` patterns; `:157` `sort -u`.
  - `customer-box-role-set.tst.sh:140-143`: the comment control and the `changed_when: false` control.
  - `y9-vendor-lane-rule.sh:62-89`: `_y9_qwen` (28 lines). `:67` `msg="$(_y9_one ... 2>&1; echo "rc=$rc")"`;
    `:70` the 4-substring `case`; `:74-77` the `while [ -e ]` loop and `cp -p`.
  - `y8-vibe-agents.py:52-68`: `backup_stamped`, `O_CREAT | O_EXCL` mode `0o600`, `k` in `range(1, 100)`, `sys.exit("... no free backup name ...: nothing replaced")`.
  - `test-agy-qwen-fleet-rules.sh:98`: `echo "== y9 agy + qwen fleet rules: ..."` (the file has 100 lines).
  - `spl-review-go.func.sh:662` `IFS=$'\037' read -r a where`; `:684-685` "Backticked spans stay"; `spl-review-go.tst.sh:111-114` case 24 ("a backticked prd step ... -> rc 4").

### 1.3 Red controls: read, hashed, run on the base

I extracted them from the plan at `0dfecbb3` (plan lines 126-211, 226-326, 341-487) into a scratch dir:

| control | `sha256sum` | `wc -c` | plan says |
|---|---|---|---|
| `rc01-b49.sh` | `f6fce61785cfc92b9ce21c89bb8433afa144fe5293c38f0ad0c4b59496a993e5` | 4668 | `f6fce61785cf`, 4668 B |
| `rc02-b49.sh` | `5509c3f13d9b8aa10ac94a8729a8f9b7f2873db18f04bfbaa30492b860160dd5` | 5523 | `5509c3f13d9b`, 5523 B |
| `rc03-b49.sh` | `e474daac0f091c9181128580f431a401dfc4343b986cc71cf268f05abcd7f4e8` | 7052 | `e474daac0f09`, 7052 B |

Run from this worktree (`bash <rc> 0d5e0b252`, then with `fix-shape`), last line and exit code:

| run | last line | exit |
|---|---|---|
| `rc01-b49.sh 0d5e0b252` | `rc01 exit 1` (A: `left=1 (want 0) pick='' (want ':0,')`; B, C, D pass) | 1 |
| `rc01-b49.sh 0d5e0b252 fix-shape` | `rc01 exit 0` (A: `left=0 pick=':0,'`) | 0 |
| `rc02-b49.sh 0d5e0b252` | `rc02 exit 1` (5 list-dash cases `rc=0 hits=0`; `trailing_slash refused_total=2`) | 1 |
| `rc02-b49.sh 0d5e0b252 fix-shape` | `rc02 exit 0` (all 5 `rc=1 hits=1`; `refused_total=1 clean_rel=1`) | 0 |
| `rc03-b49.sh 0d5e0b252` | `rc03 exit 1` (A `stderr_has_cause=0`; B `rc=0 created_100=1 msg=0 file_kept=0`; C passes) | 1 |
| `rc03-b49.sh 0d5e0b252 fix-shape` | `rc03 exit 0` (A `stderr_has_cause=1`; B `rc=1 created_100=0 msg=1 file_kept=1`) | 0 |

Every line printed equals the plan's section 4 tables.

**Live state.** I read all three. Each `git archive`s its tree into `mktemp -d`, removed by an
`EXIT` trap. rc01 runs `spl_spawn_place_pin_hold` under `SPOOL_TEST=1` and a throwaway `SPOOL_ROOT`,
with `spl_spawn_place_pick_out`, `_wait`, `_wait_keep`, `_seats` and `do_log` stubbed. rc02 runs the check
on a copy of the role set. rc03 runs the step with `HOME` set to a temp dir (`$tmp/h1..h3`), and puts a
stub `date` on `PATH` in case B only. None touches the checkout, the live spool, `~/.qwen` or the hub.

**Fails for the planned reason.** rc02 and rc03: yes, the failing cases are the defects of 3.2 and 3.3.
rc01: it fails for the reason it states, on an input the live system cannot produce (W1).

Baseline suites on `0d5e0b252`:

- `bash csi-spl-iac/src/bash/tests/customer-box-role-set.tst.sh` -> `--- customer-box-role-set: 0 failure(s)`, rc 0.
- `bash csi-spl-orc/src/bash/features/spool-install/tests/test-agy-qwen-fleet-rules.sh` -> `== y9 agy + qwen fleet rules: 18/18 passed`, rc 0.
- `SPOOL_TEST=1 env -u SPOOL_BOX_TAG -u SPOOL_AGENT_ID bash csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh </dev/null` -> `PASS: all`, rc 0 (7m00s).

### 1.4 The defects, read on the tree

- **b49-01: not reachable (W1).** The account of `:1448`/`:1464` is right as shell: a row with
  `.placement` non-empty and colon-less gives `vendor=<slug>`, `slug=""`, and is skipped. But no such row reaches
  the function:
  - `spl_spawn_place_mark` (`spl-spawn-place.func.sh:326-336`) sets `_l` only for `select((.placement // "") != "")`
    whose brief exists, and `pin_hold` reads only `select(.state == "queued" and ._l)` (`:1464`).
  - The rows come from the hub only: `[[ "$LANE_MODE" == hub ]] || ...` (`:262`), `rows="$(spl_spawn_q_rows)"` (`:271`).
  - A non-empty placement must be `<vendor>:<slug>` at three layers:
    `csi-spl-rdb/src/sql/postgres/spool-hub/0180_fleet_asks_queue.sql:27-28` `CHECK (placement ~ '^([a-z]{2,16}:[a-z0-9][a-z0-9._-]{0,63})?$')`;
    `csi-spl-api/src/go/spool-hub-api/internal/store/fleet_ask.go:132` `AskPlacementRe` (the same regex), enforced at
    `internal/action/ask.go:180` and `internal/hub/box_ask.go:377`; and
    `csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh:220-221` (`FATAL SPAWN_PLACE must be <vendor>:<slug>`), in
    `spl_spawn_q_enqueue`, "the one path every queue row takes" (`:214`).
  - With `placement == ""` the row is not `_l`, so it never reaches `pin_hold` either; even if it did, the line is
    `<id>\t\t` and both later fields are empty, the same as the fix gives.

  So the `else ""` branch at `:1464` is dead on real data, and rc01's row `"hand-boxa-colonless"` is one the hub refuses with
  a 400 and the database with a CHECK violation. A pinned `hand-<box>-` row always arrives as `<vendor>:hand-<box>-...`
  (rc01 case C), which holds today. The plan's "a colon-less pinned row therefore never holds" (3.1) is true of the
  function in isolation, not of the placer.
- **b49-02: real.** `- ignore_errors: true` (and the other 4 list-dash forms) is a valid Ansible task start that
  `^[[:space:]]*(ignore_errors|failed_when|when):` does not match: rc02's 5 red cases. Fix scope is narrow (one strip at `:49`,
  one optional group in 4 patterns). The trailing-slash half is cosmetic: by hand on `0d5e0b252` (role 04 plus
  `  ignore_errors: true`, `CUSTOMER_BOX_ROLE_DIR=<T>/s/`) the check printed
  `REFUSED swallow-error: roles/04_desk_start_checks/tasks/main.yml:5:  ignore_errors: true` and
  `REFUSED swallow-error: <T>/s/roles/04_desk_start_checks/tasks/main.yml:5:  ignore_errors: true`, then FATAL, rc 1: the
  verdict is already right; only the output repeats (N2). The control turns green on a fix of the planned shape.
- **b49-03: real (A), hardening (B).** `:70` prints a failing part's output only when it holds one of 4 strings, so
  a `UnicodeDecodeError` (or y8's own `no free backup name`, which holds none of the 4) ends the step with rc 1 and no
  message: rc03 A. Case B (99 names taken within one UTC second) only happens when the names are planted; on the base the
  step then writes `-100` and replaces the file with that backup kept, so nothing is lost (N3). Fix scope is narrow
  (one function plus a helper). The control turns green on a fix of the planned shape.

### 1.5 Rows: fields, vendors, R1, R2

- Each row has a control that fails today and passes on the fix shape, a test column, vendor claude, kind
  `simple_coding`, batch 1, R7 agy else the claude waiver seat (`1a7c70da`). No mistral coding, testing or review seat.
- R1: the six row files are distinct (plan section 5), all Batch 1.
- R2 test columns, against `git grep -l <site basename or function> 0d5e0b252 -- '*test*' '*.tst.sh'`:
  - `spl-spawn-place.func.sh` -> 8 files: `lane-rotate.tst.sh`, `spl-box-cordon.tst.sh`, `spl-box-pick.tst.sh`,
    `spl-spawn-place-argmax.tst.sh`, `spl-spawn-place-owner-prio.tst.sh`, `spl-spawn-place-supply.tst.sh`,
    `spl-spawn-queue.tst.sh`, `spl-spawn-review-notify.tst.sh`. The b49-01 column names 2 (W2).
  - `y9-vendor-lane-rule|_y9_qwen|spool_install_vendor_lane_rule` -> `test-agy-qwen-fleet-rules.sh`,
    `test-agy-rules-always-on.sh`, `test-vibe-agents.sh`, `test-y14-agy-exit-rule.sh` (`:96` greps the y9 line of
    `install.sh`). The b49-03 column lacks `test-y14-agy-exit-rule.sh` (W2).
  - `spl-customer-box-role-check|do_spl_customer_box_role_check|spl_cbr_` -> `customer-box-role-set.tst.sh` only: the
    b49-02 column is complete.
  - Every other test path in the three columns exists on `0d5e0b252` (`git cat-file -e`, 9 of 9 OK).

### 1.6 R3

`lane-map.sh --check <the 6 row paths> --agent c-896` (03:4xZ) -> **exit 4**: no live lane lists any of the 6 paths;
16 live lanes on `<box2>` record no files (`unknown:` c-029, c-041, c-086, c-146, c-187, c-398, c-407, c-416, c-474,
c-535, c-728, c-927, c-935, c-936, c-957, c-965). The plan's 03:22Z read named 15; `c-935` is new. Not free until the holder
re-runs `--check` at placement, as the plan says. The live and queued lanes the plan names (section 5 R3, section 6) are
not shown touching any row file.

### 1.7 Inputs accounted for

- Round 48 section 7's first inputs: each is a row (a-801 N1 -> b49-01, a-748 N3-N4 -> b49-03), left to a live lane
  (a-767 N2, a-823 N2, a-826 N2 -> SPL-6517), or carried by name to round 50 (plan sections 3.6 and 7). None is missing.
- Candidate list `/var/spool-hub/dispatch/c002-next-round-candidates.md`: `wc -l` -> 142; `:141-142` (review-go false
  holds) accounted in 3.6 with the case-24 conflict; the earlier lines were accounted by rounds 40 to 48.
- prd ERROR, `ENV=prd SEVERITY=ERROR FRESHNESS=8h LINES=1000 FORMAT=json ./run -a do_gcp_tail_logs` (csi-spl-iac,
  03:4xZ): 13 entries in 8 h, **0 since W**, 2 since 01:28:36Z (01:39:34Z Cloud Run 503, 02:56:41Z `operator does not exist:
  uuid ~~ unknown`), as the plan says (N4).
- prd alerts, `ENV=prd SINCE=8h ./run -a do_gcp_list_alert_incidents` -> `== incidents ... none`, rc 0.
- Open bug issues, `do_spl_db_query` SELECT of the plan's section 2 row 3 (minus two columns) -> 6 rows: SPL-6361, 6362,
  6366 `wip`; 5911, 5254, 4994 `onhold`, as the plan says.
- CI: `gh run list --branch master --status failure --limit 30 ...` filtered to `createdAt >= 2026-11-26T01:28:36Z` ->
  none; the newest wf 10 (`874d1b2f4`, 03:33:39Z) `success`.
- R7 notes: `git log --format=%B 8483a5d02..0d5e0b252 | grep -c '^review: '` -> **7**, not 6 (plan section 2 row 7 and
  section 7). The 7th is `a-835` on `7e7962df5` (SPL-6542, WUI notes); its W1 and N1-N3 are folded or answered in that
  commit's body, so no bug input is lost (N1).
- Row count: 3 meets 5.1's cap; with W1 applied it is 2, the aim.

### 1.8 Hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/c-896`, rc 0.

## 2. Defects

- **W1 (b49-01, plan lines 53-60, 126-219, row 01 of section 5).** The defect cannot happen in the placer: a
  non-empty colon-less placement is refused by the database CHECK (0180), the hub API (`AskPlacementRe`) and
  `spl_spawn_q_enqueue`, and an empty one is never `_l` (1.4). Drop b49-01 from this round (carry it as hardening, if at
  all), or re-justify it with a real path that produces such a row, and change 3.1's "never holds" to say so. The round
  then has 2 rows (5.1's aim) and sections 2 row 9, 3.6, 5, 7 and the title change with it.
- **W2 (R2, section 5 test columns).** b49-01 names 2 of the 8 tests that name `spl-spawn-place.func.sh` (missing
  `lane-rotate`, `spl-box-cordon`, `spl-spawn-place-argmax`, `spl-spawn-place-owner-prio`, `spl-spawn-place-supply`,
  `spl-spawn-review-notify`, all `.tst.sh`); moot if W1 drops the row. b49-03 lacks
  `csi-spl-orc/src/bash/features/spool-install/tests/test-y14-agy-exit-rule.sh`.

## 3. Notes

- **N1.** Section 2 row 7 and section 7 say 6 `review:` lines in `8483a5d02..0d5e0b252`; it is 7 (`a-835` on `7e7962df5`).
- **N2 (b49-02, plan 3.2 item 2).** On a trailing `/` the second line keeps the whole absolute path, not "a leading `/`",
  and `:69` and `:115` do the same; the check already refuses (rc 1). The fix at `:49` covers all three. Say it is output
  only.
- **N3 (b49-03, plan 3.3 item 2).** The base never loses data in case B (it writes `-100`, keeps it, then replaces);
  call it parity with `y8-vibe-agents.py:52-68`, not a race that loses a file. The `:67` "later passing parts look
  non-zero" changes no outcome (the step's `rc` is already 1). rc03's header cites `y8-vibe-agents.py:56-68`; the
  function is `:52-68`.
- **N4.** `uuid ~~ unknown` appears 3 times in 8 h (21:51:35Z, 22:41:10Z, 02:56:41Z), as `spool_hub_rt`;
  `git grep` finds no code LIKE on a uuid id column, so "ad-hoc SQL" stands, but it repeats: worth a line in 3.5.
- **N5.** At placement the holder re-runs R3 (exit 4 here, 16 unknown lanes).
