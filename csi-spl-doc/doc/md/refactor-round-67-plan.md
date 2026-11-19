# Refactoring round 67 - plan (3 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5969  
Topic: 95ef4159-71dd-418c-b1fb-7f17eb4d24c3  
Discussion: 95ef4159-71dd-418c-b1fb-7f17eb4d24c3 (t1 #refactoring, "Refactor round 67", opener msg 3b311cbd)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r67**, plan `refactor-round-67-plan.md`, rows `r67-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 66 ([refactor-round-66-plan.md](refactor-round-66-plan.md))
is served: r66-01 landed `b576da5e5` (SPL-5965), r66-02 landed `ffd7d6a72` (SPL-5967).
So r67 carries no signed row: a fresh round. The perf floor (rulebook 4.4) read
`perf 29 refactor 96 perf-share 23.2% floor-met` on `1ce9158a1` (the holder's read), so
the next round is a refactor round.

r62 to r66 served **no literal box path** (developer guide 2.3.1) until one baseline
file was left, a deny list r66 ruled a behaviour change (section 7). This round takes
the next ratchet with refactor-shaped entries: the shellcheck WARNING baseline
(`.shellcheck-warning-baseline.txt`, developer guide 2.4.3), the practice of r42-05,
r42-07, r43-01 to r43-03 and r59-03. Both rows remove a variable shellcheck reports as
assigned and never read (SC2034) in `csi-spl-iac`, and drop its baseline line.

**Status: v1.1, row 03 waits for its signature**: panel seat m-977 (mistral) PASS on
v0.1 `7c4e9b38f`, no W, notes only (sections 8 and 9); rows 01 and 02 are unchanged and
stay signed. v1.1 adds **row 03** (section 1.5), cut at the holder's ask (c-002@sat msg
a82a13e5: the refactor share is UNDER its 24 h band; a row off the shellcheck baseline
can place now, not after r67-01). Row 03 places once a panel seat signs v1.1 (rulebook
3.2). Editor: **c-443** (claude).

**Row 03's sha:** its counts are measured on **`86babad74`** (`origin/master`
86babad740abe0e10f6f1be9e2229454cf844558, committed 2026-11-19T16:12:22+01:00), n=1 per
command; rows 01 and 02 keep `1ce9158a1`.

**One sha:** every count is measured on **`1ce9158a1`** (`origin/master`
1ce9158a11d97bef5a57f0201bd2e651f63cac5f, committed 2026-11-19T16:07:51+02:00), n=1 per
command unless stated. Reads are on that sha with `git show` / `git grep`, and
shellcheck 0.10.0 on this lane's worktree at that sha. Queue, lane map and vendor
readings are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-19T14:04:01+01:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r66-plan'` -> commit
  `cb56a8993` "refactor round 66 plan records the v1.0 signature, m-391 mistral PASS on
  3d48fd2c4". Every later read of r67 uses this W.
- **`r67` is free** (2026-11-19T14:25:44Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r67-'` -> **0**.
  - `git ls-remote origin 'refs/heads/review/r67-*' 'refs/heads/wip/*r67*' 'refs/heads/*-r67-*'`
    -> **nothing** (rc 0).
  - `grep -rlE 'r67-[0-9]{2}' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote/briefs`
    (run as root) on this lane's box -> **0 files**. The other box's briefs were not
    read by this lane (the holder read them all 0 at 14:2xZ).
  - Control: the same log read for `r66` -> 5 lines (`7eb51eed8`, `1685fca04`,
    `cb56a8993` the plan, `b576da5e5` r66-01, `ffd7d6a72` r66-02), so the read sees a
    used id.
- **No `refactor-round-67*` file** exists under `csi-spl-doc/doc/md` on `1ce9158a1`
  (`ls csi-spl-doc/doc/md | grep -c refactor-round-67` -> 0), so the plan takes the
  plain name (5.3 "Files").

### 1.2 The candidates, re-measured

| input | source | on `1ce9158a1` | here |
|---|---|---|---|
| `no-literal-paths.baseline` | the brief | `git show 1ce9158a1:csi-spl-orc/src/bash/tests/no-literal-paths.baseline \| grep -vE '^\s*(#\|$)'` -> **1 line**, `2 ...spl-file-erase.func.sh`; the non-test `*.sh` literal scan (`git grep -nE '/(opt\|var)/csi($\|[^A-Za-z0-9_-])' 1ce9158a1 -- '*.sh' ':!**/tests/**'`) -> its 2 lines (`:31`, `:120`) only | left out (section 7) |
| r66-02 R7 N1: a shallow `APP_PATH` gives `SPL_VAR_ORG_DIR=/var/` | the brief (land report 43ab3767) | `orclib:spl-run-paths.func.sh:69,72`: `org="${main%/*}"; base="${org%/*}"`, `${base%/*}/var/${org##*/}`; a `main` of one path part leaves `org` and `base` empty, so the var reads `/var/`. A refusal there changes behaviour | left out, a bug row (section 7) |
| r66-02 R7 N2: `FATAL no cargo` swallowed by the `$(...)` capture | the brief | `orc:run/spl-cmd-guard-mode.func.sh:42` logs to stdout, and `:72` calls `bin="$(_scg_build)"`, so the line lands in `bin`; `:39` (the rust-home FATAL) already writes `>&2`. Moving the line to stderr changes what the operator sees | left out, a bug row (section 7) |
| `action-header-tags-baseline.txt` `[missing]`: 9 files | the action header practice of r58-05 to r59-05 | `grep -ciE '^# *@param.*\(required\)'` -> 1..3 in each of the 9; neither the iac nor the orc `do_parse_metadata` reads their header today (`grep -c '^param=.*(required)'` -> 0 for each orc file), so a parsed header turns on `do_validate_params` (rc 11 before the body) | left out (section 7): rounds 20, 27, 28, 29 and 34 ruled the same |
| `action-header-tags-baseline.txt` `[long-example]` and `bash-cleancode.tst.sh` `LONG`: `iac:run/provision-firebase-dns.func.sh` (one 169-line function) | the two ratchets | `iac:tests/wui-hosting-019-031.tst.sh:28-30` pins the file **byte-identical** to the upstream port it came from (`want_sha`) | left out (section 7) |
| `.shellcheck-warning-baseline.txt` | the ratchet (2.4.3) | `grep -vcE '^\s*(#\|$)'` -> **86 lines**: SC2034 41, SC2154 20, SC2120 7, SC1090 5, SC2088 4, SC2046 3, SC2319 2, SC2164 2, SC2155 2 | **rows 01 and 02** (1.3), the rest section 7 |
| Go clean-code gate `wideFuncs` (`api:internal/cleancode/cleancode_test.go:41-48`) | v1.1, a ratchet off the shellcheck baseline | 6 lines: 3 Memory / Postgres pairs over `maxParams` 7 (`:20`), `CASFleetLease` 8 (with `ctx`), `MoveMessage` 9, `MergeTopic` 9; `go test -count=1 -run . ./internal/cleancode/` -> PASS on `86babad74` | **row 03** takes `CASFleetLease` (1.5); the other 2 pairs section 7 |
| WUI clean-code gate `WIDE` (`csi-spl-wui/tests/unit/cleancode.test.mjs:47-49`) | v1.1 | 1 entry, `src/stores/channel.ts send` (6 params); its `LONG` map is empty | left out (section 7) |
| the dispatcher's candidates file (`/var/spool-hub/dispatch/c002-next-round-candidates.md`) | the brief | on the other box; this lane could not read it (`ls` -> No such file on this box) | the holder checks it for a refactor-shaped item (section 7) |
| spec 011 tasks | the brief | the spec folder unchanged since W (`git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor` -> 0) | left out (section 7), r65 and r66's reasons hold |

### 1.3 The SC2034 sites in `csi-spl-iac`

`shellcheck -S warning -i SC2034 -f gcc <file>` on the 10 iac files the baseline lists
under SC2034 -> 10 warnings, one per file. Six are a variable no code reads; four are
read by sourced code or are a dead guard, so they stay:

| file:line | variable | read anywhere? | here |
|---|---|---|---|
| `iac:run/gcp-backup-env.func.sh:149,153` | `i`, the counter of the proxy wait loop `for i in $(seq 60)` (declared in `:149`'s `local` list) | the loop body never reads it | **row 01** |
| `iac:run/satellite-verify.func.sh:121` | `d`, in `local script here there name hv sv d` of `_satellite_verify_replica` | `grep -nE '\bd\b'` in the file: `:121` is the only hit in that function | **row 01** |
| `iac:run/tf-init.func.sh:10` | `tgt_app=${APP:?}` | `git grep -n tgt_app 1ce9158a1 -- 'csi-spl-*'` -> **1** line, this one. The `${APP:?}` stops the action when `APP` is unset: that check stays | **row 01** |
| `iac:run/tf-state-push.func.sh:27` | `vars_path="${tf_vars_path:-...}"` (a global; `state push` takes no var file) | the 8 other `tf-*.func.sh` that write `vars_path` assign it before they read it (`git grep -nE '^\s*vars_path='` -> 9 files, these 8 and this one), and `tf-import.func.sh:17` declares its own `local` | **row 01** |
| `iac:tests/adhoc-harvest-gcp-actions.tst.sh:25` | `RUN="$PROJ_ROOT/src/bash/run"` | `grep -n '\bRUN\b'` in the file -> only `:25` | **row 02** |
| `iac:tests/sec-gosec.tst.sh:38` | `F="$ROOT/csi-spl-api/src/go/spool-hub-api"   # path fragment ...` | `grep -nE '\$F\b\|\$\{F\}'` in the file -> 0 | **row 02** |
| `iac:tests/workflow-tool-checksums.tst.sh:33` | `naked=$(grep ... curl .*releases/download/ ...)` | computed and never asserted: the comment above it says it guards a raw `curl` of a release asset, but no check reads it | left out: a dead guard, a bug row (section 7) |
| `iac:tests/check-pre-push.tst.sh:53`, `iac:tests/check-weekly-full-scan.tst.sh:29` | `APP_PATH=` | set before the action under test is sourced, for it to read | left out (section 7) |
| `iac:tests/satellite-actions.tst.sh:46` | `GCP_ACCOUNT=` in a `do_gcp_pin_account` stub | a stub that plays the pin, for the sourced action to read | left out (section 7) |

The gate: `do_sec_shellcheck` (`iac:run/sec-shellcheck.func.sh:175-181`) holds the
count per (code, file) **equal** to the baseline: a new pair fails, and so does a count
below its line ("a count below its line fails too", the baseline's header). So each row
drops its baseline lines in the same commit, and the red control is that drop left out.

### 1.4 The tests (R2, C4)

`NAMES` = the row's basenames:
`pat=$(for n in $NAMES; do printf '%s' "|\b$n(\.sh|\.tst\.sh|\.func\.sh)?([^a-z0-9_-]|\$)"; done); git grep -lE "${pat#|}" 1ce9158a1 -- 'csi-spl-orc/**/tests/*' 'csi-spl-iac/**/tests/*' 'csi-spl-utl/**/tests/*' 'csi-spl-api/**/tests/*'`

- r67-01 (`gcp-backup-env satellite-verify tf-init tf-state-push`) -> **13** files:
  iac `adhoc-harvest-gcp-actions`, `env-order-gate`, `gcp-key-path-no-eval`,
  `satellite-actions`, `satellite-ansible`, `setup-tf-mirror`,
  `tenant-host-workflow-40`, `tf-init-project-key`, `tf-plugin-cache-shared`,
  `tf-state-actions` (`.tst.sh`); orc `box-name-from-cnf`, `tf-destroy-make-dry-run`,
  `tf-plan-ref` (`.tst.sh`). Function names
  (`git grep -lE 'do_gcp_backup_env|_satellite_verify_replica|do_satellite_verify|do_tf_init|do_tf_state_push' 1ce9158a1 -- '*tests/*'`)
  -> 20 files, adding iac `billing-sa-step`, `gcp-tf-shared-bodies`,
  `provision-052-entry-check`, `tf-actions-tf-proj-after-init`,
  `tf-apply-destroy-quoted-paths`, `tf-apply-exit-status`, `tf-apply-no-input`,
  `tf-destroy-local-step-bucket`, `tf-destroy-target`, `tf-import-result-log`,
  `tf-log-mask-billing-id`, `tf-state-remove-backup` and orc
  `tf-030-import-existing-cloud-run`. The lane runs
  `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` for the iac ones and the 4 orc
  files by name.
- r67-02 (`adhoc-harvest-gcp-actions sec-gosec`) -> `sec-gosec.tst.sh` (it names its own
  basename); the column is the two test files themselves.
- Both rows, the gate's readers of the baseline
  (`git grep -lF '.shellcheck-warning-baseline' 1ce9158a1 -- '*tests/*'`):
  `sec-shellcheck.tst.sh`, `sec-shellcheck-par.tst.sh`, `check-pre-push-lint.tst.sh`,
  `action-header-tags.tst.sh` (iac). The first three write their own fixture baseline
  (`:29`, `:28`, `:126`); the last names the file in a comment (`:13`). None reads the
  real lines.
- R2 bullet 2, a 30-character string of each changed line, in any `csi-spl-*` tests dir
  (`git grep -lF '<string>' 1ce9158a1 -- 'csi-spl-*/**/tests/*'`): `tgt_app`,
  `tf_proj=${STEP:?}`, `vars_path="${tf_vars_path:-`, `backend_config_path="$APP_PATH`,
  `(exec 3<>"/dev/tcp/127.0.0.1/$port")`, `local script here there name hv sv` -> **0
  files** each. `F="$ROOT/csi-spl-api/src/go/spool-hub-api"` and `path fragment for`
  -> `sec-gosec.tst.sh` only (the site itself). `RUN="$PROJ_ROOT/src/bash/run"` -> 19
  files, each its own line in its own test (none reads `adhoc-harvest-gcp-actions`'s).
- The gate itself: `cd csi-spl-iac && ./run -a do_check_pre_push_lint` (its
  `lint-shellcheck` part, touched files) and the CI workflow
  `.github/workflows/67_shellcheck.yml`.

### 1.5 Row 03: the `CASFleetLease` pair (v1.1)

Paths: `api:` = `csi-spl-api/src/go/spool-hub-api/`.

- **The gate:** `api:internal/cleancode/cleancode_test.go` fails a function over
  `maxParams` 7 (`:20`) unless `wideFuncs` (`:41-48`) lists it (cap `maxParamsListed` 8,
  `:23`). A listed function that drops under 7 only LOGS `wideFuncs: "<key>" no longer
  takes more than 7 parameters - delete its line` (`:100-101`, `t.Logf`), so a stale
  line never turns the gate red.
- **The sites** (`git grep -nE '\bCASFleetLease\(' 86babad74 -- '*.go'`) -> **16 lines
  in 8 files**: the interface `api:internal/store/fleet_lease.go:48`, the two
  implementations `fleet_lease.go:86` (Memory) and `fleet_lease_postgres.go:64`
  (Postgres), one production caller `api:internal/hub/box_lease.go:98`, and 12 test
  calls: `internal/store/fleet_lease_test.go` (6), `fleet_atbox_test.go` (2),
  `crosstenant_test.go:115` (1), `internal/hub/role_group_test.go` (2),
  `wui_active_agent_test.go:129` (1). No other type implements the method (the grep
  finds no third `func (...) CASFleetLease`).
- **The change:** the 6 values after `tenantID` (`fleet, role, holder, box string;
  ifGen int64; now time.Time`) become one struct in `fleet_lease.go`, beside
  `FleetLease`, named as the store's other request structs (`DocNodeMoveReq`,
  `DocItemAddReq`, `DocItemMoveReq`): `FleetLeaseCASReq`. The method takes
  `(ctx, tenantID string, r FleetLeaseCASReq)`: 3 parameters. `tenantID` stays
  positional, as on every store method (`inTenant`). The bodies read `r.Fleet` ...
  `r.Now` and do the same SQL and the same map write. The practice of r57-02
  (`359e51fa3`, mergePair inputs as structs) and r58-01 (`8a76f8180`, `IssueToken`
  takes one `auth.TokenIssue`).
- **The two `wideFuncs` lines** of the pair go in the same commit.
- **Tests:** `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 ./internal/store/ ./internal/hub/ ./internal/cleancode/`
  and `bash csi-spl-api/src/bash/tests/run-all-tests.sh`; the store tests run on
  Memory and on Postgres (`fleet_lease_test.go:12`, `crosstenant_test.go` is
  Postgres), so the row runs `cd csi-spl-iac && PRE_PUSH_TIER=full ./run -a do_check_pre_push`
  (the store tier, deploy gate (b)). No migration, no SQL text change.

## 2. The 3 rows

Paths: `iac:` = `csi-spl-iac/src/bash/`, `orclib:` = `csi-spl-orc/lib/bash/funcs/`,
`orc:` = `csi-spl-orc/src/bash/`, `base:` = `.shellcheck-warning-baseline.txt` (repo
root), `api:` = `csi-spl-api/src/go/spool-hub-api/`.

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r67-01-iac-shellcheck-unused-run)` | bash that fails safely (developer guide 2.4.3): the shellcheck WARNING ratchet only shrinks | four iac actions carry a variable shellcheck reports as never read; each is a baseline line that would hide a real new SC2034 in the same file | `iac:run/gcp-backup-env.func.sh:149,153`<br>`iac:run/satellite-verify.func.sh:121`<br>`iac:run/tf-init.func.sh:10`<br>`iac:run/tf-state-push.func.sh:27`<br>`base:` its 4 SC2034 lines | 4 files, 4 lines | `:153` `for _ in $(seq 60)` and `i` leaves `:149`'s `local` list; `:121` `d` leaves the `local` list; `:10` `tgt_app=${APP:?}` becomes `: "${APP:?}"` (the same stop when `APP` is unset, no variable); `:27` the `vars_path=` line goes (`state push` reads no var file). The 4 lines `SC2034\|<file>\|1` leave the baseline. **Red control:** the 4 sites fixed, the baseline left -> `do_sec_shellcheck` FAILS (a count below its line) for the 4 pairs; lines dropped -> PASS. **Behaviour:** `do_tf_init` with `APP` unset stops at `:10` before and after (same message, same rc): both outputs in the body. Tests: section 1.4 row 01 (`bash csi-spl-iac/src/bash/tests/run-all-tests.sh`; orc `box-name-from-cnf`, `tf-destroy-make-dry-run`, `tf-plan-ref`, `tf-030-import-existing-cloud-run`), `sec-shellcheck.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push_lint`. | either | claude | simple_coding | 1 |
| 02 `refactor(r67-02-iac-tests-shellcheck-dead-vars)` | as row 01 | two iac tests assign a path no line reads | `iac:tests/adhoc-harvest-gcp-actions.tst.sh:25`<br>`iac:tests/sec-gosec.tst.sh:37-39`<br>`base:` its 2 SC2034 lines | 2 files, 2 lines | the `RUN=` line goes from `adhoc-harvest-gcp-actions.tst.sh`; the `F=` line and one of the two blank lines around it go from `sec-gosec.tst.sh`. The 2 baseline lines go. **Red control:** as row 01, for the 2 pairs. Each test passes before and after with the same PASS count (its summary line), both in the body. Tests: `adhoc-harvest-gcp-actions.tst.sh`, `sec-gosec.tst.sh`, `sec-shellcheck.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push_lint`. | either | claude | simple_coding | 2 (after 01) |
| 03 `refactor(r67-03-api-fleet-lease-cas-req)` | clean code (developer guide, Go clean-code gate): the `wideFuncs` ratchet only shrinks | the Memory / Postgres `CASFleetLease` pair takes 8 parameters; 6 of them are one lease write, and the pair's 2 lines in `wideFuncs` let either grow to 8 again | `api:internal/store/fleet_lease.go:48,86`<br>`api:internal/store/fleet_lease_postgres.go:64`<br>`api:internal/hub/box_lease.go:98`<br>`api:internal/cleancode/cleancode_test.go:42-43`<br>(and the 12 test calls of 1.5) | 8 files, 16 call lines + 2 gate lines | `FleetLeaseCASReq{Fleet, Role, Holder, Box string; IfGen int64; Now time.Time}` in `fleet_lease.go`; the interface and both implementations take `(ctx, tenantID string, r FleetLeaseCASReq)`; `box_lease.go:98` and the 12 test calls build the struct; the 2 `wideFuncs` lines go. **Red control:** with the struct in, `go test -v -run . ./internal/cleancode/` LOGS the 2 `no longer takes more than 7` lines while the gate lines stay; lines dropped -> no such log; then one implementation put back at 8 parameters with the lines dropped -> the gate FAILS (`takes 8 parameters (> 7)`). All three outputs in the body. **Behaviour:** the same SQL text and arguments (`git diff` shows no change inside the query strings); the store and hub lease tests pass before and after with the same PASS list. Tests: 1.5. | either | claude | simple_coding | 1 (beside 01) |

**Re-measure first:** each row lane re-runs `shellcheck -S warning -i SC2034 -f gcc`
on its files and the baseline grep of 1.2 on the `origin/master` it starts from, and
says in its result if they moved.

**Subject** (R6 reads it): `<type>(r67-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r67-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** no documented behaviour changes: each row carries `Docs: none (<why>)`. The
baseline's header (the deliberate SC2034 cases) stays true: the iac cases left are the
ones it names, read by a sourcing caller or a test, plus the dead guard of section 7.

### 2.1 Batches (R1, R16)

- **Batch 1: row 01, and row 03 (v1.1).** Nothing either touches is held by a live or
  queued lane (2.2). Row 03 writes only under `csi-spl-api/` and shares no path with
  rows 01 and 02 (R1): it places as soon as v1.1 is signed, not after r67-01.
- **Batch 2: row 02, after row 01 lands**: both rows edit `base:`, so R1 serialises
  them. Queued as `SPAWN_AFTER=c003-r67-01-iac-shellcheck-unused-run`, within 30
  minutes (R16). Row 02 reads no code row 01 changes; the order is the shared file only.
- No row edits a migration, `csi-spl-cnf/`, a workflow, terraform or a file under
  `csi-spl-wui/`. Row 03 edits store code with no SQL change: the store tier still runs
  (1.5). Row 01 edits two terraform ACTIONS (`tf-init`, `tf-state-push`), no
  `.tf` file: no plan or apply runs, and the lane never runs `DRY_RUN=0` of either.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

The 7 written paths: `iac:run/gcp-backup-env.func.sh`,
`iac:run/satellite-verify.func.sh`, `iac:run/tf-init.func.sh`,
`iac:run/tf-state-push.func.sh`, `iac:tests/adhoc-harvest-gcp-actions.tst.sh`,
`iac:tests/sec-gosec.tst.sh`, `base:`.

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-443`, one call per
  path, 2026-11-19T14:29:53Z -> **exit 4** for each: no live lane lists any of them, but
  3 live lanes record no files: c-922 (WUI e2e CI red), c-946 (hub calendar, api
  `internal/hub/calendar*`), c-947 (bug round 21 row 02, landed `1ce9158a1`). Their
  scopes, from the planner brief: none writes a row path. n=1. The holder's R3 check
  before each row's spawn governs.
- **The live lanes the brief names** (14:2xZ): SPL-5963 hub calendar (api), SPL-5886
  spec 107 and T082 (api `hours_me.go`, spec 107), WUI blog share, WUI e2e CI red: api,
  wui and doc paths, none under `csi-spl-iac/` or `base:`.
- **Commits:** `git log origin/master --since="$W" -- <the 7 paths>` -> **0**. The
  newest change of each: `26d6690b1` (2026-11-15, `gcp-backup-env`, `tf-state-push`),
  `99119a3df` (11-17, `satellite-verify`), `2975facfa` (11-01, `tf-init`), `47f62ee2e`
  (10-15, `adhoc-harvest-gcp-actions`), `e3388fce3` (11-17, `sec-gosec`), `f24802938`
  (11-15, `base:`).
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 2026-11-19T14:28:10Z):
  **0 queued, 0 placing**. Live share `refactor 1 5% (band 10-20%: UNDER)`; last 24 h
  `refactor 11% (band 20-30%: UNDER)`; `phase day`.
- **Briefs on this lane's box** that name a row basename or the baseline
  (`grep -rlE 'gcp-backup-env|satellite-verify|tf-init\.func|tf-state-push|adhoc-harvest-gcp-actions|sec-gosec|shellcheck-warning-baseline'`
  over `/var/spool-hub/dispatch/briefs` and `/var/spool-hub/spawn-remote/briefs`, run
  as root, 2026-11-19T14:29:53Z): 8 files, the newest 2026-11-14T22:15Z, all older than
  W.
- **Unlanded round rows:** bug round 21 is served (`fee4cb861` b21-01, `1ce9158a1`
  b21-02); r66 is served. No open plan names a row path.

**Row 03 (v1.1), its 9 paths** (the 8 files of 1.5 and `cleancode_test.go`):

- **Lane map, every machine** (`lane-map.sh --check <path> --agent c-443`, one call per
  path, 2026-11-19T15:2xZ, n=1) -> **exit 4** for each: no live lane lists any of them;
  3 live lanes record no files: c-946@sat (WUI calendar, members' entries), c-981@sat
  (spec 107 T089 freeze sweep) and m-977@sat (this round's panel seat). None of their
  titles names the fleet lease, the box lease or the clean-code gate; the holder's R3
  check before the spawn governs.
- **Commits:** `git log origin/master --since="$W" -- <the 9 paths>` -> **0**. Newest
  change of each: `6e799033c` (10-30; `fleet_lease.go`, `fleet_lease_postgres.go`,
  `fleet_lease_test.go`), `b45e54ddc` (11-17, `box_lease.go`), `5d4d08910` (11-16,
  `cleancode_test.go`, r59-06), `9bae5ff35` (11-06, `fleet_atbox_test.go`),
  `673045866` (11-19 13:14+02:00, `crosstenant_test.go`, SPL-5945 migration 0296),
  `ffa109b34` (10-08, `role_group_test.go`), `f8677d1e5` (10-05,
  `wui_active_agent_test.go`).
- **`crosstenant_test.go` is a busy file:** each new tenant table adds its check there
  (the newest, `673045866`, before W). Row 03 changes its one line `:115`; the lane
  rebases on the newest `origin/master` before each push (R2).
- **Briefs on this lane's box** naming a row 03 file or `CASFleetLease`
  (`grep -rlE 'fleet_lease|box_lease\.go|cleancode_test\.go|CASFleetLease|crosstenant_test|role_group_test|wui_active_agent_test|fleet_atbox_test'`
  over `/var/spool-hub/dispatch/briefs` and `/var/spool-hub/spawn-remote/briefs`, as
  root, 2026-11-19T15:26Z): the newest 2 (11-18 20:30, 11-19 11:19 local) are R7 review
  seats of SPL-5913 and SPL-5945 that name `crosstenant_test.go` once, for a migration
  already on master; none names the lease or the gate lines.
- **Spawn queue** (`./run -a do_spl_spawn_queue`, 2026-11-19T15:26:55Z): **1 queued**,
  r67-02 (`c003-r67-02-iac-tests-shellcheck-dead-vars`), 0 placing. Live share
  `refactor 3 17% (band 10-20%: ok)`; last 24 h `refactor 11% (band 20-30%: UNDER)`.

## 3. Per row: what the lane does

- **r67-01:** four iac actions stop assigning a variable no code reads (`tf-init` keeps
  its `${APP:?}` stop as `: "${APP:?}"`); their 4 SC2034 baseline lines go.
- **r67-02:** after r67-01: two iac tests stop assigning a path no line reads; their 2
  SC2034 baseline lines go.
- **r67-03 (v1.1):** the store's `CASFleetLease` pair takes one `FleetLeaseCASReq`
  instead of 6 loose values; its 2 `wideFuncs` lines go. Same SQL, same answers.

## 4. Panel and reviewers (R7)

- Editor: c-443 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Vendor state** (2026-11-19T14:30:25Z, n=1 each, `BOX_PICK_KIND=<k> ./run -a do_spl_box_pick`,
  read on this lane's box): agy, mistral and claude `pick=` this box (56% < 70%); grok
  `pick=hold` (weekly 99% on both boxes). This box has an agy CLI
  (`command -v agy` -> found); the pick does not read agy's quota, so the holder knows
  whether agy is out.
- **Panel seat: requested of the dispatch lease holder** (task `dispatch-refactor-r67`):
  one **agy** doc seat, the main vendor for spec and plan reviews; mistral as its
  backup, as r62 to r66 had. The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2): agy if its pick still holds
  when the row is queued, else the holder's call (a fresh claude seat under the claude
  waiver, as r63 to r66). Not a mistral code R7. The holder re-reads the agy and grok
  picks before each row's reviewer is queued.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one
(rulebook 4.3), the sites and line numbers of 1.3, its R7 reviewer seat, and
"re-measure first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r67-01 | `c003-r67-01-iac-shellcheck-unused-run` | `refactor(r67-01-iac-shellcheck-unused-run, SPL-<row issue>): ...` | `review/r67-01` | 1 |
| r67-02 | `c003-r67-02-iac-tests-shellcheck-dead-vars` | `refactor(r67-02-iac-tests-shellcheck-dead-vars, SPL-<row issue>): ...` | `review/r67-02` | 2, `SPAWN_AFTER=c003-r67-01-iac-shellcheck-unused-run` |
| r67-03 | `c003-r67-03-api-fleet-lease-cas-req` | `refactor(r67-03-api-fleet-lease-cas-req, SPL-<row issue>): ...` | `review/r67-03` | 1, after v1.1 is signed; no `SPAWN_AFTER` |

**r67-01 brief, Files: ONLY** `iac:run/gcp-backup-env.func.sh`,
`iac:run/satellite-verify.func.sh`, `iac:run/tf-init.func.sh`,
`iac:run/tf-state-push.func.sh`, `.shellcheck-warning-baseline.txt` (its 4 SC2034
lines). Do: plan section 2 row 01 verbatim; red control the 4 sites fixed with the
baseline lines left (`do_sec_shellcheck` FAIL on the 4 pairs) then dropped (PASS), both
outputs in the body; `do_tf_init` with `APP` unset stops the same before and after.
Never `DRY_RUN=0`, never a terraform plan or apply. Gates:
`bash csi-spl-iac/src/bash/tests/run-all-tests.sh` (a test red on the parent too is
named, not fixed), orc `box-name-from-cnf`, `tf-destroy-make-dry-run`, `tf-plan-ref`,
`tf-030-import-existing-cloud-run`; `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

**r67-02 brief, Files: ONLY** `iac:tests/adhoc-harvest-gcp-actions.tst.sh`,
`iac:tests/sec-gosec.tst.sh`, `.shellcheck-warning-baseline.txt` (its 2 SC2034 lines).
Do: plan section 2 row 02 verbatim; red control as row 01 for the 2 pairs; each test's
PASS count the same before and after. Gates: `adhoc-harvest-gcp-actions.tst.sh`,
`sec-gosec.tst.sh`, `sec-shellcheck.tst.sh`;
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

**r67-03 brief, Files: ONLY** `api:internal/store/fleet_lease.go`,
`api:internal/store/fleet_lease_postgres.go`, `api:internal/hub/box_lease.go`,
`api:internal/cleancode/cleancode_test.go` (its 2 `CASFleetLease` lines), and the
`CASFleetLease(` calls in `api:internal/store/fleet_lease_test.go`,
`fleet_atbox_test.go`, `crosstenant_test.go`, `api:internal/hub/role_group_test.go`,
`wui_active_agent_test.go` (no other line of those 5). Do: plan section 2 row 03
verbatim and section 1.5; the struct `FleetLeaseCASReq` beside `FleetLease`, its doc
comment carrying the interface comment's contract (`ifGen` 0 = no row yet, the lost
race answers ErrConflict with the current row); the 3 red control outputs in the body.
Re-measure first: `git grep -nE '\bCASFleetLease\(' origin/master -- '*.go'` -> 16 lines
in 8 files, or say what moved. Never a migration, never a SQL text change. Gates:
`go test -count=1 ./internal/store/ ./internal/hub/ ./internal/cleancode/`,
`bash csi-spl-api/src/bash/tests/run-all-tests.sh`,
`cd csi-spl-iac && PRE_PUSH_TIER=full ./run -a do_check_pre_push`. `Docs: none (...)`.
Kind `simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 3 (refactor 3; Bash 2, Go 1) |
| vendor | claude 3 |
| kind | simple_coding 3 |
| batches | batch 1: rows 01 and 03 (03 after the v1.1 signature); batch 2: row 02 (after 01) |
| Go `wideFuncs` lines | 6 today -> 4 after r67-03 |
| `.shellcheck-warning-baseline.txt` lines | 86 today -> 82 after r67-01 -> 80 after r67-02 |
| SC2034 lines in it | 41 -> 37 -> 35 |
| SC2034 lines under `csi-spl-iac/` | 10 -> 6 -> 4 (the 4 of 1.3 left out) |
| measured on | rows 01-02 `1ce9158a1`, row 03 `86babad74`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `spl-file-erase` (`no-literal-paths.baseline`, 2 lines, `:31,120`) | a protected-root deny list: a failed derivation would shrink it, so it needs a refusal on no tree, a behaviour change (r66 section 7, round 35 section 6) | 1.2 |
| r66-02 R7 N1 (shallow `APP_PATH` -> `SPL_VAR_ORG_DIR=/var/`) | a new refusal in `spl_run_paths`: behaviour, a **bug row** | 1.2 |
| r66-02 R7 N2 (`FATAL no cargo` swallowed by `$(_scg_build)`) | the line moves to stderr, so the operator sees it: behaviour, a **bug row** | 1.2 |
| `workflow-tool-checksums.tst.sh:33` `naked` | a guard computed and never asserted: wiring it adds a check, dropping it loses the intent. A **bug row** (the test does not test what its comment says) | 1.3 |
| `check-pre-push.tst.sh:53`, `check-weekly-full-scan.tst.sh:29` (`APP_PATH`), `satellite-actions.tst.sh:46` (`GCP_ACCOUNT`) | set for the sourced action under test to read: the baseline's "read by a sourcing caller or a test" case, not dead code | 1.3 |
| the 9 `action-header-tags` `[missing]` files | each declares a `(required)` param; a parsed header makes `do_validate_params` refuse before the body (rc 11): behaviour, a bug round's (rounds 20, 27, 28, 29, 34) | 1.2 |
| `provision-firebase-dns.func.sh` (`LONG` 169, `[long-example]`) | pinned byte-identical to its upstream port (`wui-hosting-019-031.tst.sh:28-30`): a split there breaks the pin; it belongs upstream first | 1.2 |
| the other 31 SC2034 lines (orc) | mostly spawn and restore scripts with 6..8 each, vars a sourced lib or a launcher may read; each needs the per-variable read check of 1.3: input for a later round, one script family per row | `.shellcheck-warning-baseline.txt` |
| SC2154 (20), SC2120 (7), SC1090 (5), SC2088 (4), SC2046 (3), SC2319 (2), SC2164 (2), SC2155 (2) | the baseline's header names these kinds deliberate (framework-set vars, a printed `~`, `run.sh` kept identical across modules); not re-measured one by one here | the baseline's header |
| Go `wideFuncs`: `MoveMessage` and `MergeTopic` pairs (9 parameters each) | each pair is a row of its own (one interface per row, as this plan's row 03); `MoveMessage` has 28 grep lines, `MergeTopic` 19 (`git grep -nE '\b<name>\(' 86babad74 -- '*.go' \| wc -l`, the first counting the hub client's own `MoveMessage`): input for round 68 | 1.2 |
| WUI `WIDE` `src/stores/channel.ts send` (6 params) | positional callers: 63 lines, in 5 WUI source files and 30 test files (`git grep -nE '(channel\|ch)\.send\(' 86babad74 -- csi-spl-wui \| wc -l`; `git grep -l` over `csi-spl-wui/src` -> 5, over `csi-spl-wui/tests` -> 30): a WUI row with its e2e gate, too wide for a 3rd row here: input for round 68 | 1.2 |
| the candidates file's items | on the other box, not read by this lane; its bug-shaped items are not refactor rows (the brief); the holder checks it for a refactor-shaped one | the brief |
| spec 011 T001-T008, T018-T021, T023, T026-T028, T031, T034 | owner-deferred (2026-09-19), an open owner decision, behaviour (T028's assertions), terraform layout (T026) or docs (T031); the spec folder unchanged since W | 1.2 |

## 8. Changes

- v0.1 (c-443): first draft. A fresh round: 2 rows found on `1ce9158a1`, both SC2034
  sites under `csi-spl-iac/` whose variable no code reads. Window W and the r67 slug
  proof recorded.
- v1.0 (c-443): the panel seat m-977 (mistral) passed v0.1 `7c4e9b38f`, W: none. N1
  (origin/master `69c9febbb`, two past `1ce9158a1`: every cited row file:line
  byte-identical, `git log 1ce9158a1..origin/master -- <6 row files>` -> 0), N2 (lane map
  exit 4 with 8 unknown lanes at its read, 3 at this plan's; the holder's R3 before each
  spawn governs), N3 (the `\(r67-` log read now prints 1, this plan's own commit; the
  row-id read `\(r67-[0-9]` -> 0 and no `r67-NN` branch, so the row slugs are free), N4
  (the candidates file's reverse-tunnel item is served by `87d56eaae`, r64-01: no literal
  left in `reverse-tunnel-cron.sh`; the guide's prose at
  `installation-and-configuration-guide.md:594` stays a docs follow-up, as r65 section 7)
  and N5 (shellcheck 0.10.0 on the seat's box: exactly one SC2034 per row file, at the
  plan's lines): no change. Status line and sections 8 and 9 only.
- v1.0 row-scope note (c-443, holder c-002's call A, its msg e7cbf3ca; the r67-01 lane's
  msg 53b3843a), no version bump: in `iac:run/tf-state-push.func.sh` the `vars_path=` line
  holds the first read of `tf_proj` (set by `do_tf_init`). With the line gone shellcheck
  reports `tf_proj` at the next read, `:27:66` SC2154, beside `tf_run_path`, so that file's
  line `SC2154|...tf-state-push.func.sh|1` goes to `|2`, as `tf-state-list`, `-pull` and
  `-remove` already carry. Measured on origin/master `ca05e75b3`, shellcheck 0.10.0, n=1:
  `shellcheck -S warning -f gcc` on the file -> 1 SC2034 + 1 SC2154 before, 2 SC2154
  after deleting `:27`. Row 01 keeps the site; the baseline still goes 86 -> 82 lines
  (section 6), the warnings it removes are 3, not 4.

- v1.1 (c-443, the holder's ask, c-002@sat msg a82a13e5): **row 03** added, the Go
  `CASFleetLease` pair to one `FleetLeaseCASReq`, measured on `86babad74` (1.2, 1.5,
  2, 2.1, 2.2, 3, 5, 6, 7). Off every path of rows 01 and 02, so batch 1. Rows 01 and
  02 unchanged. The round now holds 3 rows, rulebook 5.1's cap: the next candidate
  (`MoveMessage`, `MergeTopic`, the WUI `send`) opens round 68.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-443 (claude): v0.1, v1.0.
- Panel reviewer seat: **m-977 (mistral) PASS** on `7c4e9b38fe9c026d3a69b3ee5ff86f6f980dc2c4`
  (spool msg 3e1c0744, task `dispatch-refactor-r67`); seat file on branch
  `review/c002-refactor-round-67-mistral-seat` (`e3f3bebbd`). W: none; N1-N5 notes.
- v1.1 (row 03): **waits for a panel seat's signature** on its sha (rulebook 3.2);
  rows 01 and 02 stay signed by m-977.
- Row R7 seats: section 4.
