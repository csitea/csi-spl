# Refactoring round 32 - plan (8 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5322  
Topic: b4b264a7-95e9-40aa-a863-529c8637c181  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, pushes aim 1 up
  to 3 never more than 5, R1-R16).

**Why now.** The holder's brief (c-002@sat SPAWN SUPPLY LEAD answer 03ae4b15, placed
by c-001@sat) names the trigger: refactor under its band. Re-read here
(2026-11-11T18:09:07Z, n=1): `cd csi-spl-orc && ./run -a do_spl_spawn_queue` ->
`last 24 h (114 sample(s)): refactor 4% (band 20-30%: UNDER)`, `32 queued, 1
placing`. **Round 31 ([plan](refactor-round-31-plan.md), slug `r57`) is not served
and not counted on here:** `git log 1985b986d --oneline -E --grep='r57-' | wc -l`
-> 0; its rows 01, 03, 04 are queued (positions 2-4 of 32, asks 5b51df02, f917f436,
ed90fa18, 23 h in line); rows 02, 05, 06 wait behind them. This round is planned
early (planner by day, rows by night, rulebook 1.4) and stays off all six r57 rows'
files (section 3.2).

Round 32 focus: **what rounds 29-31 left as "not re-measured" or "wider than a row",
measured now.** One Go interface pair (`IssueToken`: one production caller, so it fits
a row), three of the four listed long Bash functions (each 4-5 lines over 75, each
with tests that name it), and ten of the twenty action files whose header the parser
cannot read (comment-only, no `(required)` parameter, so `do_validate_params` gains
nothing to enforce). Row 08 drops the gate lines they leave. Round 31's `send`
carry-over is **left out again, with a new measurement** (section 2): 30 e2e files
call the store's positional `send`.

**Status: v0.1 DRAFT**, for the panel (section 5). No row lane starts before the panel
signs the plan sha.

Editor: **c-591** (claude). Panel seat: requested, section 5.

**One sha:** every count is measured on **`1985b986d`** (`origin/master`
1985b986d5dd898eb4abec6f831cbc2b5d905ca9, 2026-11-11T17:35:32Z), n=1 per command
unless stated. Go: go1.26.10. Reads are in this lane's worktree at that sha, clean;
row 01's survival probe ran on a `git archive 1985b986d csi-spl-api csi-spl-rdb` copy.
Queue and lane readings are live state, so they carry their own time, not this sha.

## 1. How to read this

- **Slug prefix `r58`.** On `1985b986d`:
  `git log 1985b986d --oneline -E --grep='r58-' | wc -l` -> 0;
  `git branch -r | grep -c 'r58-'` -> 0;
  `git ls-remote origin 'refs/heads/*r58*' | wc -l` -> 0;
  `grep -rl 'r58-' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote /var/spool-hub/asks 2>/dev/null | wc -l`
  -> 0 on this box (2026-11-11T17:53Z). The last slug is taken: the same grep for
  `r57-` -> 18 files (round 31's row briefs and asks), 0 commits.
- One row = one practice = one lane, at the sites named and nowhere else, with a test
  that shows behaviour kept or, for a test row, a **red control**.
- **Paths:** `go:` = `csi-spl-api/src/go/spool-hub-api/internal/`, `orc:` =
  `csi-spl-orc/src/bash/`, `iac:` = `csi-spl-iac/src/bash/`. Lines as of `1985b986d`;
  a function's site is its first line (R15).
- **Box:** `either` for every row (no pin).
- **Vendor:** claude for every row. **R7 reviewer:** section 5; no seat is named before
  a row is queued.
- **Subject** (R6 reads it): `<type>(r58-NN-<slug>, SPL-<row issue>): ...`.
- **Topic:** every row brief carries the `Topic:` line above.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
- **Re-measure first:** every row lane re-runs the command that measured its input in
  section 2 on the `origin/master` it starts from and says in its result if the number
  moved.
- **Tests per row (R2):** the test files that name the site's basename or function
  (`git grep -lE '<basename>|<function>' -- <the module's test dirs>`), listed per
  row. Go: the package's tests plus `bash csi-spl-api/src/bash/tests/run-all-tests.sh`;
  an auth or store row adds `PRE_PUSH_TIER=full ./run -a do_check_pre_push` (Postgres).
- **What was and was not run:** row 01's survival probe (section 2), n=1. **No other
  red control or break named here has been planted by this lane, and no case has been
  written.**

## 2. Where the rows come from (measured on `1985b986d`)

**Taken:**

| source | input | command on `1985b986d` | n | row |
|---|---|---|---|---|
| round 31 6 (Go `wideFuncs` interface pairs) | `IssueToken` | `git grep -nE '\bIssueToken\(' 1985b986d -- csi-spl-api/src/go` | 8 params. The `CredStore` method (`auth/native_store.go:67`), 2 implementations (`native_store.go:128` Memory, `native_store_postgres.go:53` Pg), **one production caller** (`auth/native.go:329`, in `mint`), one test file (`native_store_test.go`, 7 calls `:72`-`:119`). Lines `cleancode_test.go:45-46` | **Row 01** |
| the same | is the call's argument order under test? | archive copy, `native.go:329` `th, pwHash` planted as `pwHash, th`; `go test -count=1 ./internal/auth/` | **45 `--- FAIL`** (verify `401 verification_token_invalid`, e.g. `TestPreferencesNeedSession`), rc 1. The order is pinned; no pin row needed | Row 01's control |
| round 31 6 (Go `wideFuncs` interface pairs) | `CASFleetLease`, `MoveMessage`, `MergeTopic` | the same grep per name | `CASFleetLease`: 1 caller `hub/box_lease.go:97` + 5 test files; `MoveMessage`: 1 caller `hub/message_move.go:326` + 13 test files; `MergeTopic`: 1 caller `hub/topic_merge.go:108` + 9 test files | **Left out**: over the 5-site cap (section 6) |
| rounds 29-31 6 ("fleet-critical long Bash functions, not re-measured") | the Bash `LONG` list | `sed -n 25,31p iac:tests/bash-cleancode.tst.sh`; `bash iac:tests/bash-cleancode.tst.sh` | 5 listed, each at its ceiling (no `NOTE LONG`): `_spawn_worktree` 79, `do_spl_agent_identity_restore` 80, `spl_desk_pick` 80, `spl_fleet_role_tick` 78, `do_provision_firebase_dns` 169 | rows 02-04 |
| the same | tests that name each | `git grep -lE '<file basename>\|<function>' 1985b986d -- <orc and iac test files>` | `spl_desk_pick`: 5 (`desk-actions.tst.sh` names the function); `do_spl_agent_identity_restore`: 9 (6 `test-agent-identity-restore*.sh`); `_spawn_worktree`: 16 (`test-spawn-stale-wt-dir.sh`, `test-spawn-fetch-no-prompt.sh`, `test-spawn-reuse-unpushed.sh` name the function); **`spl_fleet_role_tick`: 0 tests name it** (only `bash-cleancode.tst.sh`) | rows 02-04; `spl_fleet_role_tick` left out |
| round 29 2 ("the action header files") | the `[missing]` list | `bash iac:tests/action-header-tags.tst.sh` | `measured 812 files: 20 missing, 1 long-example`; `ALL PASS` | rows 05-07 |
| the same | why each is missing; what parsing it would change | `do_parse_metadata <f>` per listed file; `grep -ciE '^# *@param.*required' <f>` | all 20 parse to nothing (no `#---` block before the first code line). **10 carry no `(required)` param**, so `do_validate_params` (`csi-spl-orc/lib/bash/funcs/validate-params.func.sh:33`) gains nothing to refuse; 9 carry 1-3 (`gcp-project-delete`, `gcp-tail-logs`, `spl-ask-ack`, `spl-ask-close`, `spl-ask-put`, `spl-lane-put`, `spl-spawn-enqueue`, `spl-spawn-group-put`, `spl-spawn-placed`): a header that parses would make `./run` refuse a call without them, a behaviour change; `spl-spawn-place.func.sh` (0 required) is **owned** (section 3.2) | 10 files -> rows 05-07; the 9 and `spl-spawn-place` left out |
| rows 01-04 here | the gate lines they leave | the two gate rows above | 5 (3 Bash `LONG`, 2 Go `wideFuncs`) | **Row 08**, batch 3 |

**Deferred or dropped:**

| source | input | command on `1985b986d` | n | disposition |
|---|---|---|---|---|
| round 31 6 (input for round 32) | `send` `WIDE` (`csi-spl-wui/src/stores/channel.ts:534`) | `git grep -cE "(ch\|chStore\|channel\|\('channel'\)\??)\.send\(" 1985b986d -- csi-spl-wui/tests/e2e`, summed | **30 e2e files, 56 calls** drive the store's positional `send` through pinia (e.g. `agent-id-mention.test.mjs:51` `ch.send(text, undefined, undefined, undefined, 1)`), on top of round 31's 7 source call sites and 2 wirings. Round 31 counted only `src/`. Any change of its parameter list moves those files too | **Left out**: needs an e2e send helper first (30 files, over the cap many times); input for a later round, section 6 |
| round 31 6 | a live-store pin of `send` | `git grep -c useChannelStore 1985b986d -- csi-spl-wui/tests/unit \| wc -l` | 0 | **Left out**, with `send` |
| round 31 6 | `hubclient` `writeAtomic`, `hold` | not re-measured | none | **Left out**, as round 31 |
| round 31 6 | Go `longFuncs` (`(*Server).Handler`, `ProvisionMember`) | `sed -n 33,36p go:cleancode/cleancode_test.go` | 2 lines | **Left out**, as round 31 |
| round 31 6 | `provision-firebase-dns` long example and `LONG` line | not re-measured | byte-pinned to csi-rel | **Dropped**, as rounds 30-31 |
| round 31 6 | raw text, low packages, slow scanners | **NOT re-measured** | none | **Left out**, as round 31 |

## 3. The 8 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r58-01-api-issue-token-struct)` | pass the struct instead (`cleancode_test.go:20`) | `IssueToken` takes 8 parameters, 4 strings in a row; one production caller, so the interface pair fits one row | `go:auth/native_store.go:67` (the `CredStore` method)<br>`go:auth/native_store.go:128` (Memory)<br>`go:auth/native_store_postgres.go:53` (Pg)<br>`go:auth/native.go:329` (its one caller)<br>`go:auth/native_store_test.go:72-119` (7 calls) | 1 method, 2 implementations, 1 caller, 1 test file | `IssueToken(ctx, t TokenIssue)` with `TokenIssue{Kind, Subject, TokenHash, PwHash string; Now, Expires time.Time; Floor MailFloor}` defined in `auth` beside `MailFloor`. Results and errors unchanged. Leave both `wideFuncs` lines (row 08). **Control:** the probe's swap at `native.go:329` (`pwHash, th`) -> 45 `--- FAIL` in `./internal/auth/` (section 2, run here n=1); the lane re-plants the same swap in the struct literal (`TokenHash: pwHash, PwHash: th`) -> red, restored. Tests: `go test -count=1 ./internal/auth/`; `run-all-tests.sh`; auth store: `PRE_PUSH_TIER=full ./run -a do_check_pre_push` (Postgres runs `native_store_test.go` on `PgCredStore`); `go test -count=1 -v -run TestCleanCode ./internal/cleancode/` (two `no longer takes more than` logs after). | either | claude | simple_coding | 1 |
| 02 `refactor(r58-02-orc-desk-pick-steps)` | a function in named steps (`MAX_LINES` 75) | `spl_desk_pick` is 80 lines, at its `LONG` ceiling | `orc:run/spl-desk-reply.func.sh:528` (`spl_desk_pick`) | 1 function | Move one cohesive block into a named helper in the same file so `spl_desk_pick` is at most 75 lines; output, exit codes and globals unchanged. Leave the `LONG` line (row 08; the gate prints a `NOTE LONG`, not a fail: `bash-cleancode.tst.sh:78`). Tests: `orc:tests/desk-actions.tst.sh`, `desk-root-readers.tst.sh`, `enc-dirs-untouched.tst.sh`, `watcher-read-only.tst.sh` (they name the file); `bash iac:tests/bash-cleancode.tst.sh` (a `NOTE LONG` for it after); `cd csi-spl-iac && ./run -a do_check_pre_push_lint` (shellcheck, sigpipe). **Control:** C2 behaviour kept; the lane names one `desk-actions.tst.sh` case that fails with the helper's call deleted, restored. | either | claude | simple_coding | 1 |
| 03 `refactor(r58-03-orc-identity-restore-steps)` | as row 02 | `do_spl_agent_identity_restore` is 80 lines, at its ceiling | `orc:run/spl-agent-identity-restore.func.sh:89` | 1 function | As row 02: at most 75 lines, a named helper in the same file; output, `DRY_RUN` behaviour and exit codes unchanged. Leave the `LONG` line (row 08). Tests: the 6 `orc:features/spawn-agents/tests/test-agent-identity-restore*.sh`, `test-agent-name-shape.sh`, `orc:tests/asks.tst.sh`; `bash-cleancode.tst.sh`; `do_check_pre_push_lint`. **Control:** as row 02, a named `test-agent-identity-restore*.sh` case red with the helper's call deleted, restored. | either | claude | simple_coding | 1 |
| 04 `refactor(r58-04-orc-spawn-worktree-steps)` | as row 02 | `_spawn_worktree` is 79 lines, at its ceiling | `orc:features/spawn-agents/scripts/spawn-core.inc.sh:194` | 1 function | As row 02: at most 75 lines, a named helper in `spawn-core.inc.sh`; the worktree, branch and fetch steps unchanged. Leave the `LONG` line (row 08). Tests: the 15 spawn-agents and orc tests that name `spawn-core.inc.sh` or the function (section 2's grep, `bash-cleancode.tst.sh` aside; `test-spawn-stale-wt-dir.sh`, `test-spawn-fetch-no-prompt.sh`, `test-spawn-reuse-unpushed.sh` name the function); `bash-cleancode.tst.sh`; `do_check_pre_push_lint`. **Control:** as row 02, on `test-spawn-reuse-unpushed.sh` or `test-spawn-stale-wt-dir.sh`, restored. | either | claude | simple_coding | 1 |
| 05 `refactor(r58-05-orc-action-headers-a)` | a header `./run --help` can read (developer guide 2.4.2) | 4 action files parse to no header (section 2) | `orc:run/spl-asks-sync.func.sh`<br>`orc:run/spl-orch-inbox.func.sh`<br>`orc:run/spl-spawn-group-list.func.sh`<br>`orc:run/spl-export-constitution-coding-standards.func.sh`<br>`iac:tests/action-header-tags-baseline.txt` (4 `[missing]` lines) | 4 files, 4 lines | Wrap each file's existing `@description` / `@param` / `@example` lines in a `#---` block right after the shebang (moving any code or plain comment above it below it); add an `@example` only where none is parsed, no other text change; delete the 4 baseline lines. Re-check `grep -ciE '^# *@param.*required'` -> 0 per file before the push. Tests: `bash iac:tests/action-header-tags.tst.sh` (`16 missing` after; it fails while a fixed file is still listed); `orc:tests/asks.tst.sh` (`spl-orch-inbox`), `export-constitution-coding-standards.tst.sh`; `do_parse_metadata <f>` shows a `description=` and an `example=` per file. **Control:** the test's own rule is the red: fix one file, leave its baseline line -> `FAIL ... is listed under [missing] but now has both tags`, then delete it -> pass. | either | claude | simple_coding | 1 |
| 06 `refactor(r58-06-orc-action-headers-b)` | as row 05 | 3 more files | `orc:run/spl-epic-stall-check.func.sh`<br>`orc:run/spl-security-round-queue.func.sh`<br>`orc:run/spl-spawn-fill.func.sh`<br>`iac:tests/action-header-tags-baseline.txt` (3 lines) | 3 files, 3 lines | As row 05. Tests: `action-header-tags.tst.sh` (`13 missing`); `orc:tests/spl-epic-stall-check.tst.sh`, `alarm-kind-note.tst.sh`, `spl-security-round-queue.tst.sh`, `spl-spawn-fill.tst.sh`. Control as row 05. | either | claude | simple_coding | 2 (after 05) |
| 07 `refactor(r58-07-orc-action-headers-c)` | as row 05 | 3 more files | `orc:run/spl-spawn-queue.func.sh`<br>`orc:run/spl-spawn-share.func.sh`<br>`orc:run/spl-lane-map.func.sh`<br>`iac:tests/action-header-tags-baseline.txt` (3 lines) | 3 files, 3 lines | As row 05. Tests: `action-header-tags.tst.sh` (`10 missing`); `alarm-kind-note.tst.sh`, `spl-spawn-share.tst.sh`, `spl-spawn-place-argmax.tst.sh`, `spl-spawn-place-supply.tst.sh`, `lane-map.tst.sh`, `lane-map-dead-role-seat.tst.sh`, `spl-box-pick.tst.sh`, `box-stats-cron.tst.sh`, `apply-gh-runner-cpu-budget.tst.sh`. Control as row 05. | either | claude | simple_coding | 3 (after 06) |
| 08 `test(r58-08-drop-gate-lines-of-r58)` | a gate's list holds no stale line (`r56-08`, `r57-06`) | rows 01-04 leave 5 stale lines | `iac:tests/bash-cleancode.tst.sh:27-29` (`_spawn_worktree`, `do_spl_agent_identity_restore`, `spl_desk_pick`)<br>`go:cleancode/cleancode_test.go:45-46` (`IssueToken` x2); lines as of `1985b986d`, they move when r57-06 lands | 5 lines | Placed only after **r57-06** and rows 01-04 are on trunk (R16); a row not landed keeps its line, and the lane says which. Delete exactly the lines the gates note. Tests: `bash-cleancode.tst.sh` (no `NOTE LONG`; `2 listed`); `go test -count=1 -v ./internal/cleancode/` (no `no longer` log); `run-all-tests.sh`. R9 (a gate's list): `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. **Red control:** delete a still-long line (`spl_fleet_role_tick`) -> the Bash gate fails naming it; delete `(*Memory).CASFleetLease` -> the Go gate fails; both restored. | either | claude | tests | 3 (after r57-06, 01-04) |

### 3.1 Lanes and batches

- **Batch 1: rows 01-05, no file in two rows.** Row 01 owns four `auth/native*` files;
  rows 02, 03, 04 one orc file each; row 05 four orc action files and
  `action-header-tags-baseline.txt`. No row edits a migration, `csi-spl-cnf/`, a
  workflow, terraform, a WUI file or a gate's list.
- **Batch 2: row 06**, and **batch 3: row 07**: each edits
  `action-header-tags-baseline.txt` after the row before it lands (R1, R16).
- **Batch 3: row 08** edits `bash-cleancode.tst.sh` and `cleancode_test.go`; the second
  is **r57-06's** file. Placed within 30 minutes of the last of r57-06 and rows 01-04
  landing (R16).
- Rows 01-04 run the gates but do not edit them.

### 3.2 Off every live lane, every queued row and round 31 (R3)

- **Round 31 (r57-01..06, unlanded):** their written paths, from
  [refactor-round-31-plan.md](refactor-round-31-plan.md) sections 3 and 3.1:
  `auth/audit.go`, `auth/audit_test.go`, `hub/memberactivity.go`,
  `hub/memberactivity_adapter_pin_test.go` (new), `hub/merge.go`,
  `hub/fanout_encode_e16_bench_test.go`, `hub/view.go`, `useCardTopicActions.ts`,
  `MessageCard.vue`, `card-message-actions.test.mjs`, `card-topic-actions.test.mjs`
  (new), `useCardMove.ts`, `card-move-steps.test.mjs`, `cleancode.test.mjs`,
  `cleancode_test.go`. Rows 01-07 write none of them:
  `grep -E '^\| 0[1-7] ' <this file> | grep -cE 'audit|memberactivity|merge\.go|fanout_encode|hub/view\.go|useCard|MessageCard|card-(message|topic|move)|cleancode\.test\.mjs'`
  -> 0. With `cleancode` in place of `cleancode\.test\.mjs` -> 4 rows, every hit a gate
  they run or cite, never write: `bash-cleancode.tst.sh` (not an r57 file; rows 02-04),
  and row 01's `cleancode_test.go:20` citation and `./internal/cleancode/` run. Row 08
  writes `cleancode_test.go` and waits for r57-06.
  `git log origin/master --oneline -E --grep='r57-' | wc -l` -> 0 at
  2026-11-11T17:53:35Z (on `1985b986d`).
- **Lane map: NOT proven free.** `lane-map.sh --check <the written paths of rows 01-08,
  both gate files included, comma separated> --agent c-591`: with
  `spl-spawn-place.func.sh` in the list -> **exit 3** at 2026-11-11T18:05:38Z, owned by
  `c-567@sat c-567-c002-spl5259-issue-follows-discussion` (changed in its worktree), so
  that file is left out (section 2). Without it (19 paths) -> **exit 4** at 18:07:05Z: 0
  paths owned; 9 `unknown:` lanes, all on the other box (not sat), with no files recorded (`c-004`,
  `c-381`, `c-507`, `c-528`, `c-545`, `c-669`, `c-981` rotate lanes, `c-382` csi-rel
  price, `c-770` bug prepush sig control). Exit codes read via `PIPESTATUS`, n=1 each.
  **Exit 4 is not free, and this plan did not clear it**; the holder re-runs the check
  before each row's spawn (R3).
- **Spawn queue (2026-11-11T18:09:07Z):** `do_spl_spawn_queue` -> `32 queued, 1
  placing`; 33 placement slugs. **29 briefs on this box**, grepped for every written
  basename and function of rows 01-08 (`native\.go`, `native_store`, `IssueToken`,
  the ten action file names, `action-header-tags`, `spawn-core\.inc`,
  `_spawn_worktree`, `spl-agent-identity-restore`, `identity_restore`,
  `spl-desk-reply`, `spl_desk_pick`, `bash-cleancode`, `cleancode_test`) -> 1 hit,
  `hand-sat-c002-r57-01-api-pin-auth-event-struct` on `cleancode_test` (round 31,
  above). **4 are not on this box, not grepped:**
  `c002-bug-enqueue-refuses-no-topic-brief`, `c002-bug-gc-exempt-seat`,
  `c002-spl5320-prepush-sig-claude-waiver-reviewer`,
  `hand-sat-c002-bug-agy-review-seat-placed-on-box-without-agy`; the holder greps them
  on sat.
- **Worktrees on this box** (158 in `git worktree list`, 2026-11-11T18:10:42Z): each
  one's `git diff --name-only origin/master...HEAD` plus `git status --porcelain`,
  matched against the 19 paths -> 1 hit, `g-962-r4620` (`spawn-core.inc.sh`; last commit
  `a6078ea15` 2026-11-02, no tmux window: `list-windows -a | grep -c g-962` -> 0): stale
  scratch, not a live lane.

## 4. Per row: what the lane does

- **01:** `IssueToken` takes one `auth.TokenIssue`; both stores and the one caller follow.
- **02:** `spl_desk_pick` in named steps, at most 75 lines.
- **03:** `do_spl_agent_identity_restore` in named steps, at most 75 lines.
- **04:** `_spawn_worktree` in named steps, at most 75 lines.
- **05:** Four action headers parse; their baseline lines go.
- **06:** After 05: three more.
- **07:** After 06: three more.
- **08:** After r57-06 and 01-04: delete the five gate lines they leave.

## 5. Panel and reviewers (R7)

- Editor: c-591 (claude). Both seats sign the plan sha (rulebook 3.2).
- **Panel seat:** an agy seat, cross-vendor as rulebook 3.2 asks, **pinned to the box that has agy** (not sat)
  (sat has no agy). Asked of the dispatch holder (c-002@sat, `LEASE_CMD=show` at
  2026-11-11T18:14Z) on task `dispatch-refactor-r32`. agy reviews this plan only,
  never a row.
- **Row reviewers: same-vendor R7 under waiver 1a7c70da, unless the rule has changed
  when a row is queued.** Re-read here, n=1: `ENV=prd ./run -a do_spl_hub_agent_kinds`
  -> `prd instance agent kinds: off [grok,qwen], paused []` (2026-11-11T18:14:42Z);
  mistral reviews paused (cf7a7ee5); agy takes no code R7. **Not re-read here:** the
  owner's posts since the waiver's last re-check (a body search can miss a garbled
  post); the holder confirms the waiver stands before each row's reviewer is queued.
- **Conditions per row:** the reviewer is a FRESH claude session, never the author and
  never a seat already in the work; it reads only the tree; its brief names waiver
  1a7c70da. Its review line says same-vendor under the waiver, in the `read:` field.
- The waiver does not make a row compliant: rulebook 2.7.5 fails an equal vendor pair,
  and the retro names each such row.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| `send` `WIDE` (`channel.ts:534`) | 30 e2e files (56 calls) plus 7 source call sites and 2 wirings use its positional form; needs an e2e send helper first; **input for a later round** | section 2 |
| a live-store pin of `send` | no unit test loads the channel store (0) | section 2 |
| `CASFleetLease`, `MoveMessage`, `MergeTopic` pairs | 5, 13 and 9 test files call each; over the 5-site cap | section 2 |
| `spl_fleet_role_tick` (`LONG`, 78) | no test names it; needs a pin row first | section 2 |
| the 9 header files with a `(required)` param | parsing their header makes `./run` refuse a call without it: a behaviour change, bug-round input | section 2 |
| `spl-spawn-place.func.sh` header | owned by c-567@sat (lane map exit 3) | section 3.2 |
| `hubclient` `writeAtomic`, `hold` | no small case found | round 30 section 2 |
| Go `longFuncs` | not split here | round 31 section 2 |
| `provision-firebase-dns` long example and `LONG` line | byte-pinned to csi-rel | round 30 section 2 |
| raw text, low packages, slow scanners | not re-measured | section 2 |

## 7. Counts

| metric | n |
|---|---|
| rows | 8 (refactor 7, test 1; Go 1, Bash 6, both gates 1) |
| vendor | claude 8 |
| kind | simple_coding 7, tests 1 |
| batches | batch 1: 5 rows; batch 2: 1; batch 3: 2 |
| Bash `LONG` lines | 5 -> 2 (row 08) |
| Go `wideFuncs` lines | 12 -> 10 (row 08); 4 fewer again once r57-06 lands |
| action header `[missing]` | 20 -> 10 (rows 05-07) |
| measured on | `1985b986d`, n=1 per command unless stated |

## 8. Changes

- v0.1: first draft (c-591): 8 rows, slug `r58`, measured on `1985b986d`. Carries
  round 31's section 6: `send` re-measured and left out again (30 e2e files); the Go
  interface pairs measured (`IssueToken` taken, three left out); the long Bash
  functions measured (three taken, `spl_fleet_role_tick` left out); ten action
  headers taken from the `[missing]` list.

## 9. Consensus

Both seats sign this plan (rulebook 3.2).

- Editor seat: c-591 (claude): drafted v0.1.
- Panel reviewer seat: agy, pinned to the box that has agy: requested.
- Row R7 seats: fresh **claude** sessions, same-vendor R7 under waiver 1a7c70da if it
  still stands at queueing (section 5).
