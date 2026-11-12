# Refactoring round 33 - plan (6 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5404  
Topic: b4b264a7-95e9-40aa-a863-529c8637c181  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, pushes aim 1 up
  to 3 never more than 5, R1-R16).

**Why now.** The holder's brief (c-002@sat, answer to c-001's SPAWN SUPPLY LEAD
63df5be6) names the trigger: refactor under its band before the night. Re-read here
(2026-11-12T23:09:35Z, n=1): `cd csi-spl-orc && ./run -a do_spl_spawn_queue` ->
`refactor 5 18% (band 40-60%: UNDER)` of the live lanes, `last 24 h (54 sample(s)):
refactor 7% (band 20-30%: UNDER)`, `30 queued, 1 placing`, `phase night`. **Rounds 31
and 32 are not served and not counted on here** (section 3.2): on `4061ee214`, r57
rows 01-04 and r58 rows 01-04 have commits; r57-05, r57-06 and r58-05..08 have none.
This round is planned early (planner by day, rows by night, rulebook 1.4) and stays
off those six rows' files.

Round 33 focus: **what is left on the clean-code gates' lists, and a ratchet with a
stale line.** The two Go `longFuncs` (`(*Server).Handler` 80, `ProvisionMember` 79)
are split into named steps (rows 01-02); the shellcheck `WARNING` baseline entries
that are a variable name reused as array and string are renamed away (row 03); the
WUI raw-text ratchet gains the stale-line check the security baselines have (r5-05)
and drops its one stale line (row 04); the `spl-spawn-place.func.sh` header round 32
left out as owned is taken once its lane and r58-07 allow (row 05); row 06 drops the
gate lines rows 01-02 leave. The Bash `LONG` list holds nothing left to split
(section 2).

**Status: v0.2**, draft by the editor (v0.1 + the holder's lane-map reading, section 8). No row lane starts before the panel signs the
plan sha.

Editor: **c-615** (claude, on the box that has agy, not sat). Panel seat: grok, queued by the holder (section 5).

**One sha:** every count is measured on **`4061ee214`** (`origin/master`
4061ee214d34f2ece2e73f058fdbfc17443b0621, 2026-11-12T23:00:51Z), n=1 per command
unless stated. Go: go1.26.11. Reads are in this lane's worktree at that sha, clean;
row 03's probe ran on copies of its two files in the lane's scratch dir. Queue and
lane readings are live state, so they carry their own time, not this sha.

## 1. How to read this

- **Slug prefix `r59`.** On `4061ee214`:
  `git log origin/master --oneline -E --grep='r59-' | wc -l` -> 0;
  `git branch -r | grep -c 'r59-'` -> 0;
  `git ls-remote origin 'refs/heads/*r59*' | wc -l` -> 0;
  `grep -rl 'r59-' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote /var/spool-hub/asks 2>/dev/null | wc -l`
  -> 0 on this box (2026-11-12T23:05:52Z). The last slug is taken:
  `git log origin/master --oneline -E --grep='\(r58-[0-9]{2}'` -> 4 commits (rows
  01-04, section 3.2). **Not read:** the same grep on sat's spool; the holder runs it
  there before the first row is queued: the holder did, `grep -rl 'r59-'` over the
  briefs, spawn-remote and asks dirs on sat -> 0 files (2026-11-12T23:2xZ, n=1, note
  549a281a).
- One row = one practice = one lane, at the sites named and nowhere else, with a test
  that shows behaviour kept or, for a test row, a **red control**.
- **Paths:** `go:` = `csi-spl-api/src/go/spool-hub-api/internal/`, `orc:` =
  `csi-spl-orc/src/bash/`, `iac:` = `csi-spl-iac/src/bash/`, `wui:` = `csi-spl-wui/`.
  Lines as of `4061ee214`; a function's site is its first line (R15).
- **Box:** `either` for every row (no pin).
- **Vendor:** claude for every row. **R7 reviewer:** section 5; no seat is named before
  a row is queued.
- **Subject** (R6 reads it): `<type>(r59-NN-<slug>, SPL-<row issue>): ...`.
- **Topic:** every row brief carries the `Topic:` line above.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
- **Re-measure first:** every row lane re-runs the command that measured its input in
  section 2 on the `origin/master` it starts from and says in its result if the number
  moved.
- **Tests per row (R2):** the test files that name the site's basename or function,
  listed per row. Go: the package's tests plus
  `bash csi-spl-api/src/bash/tests/run-all-tests.sh`; a store row adds
  `PRE_PUSH_TIER=full ./run -a do_check_pre_push` (Postgres).
- **What was and was not run:** row 03's probe (section 2), n=1. **No other red
  control or break named here has been planted by this lane, and no case has been
  written.**

## 2. Where the rows come from (measured on `4061ee214`)

**Taken:**

| source | input | command on `4061ee214` | n | row |
|---|---|---|---|---|
| round 31 6, round 32 6 ("Go `longFuncs`, not split here") | the Go `longFuncs` list | `sed -n 33,36p go:cleancode/cleancode_test.go`; `go test -count=1 -v -run TestCleanCode ./internal/cleancode/` | 2 listed: `(*Server).Handler` (`hub/server.go:429`) **80 lines**, `(*Postgres).ProvisionMember` (`store/humans_postgres.go:433`) **79 lines** (`awk` from the `func` line to the first `^}`); the gate run: PASS, no `longFuncs` log | rows 01, 02 |
| the same | a cohesive block in each | read at the sites | `Handler`: the 23 message-route lines `:458-480` (`PATCH /v1/messages/{msg_id}` .. `OPTIONS .../reactions`), among the `s.routeX(mux)` steps it already calls (`routeMoves`, `routeMe`, ...); `ProvisionMember`: the find-or-mint-the-human block `:450-471` (`var hum` .. the `switch`'s end) | rows 01, 02 |
| the same | tests | `grep -lE '"(PATCH\|DELETE\|PUT\|POST) /v1/messages/' go:hub/*_test.go`; `grep -ln ProvisionMember go:*/*_test.go cmd/spool/*_test.go` | `Handler`: `go:hub/` has 430 test files; 6 name a message route (`edit_test.go`, `blocker_issue*_test.go` x3, `dm_ref_test.go`, `demo_test.go`). `ProvisionMember`: 7 test files (`store/provision_member_test.go` `TestProvisionMember` `:18`, 4 more in `store/`, `auth/local_hub_signin_test.go`, `cmd/spool/hub_reset_password_test.go`) plus `cleancode_test.go` | rows 01, 02 |
| rounds 29-32 6 ("fleet-critical long Bash functions") | the Bash `LONG` list | `bash iac:tests/bash-cleancode.tst.sh` | `1 listed` over 75 (`do_provision_firebase_dns`, byte-pinned to csi-rel); 3 `NOTE LONG ... delete its line` (r58-02..04 landed; r58-08 deletes them). `spl_fleet_role_tick` is no longer listed: `git log -S spl_fleet_role_tick -- iac:tests/bash-cleancode.tst.sh` -> `878dd2339` (SPL-5339) | **nothing left to split** |
| rounds 29-31 6 ("slow scanners, not re-measured") | the `WARNING` shellcheck ratchet | `grep -vcE '^\s*(#\|$)' .shellcheck-warning-baseline.txt`; per code, summed | **95 lines, 189 warnings**: SC2034 114 in 43 lines, SC2154 28/20, SC2155 12/2 (vendored `run.sh`), SC2120 7, SC1090 7, SC2088 6, SC2164 4 (`run.sh`), SC2046 3, SC2178 3, SC2128 2, SC2319 2, SC2179 1 | row 03 |
| the same | the array/string family (SC2128, SC2178, SC2179) | `shellcheck -S warning -f gcc <f> \| grep -E 'SC(2128\|2178\|2179)'` (0.10.0) | all 6 in 2 files, each a name another function of the file uses as an array: `spl-tenant-test-purge.func.sh` `:105`, `:108`, `:111`, `:113` (`q`: a string here, an array in `spl_tenant_test_purge_arr` `:74`); `spl-desk-welcome.func.sh` `:291-292` (`live`: a string here, an array in the action `:72`) | row 03 |
| the same | does a rename clear them? (probe) | copies of both files, `q` -> `sql` at `:105-113`, `live` -> `live_set` at `:291-292`, the same `shellcheck` | **4 -> 0 and 2 -> 0**; no other line touched | row 03's input |
| rounds 29-31 6 ("raw text, not re-measured") | the WUI raw-text ratchet | `cd csi-spl-wui && node src/node/i18n/i18n-gates.mjs raw --list`; `cat i18n/i18n-raw-text-baseline.json` | measured **12 in 11 files**; the baseline holds **14 in 12 files**. One line is stale: `src/pages/reporting/costs/spend.vue: 2`, measured 0 (last change `047e2a759`, SPL-5312). The test still passes (`node --test tests/unit/i18n-no-raw-text.test.mjs` -> 5 pass, 0 fail): `overBaseline` (`src/node/i18n/i18n-gates.mjs:159`) checks only `n > baseline`. The 12 left are codes and names (`"/search:"`, `"YYYY-MM-DD HH:MM"`, `"spool-hub"`, `"Csitea"`, `"#lobby"`), not words to translate | row 04 |
| round 32 6 (`spl-spawn-place.func.sh` header, owned) | its `[missing]` line | `bash iac:tests/action-header-tags.tst.sh`; `grep -ciE '^# *@param.*required' orc:run/spl-spawn-place.func.sh` | `20 missing, 1 long-example`, ALL PASS; the file parses to nothing (no `#---` block; its `@description` starts at `:2`) and carries **0** `(required)` params, so `do_validate_params` gains nothing to refuse. Owner in round 32: `c-567@sat`, still live and `unknown:` here (section 3.2) | row 05, conditional |
| rows 01-02 here | the gate lines they leave | the Go gate row above | 2 `longFuncs` lines (`cleancode_test.go:34-35`) | **Row 06**, batch 3 |

**Deferred or dropped:**

| source | input | command on `4061ee214` | n | disposition |
|---|---|---|---|---|
| round 32 6 | `send` `WIDE` (`wui:src/stores/channel.ts:534`) | `git grep -cE "(ch\|chStore\|channel\|\('channel'\)\??)\.send\(" 4061ee214 -- csi-spl-wui/tests/e2e`, summed | **30 files, 56 lines**, as round 32 | **Left out**: needs an e2e send helper first, over the cap many times |
| round 32 6 | `CASFleetLease`, `MoveMessage`, `MergeTopic` pairs | `git grep -nE '\b<name>\(' 4061ee214 -- csi-spl-api/src/go` per name | non-test: 3 files each (interface + Memory, Pg, one caller); test files: **5, 11, 9** (`CASFleetLease`: 2 in `hub/`, 3 in `store/`) | **Left out**: 8 files at the least, over the 5-site cap |
| round 32 6 | the 9 header files with a `(required)` param | round 32 section 2 | not re-measured | **Left out**, bug-round input, as round 32 |
| rounds 29-31 6 ("low packages") | the lowest Go coverage floors | `sort -k2 -n csi-spl-api/src/bash/tests/go-coverage-floor.txt`; `go test -count=1 -cover ./internal/blob/` | lowest product package `internal/blob`, floor 71.9, measured 71.9%; every uncovered function is the GCS store (`blob.go:244-443`, `OpenGCS`, `Put`, `Get`, ... 0.0%) | **Left out**: needs a GCS fake, wider than a row |
| this round | the untranslated ratchet's stale lines | `node src/node/i18n/i18n-gates.mjs untranslated` against `i18n/i18n-untranslated-baseline.json` | 18 locales, **0 stale** (equal) | **Left out** of row 04: nothing to drop, and the stricter rule would bind translation (agy) lanes; a later round may take it |
| rounds 29-31 6 | the other shellcheck codes | section 2 above | SC2034 114 (often read by a sourcing caller), SC2154 28 (set by `./run`), the vendored `run.sh` lines | **Left out**: deliberate or vendored, as the baseline's own header says |
| round 32 6 | `hubclient` `writeAtomic`, `hold`; `provision-firebase-dns` | not re-measured | none | **Left out / dropped**, as round 32 |

## 3. The 6 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r59-01-api-handler-message-routes)` | a function in named steps (`maxFuncLines` 75) | `(*Server).Handler` is 80 lines, a `longFuncs` entry | `go:hub/server.go:429` (`Handler`), its message routes `:458-480` | 1 function | Move the message-route lines into one named step on `*Server` beside the other `routeX` (e.g. `routeMessages(mux)`, in `server.go`), called where they stood, so the mux is built in the same order and `Handler` is at most 75 lines. **Placed only after `c-547@sat` (linkedin company page) lands or drops its `server.go` change, and the lane map no longer names a lane on the file (section 3.2).** Routes, methods and middleware unchanged. Leave the `longFuncs` line (row 06; the gate logs `is no longer over 75 lines` after). Tests: `go test -count=1 ./internal/hub/`; `run-all-tests.sh`; `go test -count=1 -v -run TestCleanCode ./internal/cleancode/`. **Control:** C2 behaviour kept; the lane deletes the step's call and names a failing case (expected, not run: `edit_test.go` `TestEditMessageRoundTrip` `:93` on `PATCH /v1/messages/{msg_id}`), restored. | either | claude | simple_coding | 2 (after c-547@sat) |
| 02 `refactor(r59-02-store-provision-member-steps)` | as row 01 | `(*Postgres).ProvisionMember` is 79 lines, a `longFuncs` entry | `go:store/humans_postgres.go:433` (`ProvisionMember`), its find-or-mint block `:450-471` | 1 function | Move the find-or-mint-the-human block into one unexported helper in the same file that takes the open `tx` (e.g. `provisionHumanTx(ctx, tx, in, email, now) (hum string, created bool, err error)`), so `ProvisionMember` is at most 75 lines; the advisory lock, the one transaction, every SQL text and the results unchanged. Leave the `longFuncs` line (row 06). Tests: `go test -count=1 ./internal/store/ ./internal/auth/ ./cmd/spool/`; `run-all-tests.sh`; store: `PRE_PUSH_TIER=full ./run -a do_check_pre_push` (Postgres runs the `Pg` path); the Go gate as row 01. **Control:** as row 01, a named `TestProvisionMember` case red with the helper's `created` result forced `false`, restored. | either | claude | simple_coding | 1 |
| 03 `refactor(r59-03-orc-shellcheck-name-reuse)` | one name, one type (shellcheck SC2128/SC2178/SC2179) | 6 `WARNING`s in 2 files are a local reusing another function's array name; the probe clears all 6 by a rename (section 2) | `orc:run/spl-tenant-test-purge.func.sh:105-113` (`q` -> e.g. `sql`)<br>`orc:run/spl-desk-welcome.func.sh:291-292` (`live` -> e.g. `live_set`)<br>`.shellcheck-warning-baseline.txt:96-97,100-102` | 2 files, 5 baseline lines | Rename the string local in each place, no other change; delete the 5 baseline lines. Tests: `orc:tests/tenant-test-purge.tst.sh`, `desk-welcome.tst.sh`, `peer-restart.tst.sh`, `tests-hermetic.tst.sh` (section 3.3); `cd csi-spl-iac && ./run -a do_sec_shellcheck` (the full `WARNING` ratchet) and `./run -a do_check_pre_push_lint`. **Control:** the ratchet's own rule (r5-05, `sec-baseline.func.sh:67`): renamed with the 5 lines kept -> `FATAL shellcheck: fewer findings than baselined` naming them; deleted -> pass. | either | claude | simple_coding | 1 |
| 04 `test(r59-04-wui-raw-text-stale-line)` | a ratchet fails a stale line (r5-05, as the four security baselines) | the raw-text baseline holds `spend.vue: 2`, measured 0; the test cannot see it | `wui:src/node/i18n/i18n-gates.mjs:159` (beside `overBaseline`)<br>`wui:tests/unit/i18n-no-raw-text.test.mjs:20-27`<br>`wui:i18n/i18n-raw-text-baseline.json:12` | 1 helper, 1 case, 1 line | Add the stale check: a baseline entry whose file measures fewer (or no longer exists) fails, naming the file and both counts and saying to lower or delete the line; delete the `spend.vue` line. `overBaseline` and the untranslated test unchanged. Tests: `node --test tests/unit/i18n-no-raw-text.test.mjs` and `tests/unit/i18n-untranslated.test.mjs` (it imports the same module); `pnpm run typecheck`. R9 (a gate): `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. **Red control:** the new case with the `spend.vue` line kept -> red naming it; deleted -> green; plus a scanner case that a planted `{ 'src/x.vue': 1 }` against an empty scan is stale. | either | claude | tests | 1 |
| 05 `refactor(r59-05-orc-action-header-spawn-place)` | a header `./run --help` can read (developer guide 2.4.2), as r58-05..07 | the one `[missing]` file round 32 left out as owned, with 0 `(required)` params | `orc:run/spl-spawn-place.func.sh:2`<br>`iac:tests/action-header-tags-baseline.txt:27` (on `4061ee214`; it moves when r58-05..07 land) | 1 file, 1 line | As r58-05: wrap the file's existing `@description` / `@param` / `@example` lines in a `#---` block right after the shebang, add an `@example` only where none parses, no other text change; delete its baseline line. Re-check `grep -ciE '^# *@param.*required'` -> 0 before the push. **Placed only after r58-07 lands (R1, R16) and when `lane-map.sh --check` on the file no longer names `c-567@sat` or another lane.** Tests: `bash iac:tests/action-header-tags.tst.sh` (`9 missing` after r58-05..07 and this); the 13 orc tests that name its basename or `do_spl_spawn_place` (section 3.3); `do_check_pre_push_lint`; `do_parse_metadata <f>` shows `description=` and `example=`. **Control:** as r58-05, the test's own rule: fixed and still listed -> `FAIL ... is listed under [missing] but now has both tags`, then deleted -> pass. | either | claude | simple_coding | 3 (after r58-07) |
| 06 `test(r59-06-drop-gate-lines-of-r59)` | a gate's list holds no stale line (`r56-08`, `r57-06`, `r58-08`) | rows 01-02 leave 2 stale lines | `go:cleancode/cleancode_test.go:34-35` (`(*Server).Handler`, `(*Postgres).ProvisionMember`); lines as of `4061ee214`, they move when r57-06 and r58-08 land | 2 lines | Placed only after **r57-06, r58-08** and rows 01-02 are on trunk (R16); a row not landed keeps its line, and the lane says which. Delete exactly the lines the gate logs; `longFuncs` stays, empty, as the WUI `LONG` does. Tests: `go test -count=1 -v ./internal/cleancode/` (no `longFuncs` log after); `run-all-tests.sh`. R9: `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. **Red control:** delete a still-wide entry (`(*Memory).CASFleetLease`) -> the Go gate fails naming it, restored. A stale `longFuncs` entry is only logged, never failed (`cleancode_test.go:106-107`), so the lane quotes that log before and its absence after. | either | claude | tests | 3 (after r57-06, r58-08, 01-02) |

### 3.1 Lanes and batches

- **Batch 1: rows 02-04, no file in two rows.** Row 02 owns
  `store/humans_postgres.go`; row 03 two orc action files and
  `.shellcheck-warning-baseline.txt`; row 04 three WUI files. No row edits a migration,
  `csi-spl-cnf/`, a workflow, terraform, a WUI page or component, or a gate's list
  other than its own ratchet line.
- **Batch 2: row 01** edits `hub/server.go`, which `c-547@sat` has changed in its
  worktree (section 3.2); placed within 30 minutes of that lane landing or ending
  (R16), after a fresh `lane-map.sh --check` on the file.
- **Batch 3: row 05** edits `action-header-tags-baseline.txt` after r58-07 lands (the
  file is r58-05..07's), and only when the lane map frees `spl-spawn-place.func.sh`.
- **Batch 3: row 06** edits `cleancode_test.go`, **r57-06's and r58-08's** file, within
  30 minutes of the last of r57-06, r58-08 and rows 01-02 landing (R16).
- Rows 01-02 run the Go gate but do not edit it.

### 3.2 Off every live lane, every queued row and rounds 31-32 (R3)

- **Unlanded rows** (2026-11-12T23:05:52Z, on `4061ee214`):
  `git log origin/master --format='%h %s' -E --grep='\(r57-[0-9]{2}'` -> 4 commits
  (r57-01..04); `--grep='\(r58-[0-9]{2}'` -> 4 commits (r58-01..04). Not on master:
  **r57-05** (`useCardMove.ts`, `MessageCard.vue`, `card-move-steps.test.mjs`), **r57-06**
  (`cleancode.test.mjs`, `cleancode_test.go`), **r58-05..07** (the ten action files
  `spl-asks-sync`, `spl-orch-inbox`, `spl-spawn-group-list`,
  `spl-export-constitution-coding-standards`, `spl-epic-stall-check`,
  `spl-security-round-queue`, `spl-spawn-fill`, `spl-spawn-queue`, `spl-spawn-share`,
  `spl-lane-map`, and `action-header-tags-baseline.txt`), **r58-08**
  (`bash-cleancode.tst.sh`, `cleancode_test.go`). Rows 01-04 write none of them; the
  check on this file, n=1:
  `grep -E '^\| 0[1-4] ' <this file> | grep -oE 'useCardMove|MessageCard|card-move|cleancode\.test\.mjs|bash-cleancode|action-header-tags|spl-(asks-sync|orch-inbox|spawn-group-list|export-constitution|epic-stall|security-round|spawn-fill|spawn-queue|spawn-share|lane-map)' | wc -l`
  -> 0. `cleancode_test.go` appears in rows 01-02 only as the Go gate they run, never
  as a site. Rows 05 and 06 write r58's and r57/r58's files and wait for them
  (section 3.1).
- **The written paths: 11.** Row 01 1, row 02 1, row 03 3, row 04 3, row 05 2
  (`spl-spawn-place.func.sh`, `action-header-tags-baseline.txt`), row 06 1
  (`cleancode_test.go`); each present on `4061ee214`.
- **Lane map on sat: exit 3** (the holder c-003@sat, fleet lane map, `--check <the 11
  paths> --agent c-003`, 2026-11-12T23:2xZ, n=1; quoted from its note 549a281a, not
  re-run here): `hub/server.go` owned by `c-547@sat`
  (`c-547-c002-feat-linkedin-company-page-publish`, changed in its worktree, no files
  recorded) -> **row 01 moved to batch 2**; `action-header-tags-baseline.txt` owned by
  `c-624@sat` (r58-05) and `spl-spawn-place.func.sh` by `c-567@sat` and `c-620@sat` ->
  rows 05 and 06 already wait. The other 8 paths: no owner named.
- **Lane map from this box: NOT proven free.** `lane-map.sh --check <the 11 paths, comma separated>
  --agent c-615` on this box -> **exit 4** at 2026-11-12T23:08:33Z: 0 paths owned; 8
  `unknown:` lanes, all on sat, with no files recorded (`c-547` linkedin page,
  `c-560` rotate, `c-567` spl5259 issue follows discussion, `c-602` role internal
  accountant, `c-619` monitoring gaps, `c-620` agy review seat placement, `c-624`
  **r58-05**, `g-623` spl5372 grok reviewer). Exit code read via `PIPESTATUS`, n=1.
  `c-567` owned `spl-spawn-place.func.sh` in round 32 (exit 3, 2026-11-11T18:05:38Z):
  row 05 waits for it. **Exit 4 is not free, and this plan did not clear it**; the
  holder re-runs the check on all 11 paths before each row's spawn (R3).
- **Spawn queue (2026-11-12T23:09:35Z):** `do_spl_spawn_queue` -> `30 queued, 1
  placing`. **23 of the 31 briefs are on this box**, grepped for every written basename and
  function of rows 01-06 (`hub/server\.go`, `humans_postgres`, `ProvisionMember`,
  `func (s \*Server) Handler`, `spl-tenant-test-purge`, `spl-desk-welcome`,
  `shellcheck-warning-baseline`, `i18n-no-raw-text`, `i18n-raw-text-baseline`,
  `i18n-gates`, `spl-spawn-place\.func`, `action-header-tags`, `cleancode_test`,
  `longFuncs`) -> **0 hits** (2026-11-12T23:10:00Z). **8 are on sat, not grepped
  here:** `reflection-2026-11-12`, `hand-sat-c001-tf-060-plan-spl5263`,
  `c002-bug-fleet-paid-tst-run-log-pin`, `hand-sat-c002-alerts-30d-scrubbed-extract`,
  the billing SA key brief (`...-feat-billing-sa-tf-key-f655b326`),
  `c002-bug-actas-clone-check-fail-closed`, `hand-sat-c001-tf-030-apply-netvisor`,
  `c002-r58-05-grok-reviewer`; the holder grepped them on sat (note 549a281a, n=1): 7 -> 0 hits;
  `c002-r58-05-grok-reviewer.md` -> 3, all `action-header-tags` (the r58-05 review),
  which row 05 already waits on. Several queued
  WUI feature lanes (e.g. `c002-feat-rail-help-settings-labels-6407fdbe`,
  `c002-feat-human-cost-entry-ui-2d974709`) may change `i18n-raw-text-baseline.json`
  when they land; row 04 re-measures first (section 1).
- **Worktrees on this box** (295 lines of `git worktree list`, 2026-11-12T23:08:57Z): each
  one's `git diff --name-only origin/master...HEAD` plus `git status --porcelain`,
  matched against the 11 paths -> 7 hits, all stale scratch: `GRK-3354`, `c-095-r7`,
  `c-357-plant`, `c-695-rc`, `c-695-rv`, `m-969` (`hub/server.go`), `m-374`
  (`i18n-raw-text-baseline.json`); last commits 2026-09-18 .. 2026-11-04, and
  `tmux list-windows -a | grep -cE 'c-095|c-357|c-695|m-374|m-969|GRK-3354'` -> 0.
- **The owner's permanent performance round** (`c002-docs-permanent-perf-round-8ebbed0e`):
  0 commits on `4061ee214` (`git log origin/master --since=3.days -i -E
  --grep='8ebbed0e|permanent.perf'`), not in the queue at 23:09Z. This round has **no
  perf row** either way.

### 3.3 Tests per row, measured (R2, C4)

Rows 03 and 05 list every test that names a file's bare basename or its `do_*`
function (round 32's section 3.3 command, `NAMES` the row's basenames):

`pat=$(for n in $NAMES; do printf '%s' "|\b$n(\.func\.sh)?([^a-z0-9_-]|\$)|\bdo_${n//-/_}\b"; done); git grep -lE "${pat#|}" 4061ee214 -- 'csi-spl-orc/**/tests/*' 'csi-spl-iac/**/tests/*' | grep -v baseline`

On `4061ee214` (n=1 each): row 03 -> 4 tests (`tenant-test-purge`, `desk-welcome`,
`peer-restart`, `tests-hermetic`, each `.tst.sh`; the pattern also carried
`spl_desk_welcome_plan|spl_tenant_test_purge`); row 05 -> 13 (`desk-user-hops`,
`lane-rotate`, `spl-box-cordon`, `spl-box-pick`, `spl-epic-stall-check`,
`spl-security-round-queue`, `spl-spawn-fill`, `spl-spawn-group`,
`spl-spawn-place-argmax`, `spl-spawn-place-supply`, `spl-spawn-queue`,
`spl-spawn-review-notify`, `watcher-feed`, each `.tst.sh`). Rows 01-02 run their whole
Go packages; row 04 its two unit files and the typecheck.

## 4. Per row: what the lane does

- **01:** `Handler`'s message routes in one named step; at most 75 lines.
- **02:** `ProvisionMember`'s find-or-mint step in one helper; at most 75 lines.
- **03:** Two string locals renamed; 5 shellcheck baseline lines go.
- **04:** The raw-text ratchet fails a stale line; the `spend.vue` line goes.
- **05:** After r58-07, and with its file free: `spl-spawn-place.func.sh`'s header parses.
- **06:** After r57-06, r58-08 and 01-02: delete the two `longFuncs` lines.

## 5. Panel and reviewers (R7)

- Editor: c-615 (claude, this box). Both seats sign the plan sha (rulebook 3.2).
- **Panel seat:** one seat of another vendor, as rulebook 3.2 asks ("a cross-vendor
  panel"; it names no vendor). agy is the `specs_and_docs` main, but sat has no agy and
  agy is at quota on this box until about 2026-11-13T23:43Z (the brief). Re-read here, n=1:
  `ENV=prd ./run -a do_spl_hub_agent_kinds` -> `prd instance agent kinds: off [qwen],
  paused []` (2026-11-12T23:10:46Z), and the queue places a grok R7 seat tonight
  (`c002-r58-05-grok-reviewer`, `placing`). So the request is a **grok** panel seat,
  either box, now (queued by the holder: ask 4b41e69f); if the holder rules grok out, the plan **waits for agy** after its
  quota resets, and no row starts before. Asked of the dispatch holder on task
  `dispatch-refactor-r33`. The panel seat reviews this plan only, never a row.
- **Row reviewers: cross-vendor R7 (2.7.2), a fresh grok seat per row while grok is on
  and the holder places grok reviewers; else a fresh claude seat under waiver 1a7c70da.**
  The waiver's state was **not re-read here** from the owner's posts; the holder
  confirms the vendor before each row's reviewer is queued.
- **Conditions per row:** the reviewer is a FRESH session, never the author and never a
  seat already in the work; it reads only the tree. A claude reviewer's brief names
  waiver 1a7c70da and its line says same-vendor under the waiver in `read:`; the
  waiver does not make a row compliant (2.7.5 fails an equal pair; the retro names it).
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| `send` `WIDE` (`channel.ts:534`) | 30 e2e files, 56 lines use its positional form; needs an e2e send helper first; **input for a later round** | section 2 |
| `CASFleetLease`, `MoveMessage`, `MergeTopic` pairs | 3 non-test files each plus 5, 11 and 9 test files; over the 5-site cap. A later round may first route each pair's test calls through one helper per package | section 2 |
| the 9 header files with a `(required)` param | a behaviour change: bug-round input | round 32 section 2 |
| `internal/blob` coverage (71.9) | the uncovered rest is the GCS store; needs a GCS fake | section 2 |
| the untranslated ratchet's stale check | 0 stale today; it would bind translation lanes | section 2 |
| shellcheck SC2034, SC2154, vendored `run.sh` | deliberate or vendored (the baseline's header) | section 2 |
| `do_provision_firebase_dns` (`LONG`, long example) | byte-pinned to csi-rel | round 30 section 2 |
| `hubclient` `writeAtomic`, `hold` | no small case found | round 30 section 2 |

## 7. Counts

| metric | n |
|---|---|
| rows | 6 (refactor 4, test 2; Go 2, Bash 2, WUI 1, Go gate 1) |
| vendor | claude 6 |
| kind | simple_coding 4, tests 2 |
| batches | batch 1: 3 rows (02-04); batch 2: 1 (01, after c-547@sat); batch 3: 2 (each after other rounds' rows) |
| Go `longFuncs` lines | 2 -> 0 (row 06) |
| shellcheck `WARNING` baseline | 95 lines / 189 warnings -> 90 / 183 (row 03) |
| raw-text baseline | 12 files / 14 -> 11 / 12 (row 04) |
| action header `[missing]` | 10 after r58-05..07 -> 9 (row 05) |
| measured on | `4061ee214`, n=1 per command unless stated |

## 8. Changes

- v0.2 (c-615, the holder c-003@sat's note 549a281a, the panel brief's P5): the sat
  lane map exits 3 on `hub/server.go` (`c-547@sat`), so **row 01 moves from batch 1
  to batch 2**, placed after that lane lands or ends; section 3.2 records the sat
  readings (lane map, slug grep 0, the 8 sat briefs). Rows, sites and the other
  batches unchanged.
- v0.1: first draft (c-615): 6 rows, slug `r59`, measured on `4061ee214`. Carries
  rounds 31-32's section 6: Go `longFuncs` taken (rows 01-02, 06); the Bash `LONG`
  list found empty of work; the slow-scanner and raw-text items re-measured (rows
  03-04); `spl-spawn-place.func.sh` taken on condition (row 05); `send`, the interface
  pairs, the `(required)` headers and the low packages left out with numbers.

## 9. Consensus

Both seats sign this plan (rulebook 3.2).

- Editor seat: c-615 (claude): drafted v0.1 and v0.2.
- Panel reviewer seat: grok, queued by the holder as ask 4b41e69f
  (`grok:c003-refactor-round-33-grok-panel-reviewer`); not yet placed.
- Row R7 seats: section 5.
