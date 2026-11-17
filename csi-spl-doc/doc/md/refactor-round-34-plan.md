# Refactoring round 34 - plan (6 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5800  
Topic: 3209f8b8-cdf7-42b3-9018-8376989f9461  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, pushes aim 1 up
  to 3 never more than 5, R1-R16).

**Why now (fresh, measured here).** The holder's brief (c-002@sat, c-001's ruling
a257107a) names the trigger: refactor under its band. Re-read here, n=1 each:
- `cd csi-spl-orc && ./run -a do_spl_spawn_queue` (2026-11-17T14:29:34Z) -> live lanes
  `refactor 3 13% (band 10-20%: ok)`, `last 24 h (131 sample(s)): refactor 8% (band
  20-30%: UNDER)`, `3 queued, 0 placing`, no refactor row queued, `phase day`.
- Round 33 is served on trunk: `git log origin/master --oneline -E --grep='\(r59-[0-9]{2}'`
  -> 7 lines: rows 01-06 of r59 and `76f65baee` (r57-06, whose body names r59); rounds
  31 and 32 too:
  r57-05 `76990f6cc`, r57-06 `76f65baee`, r58-05..08 `6725d4709`, `0380b833e`,
  `0184b4d70`, `c1a54b63f`. **No round 31-33 row is open**, so unlike round 33 this
  plan waits on none.
- The perf floor (rulebook 4.4), the command of 4.4 on `fd9e5a27a` -> `perf 20 refactor
  100 perf-share 16.7% under-20`. Perf round 14 (`p14`, SPL-5795) holds the next slot
  under 4.4; c-001's ruling a257107a runs this round **beside** it, its rows queued
  after p14's, both `SPAWN_CLASS=refactor`. Section 3.2 names the files p14 holds.

Round 34 focus: **two inputs perf round 5's retro routed here, and the two ratchets
SPL-5549 and SPL-5527 opened.** Rows 01-02 take perf-round-5-retro section 5 items 4
(the signed-human predicate written three times) and 5 (`internal/payments` on its
coverage floor). Row 03 empties the `param-required` baseline (3 files, 7 lines).
Rows 04-06 take 10 of the 27 files off the `no-literal-paths` baseline: the
`/var/<org>/<app>` state-dir defaults and two key-file examples, part of the "round 2"
its test header names.

**Status: v0.1, draft.** No row lane starts before the panel signs the plan sha.

Editor: **c-041@sat** (claude). Panel seat: requested, section 5.

**One sha:** every count is measured on **`fd9e5a27a`** (`origin/master`
fd9e5a27a382451896ba01560e25eefcecc040d8, 2026-11-17T13:54:13Z), n=1 per command
unless stated. Go: go1.26.11. Reads are in this lane's worktree at that sha, clean.
Queue, lane and vendor readings are live state, so they carry their own time.

## 1. How to read this

- **Slug prefix `r60`.** On `fd9e5a27a` at 2026-11-17T14:32:32Z, on sat:
  `git log origin/master --oneline -E --grep='r60-' | wc -l` -> 0;
  `git branch -r | grep -c 'r60-'` -> 0;
  `git ls-remote origin 'refs/heads/*r60*' | wc -l` -> 0;
  `grep -rlE 'r60-[0-9]{2}' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote /var/spool-hub/asks | wc -l`
  -> 0. The last slug is taken: `--grep='\(r59-[0-9]{2}'` -> 7; the highest round
  slug in any subject,
  `git log origin/master --format=%s | grep -oE '^[a-z]+\(r[0-9]+-' | grep -oE 'r[0-9]+' | sort -t r -k2 -n | tail -1`
  -> `r59`. No `refactor-round-34*` file under `csi-spl-doc/doc/md`. **Not read:** the
  same spool grep on the other box; the holder runs it there before the first row
  is queued.
- One row = one practice = one lane, at the sites named and nowhere else, with a test
  that shows behaviour kept or, for a test row, a **red control**.
- **Paths:** `go:` = `csi-spl-api/src/go/spool-hub-api/internal/`, `orc:` =
  `csi-spl-orc/src/bash/`, `iac:` = `csi-spl-iac/src/bash/`. Lines as of `fd9e5a27a`;
  a function's site is its first line (R15).
- **Box:** `either` for every row (no pin).
- **Vendor:** claude for every row. **R7 reviewer:** section 5; no seat is named before
  a row is queued.
- **Subject** (R6 reads it): `<type>(r60-NN-<slug>, SPL-<row issue>): ...`.
- **Topic:** every row brief carries the `Topic:` line above.
- **R7 line:** the rulebook 2.7.4 form; box-free in a commit body (SPL-5634).
- **Re-measure first:** every row lane re-runs the command that measured its input in
  section 2 on the `origin/master` it starts from and says in its result if the number
  moved.
- **Tests per row (R2):** listed per row, measured in section 3.3. Go rows add
  `bash csi-spl-api/src/bash/tests/run-all-tests.sh`; a store row adds
  `PRE_PUSH_TIER=full ./run -a do_check_pre_push` (Postgres).
- **What was and was not run:** the commands in sections 2 and 3, n=1. **No red control
  or break named here has been planted by this lane, and no case has been written.**

## 2. Where the rows come from (measured on `fd9e5a27a`)

**Taken:**

| source | input | command on `fd9e5a27a` | n | row |
|---|---|---|---|---|
| perf-round-5-retro 5, item 4 (ask 94ae299e; `perf-round-7-plan.md` routes it here) | the signed-human predicate | `grep -n "m.from_box = 'box-wui' AND m.from_id LIKE 'HUM-%'" go:store/fallback_postgres.go` | **3** lines, `:84`, `:119`, `:152` (227-line file). Its companions repeat too: the channel / to-id clause `:85`, `:120`, `:154` (3); the `c.no_fallback` probe `:86-87`, `:121-122`, `:155-156` (3); the no-agent-reply probe `:125-129`, `:157-161` (2). The retro's `:84 :115 :148` moved; c-101's `:84 :119 :152` (f67ead04e) still holds | row 01 |
| the same | its tests | `git grep -lE 'UnheardPosts\|UnansweredPosts\|ReescalatablePosts\|fallback_postgres' fd9e5a27a -- csi-spl-api` | test files: `go:store/unanswered_test.go`, `go:hub/fallback_test.go`, `relay_test.go`, `relay_retry_test.go`, `message_move_notice_test.go` | row 01 |
| perf-round-5-retro 5, item 5 (ask 94ae299e) | `internal/payments` coverage headroom | `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./internal/payments/`; `grep -n 'internal/payments' csi-spl-api/src/bash/tests/go-coverage-floor.txt` | **84.3%** against floor **84.3** (`:134`): 0.0 points headroom. The retro's 72.4 is gone (r14-06, r16-04 raised it) | row 02 |
| the same | its least-covered functions | `go test -coverprofile=<f> ./internal/payments/ && go tool cover -func=<f> \| sort -k3 -n \| head` | `handler.go:635` `paypalCapture` **45.0%**, `:460` `status` **58.3%**, `:536` `afterPaid` 60.0%, `:580` `fakePay` 60.6%, `:488` `claim` 61.5%; `git grep -nE 'paypalCapture' -- '<payments>/*_test.go'` -> 0 lines | row 02 |
| SPL-5549 (`26d6690b1`, one `(required)` form) | the `param-required` baseline | `grep -vE '^\s*(#\|$)' iac:tests/param-required-baseline.txt` | **7 lines in 3 files**: `orc:run/spl-agent-caps-set.func.sh` (`ENV` `:19`, `CAPS_VENDOR` `:22`, `CAPS_MAX_LIVE` `:23`), `spl-agent-split-show.func.sh` (`ENV`, `TENANT_ID`, at `:11-12` and again `:18-19`), `spl-hub-agent-kinds.func.sh` (`ENV` `:15`, `ORDERED_BY` `:18`, "required when DRY_RUN=0"). Its header: "open in another lane (c-688) on 2026-11-15"; c-688 is in no lane map row today (section 3.2) | row 03 |
| SPL-5527 (`5eff7c9df`; "Round 2 removes the rest", `orc:tests/no-literal-paths.tst.sh:14`) | the `no-literal-paths` baseline | `grep -vE '^\s*(#\|$)' orc:tests/no-literal-paths.baseline \| awk '{s+=$1} END{print NR, s}'`; `grep -nE '/(opt\|var)/csi($\|[^A-Za-z0-9_-])' <file>` per file | **27 files, 52 lines**. 10 files are one pattern, a `${X_DIR:-/var/<org>/<app>/<sub>}` default and its `@param` line, or an `@example` key path: token-burn x3 (6 lines), agent-login x3 + steps-log (8), uplink / wire / box-msg probes (4) | rows 04-06 |
| the same | the derived form already on trunk | `git show 5eff7c9df -- csi-spl-orc/src/bash/run/` | `spl_run_paths` (`csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh`) exports `SPL_VAR_APP_DIR` = `<var>/<org>/<app>`; the actions it changed source it as `declare -F spl_run_paths >/dev/null \|\| source ...` | rows 04-06 |

**Deferred or dropped:**

| source | input | command on `fd9e5a27a` | n | disposition |
|---|---|---|---|---|
| round 33 6 | `send` `WIDE` (`csi-spl-wui/src/stores/channel.ts:540`) | `git grep -cE "(ch\|chStore\|channel\|\('channel'\)\??)\.send\(" fd9e5a27a -- csi-spl-wui/tests/e2e`, summed | **31 files, 57 lines** (round 33: 30, 56) | **Left out**: needs an e2e send helper first, over the cap |
| round 33 6 | `CASFleetLease`, `MoveMessage`, `MergeTopic` (the 6 Go `wideFuncs`, `go:cleancode/cleancode_test.go:41-48`) | `git grep -lE '\b<name>\(' fd9e5a27a -- csi-spl-api/src/go` per name, non-test / test | **3/5, 5/11, 3/9** files | **Left out**: 8 files at the least per pair, over the 5-site cap |
| round 33 6 | the 9 `action-header-tags` `[missing]` files | `grep -ciE '^# *@param.*required' <f>` per file of `iac:tests/action-header-tags-baseline.txt` | all 9 carry a `(required)` param (1..3 each): a header that parses makes `do_validate_params` refuse earlier | **Left out**: behaviour change, bug-round input, as rounds 32-33 |
| round 33 6 | `internal/blob` coverage | `go-coverage-floor.txt:67` | floor 71.9; the GCS store needs a fake | **Left out**, as round 33 |
| this round | the other 17 `no-literal-paths` files | the command above | `spl-spawn-place`, `spl-desk-up`, `spl-lane-rotate`, `spl-watchdog`, `install-box-crons`, `setup-reverse-tunnel`, ... (fleet-critical actions or cron installers, 34 lines) | **Left out**: input for round 35, one family per row |
| round 33 6 | shellcheck SC2034 / SC2154 / vendored `run.sh`; untranslated stale check; `do_provision_firebase_dns`; `hubclient` | not re-measured | none | **Left out / dropped**, as round 33 |

## 3. The 6 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r60-01-store-fallback-signed-human-sql)` | a SQL fragment exists once (developer guide 2.2.4) | the signed-human predicate is written 3 times; a fix to one copy drifts from the others (retro 5 item 4) | `go:store/fallback_postgres.go:84-87` (`UnheardPosts`), `:119-129` (`UnansweredPosts`), `:152-161` (`ReescalatablePosts`) | 1 file, 3 queries | Move the predicate (with the `no_fallback` and no-reply probes) into unexported package `const` fragments in the same file, joined into the three query texts with `+`, so `UnheardPosts` and `UnansweredPosts` send byte-identical SQL and `ReescalatablePosts` the same conjuncts (its `f.delivered_at` line may move inside the `AND` list; nothing else). Placeholders, ORDER BY, LIMIT, results unchanged. Tests: `go test -count=1 ./internal/store/ ./internal/hub/`; `run-all-tests.sh`; store: `PRE_PUSH_TIER=full ./run -a do_check_pre_push` (Postgres runs the `Pg` path). **Control:** C2 behaviour kept; the lane drops `AND m.env_sig <> ''` from the fragment and names the case that goes red on Postgres (expected in `store/unanswered_test.go`; not run here), restored. | either | claude | simple_coding | 1 |
| 02 `test(r60-02-api-payments-capture-status-cases)` | a coverage floor with headroom (developer guide 2.12.5) | `internal/payments` sits on its floor, 84.3 = 84.3 | a new `go:payments/capture_status_test.go`; `csi-spl-api/src/bash/tests/go-coverage-floor.txt:130-134` | 1 new file, 1 floor line | Table cases for the error branches of `paypalCapture` (`handler.go:635`) and `status` (`:460`) through the package's existing fakes (no network, no real key); no product code changes. Raise the floor to the new measure minus 0.5 (n=3 reads, all quoted), its comment updated. Tests: `go test -count=1 -cover ./internal/payments/` x3; `run-all-tests.sh` (its coverage check). R9 (a gate's list): `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. **Red control:** the new floor with the new file removed -> `run-all-tests.sh` fails naming `internal/payments`; restored -> pass. | either | claude | tests | 1 |
| 03 `refactor(r60-03-orc-param-required-form)` | one `(required)` form (developer guide 2.4.2) | 7 baseline lines say required another way | `orc:run/spl-agent-caps-set.func.sh:19-23`<br>`orc:run/spl-agent-split-show.func.sh:11-12,18-19`<br>`orc:run/spl-hub-agent-kinds.func.sh:15-18`<br>`iac:tests/param-required-baseline.txt:4-10` | 3 files, 7 lines | Per param: `# @param NAME (required) - <text>` **only** where the body already refuses an unset NAME on every path, dry run included (the lane quotes the refusing line, e.g. caps-set `:41`, `:43`); else `(optional) - <text>; needed with DRY_RUN=0` (hub-agent-kinds `ORDERED_BY` refuses only then, `:40`). No body change; delete the 7 baseline lines (the header comment stays). An exit code a test pins that would move to `./run`'s 11 keeps that param `(optional)`. Tests: `orc:tests/agent-caps-set.tst.sh`, `agent-split-show.tst.sh`, `hub-agent-kinds.tst.sh`, `spl-lane-mix.tst.sh`, `spl-review-go.tst.sh`; `bash iac:tests/param-required.tst.sh`; `do_check_pre_push_lint`. **Control:** the gate's own rule, before (a fixed param still in the baseline, as the test reports it) and after (deleted -> pass), both outputs in the body. | either | claude | simple_coding | 1 |
| 04 `refactor(r60-04-orc-token-burn-state-dir)` | no literal box path (developer guide 2.3.1) | 3 files default to `/var/<org>/<app>/token-burn` | `orc:run/spl-token-burn-collect.func.sh:19,47,531`<br>`orc:run/spl-token-burn-grok-backfill.func.sh:19,33`<br>`orc:run/spl-token-burn-push-env.func.sh:10`<br>`orc:tests/no-literal-paths.baseline` (3 lines) | 3 files, 6 lines | The default becomes `${TOKEN_BURN_STATE_DIR:-${SPL_VAR_APP_DIR}/token-burn}` after `spl_run_paths` (sourced as `5eff7c9df` does), the action failing when it cannot derive the dir; the `@param` lines name `SPL_VAR_APP_DIR` (spl_run_paths). Delete the 3 baseline lines. Tests: `orc:tests/spl-token-burn-collect.tst.sh`, `-grok-backfill`, `-parse`, `-push-env`, `ws-claude-signin.tst.sh`, `no-literal-paths.tst.sh`, `spl-run-paths.tst.sh`. **Control:** C2: on this box the derived dir equals the old literal (the lane prints both); the ratchet: fixed with the lines kept -> `STALE baseline ... lower it` / `drop its line`; deleted -> pass. | either | claude | simple_coding | 1 |
| 05 `refactor(r60-05-orc-agent-login-state-dir)` | as row 04 | 4 files default to `/var/<org>/<app>/agent-login-check` or `agent-logs` | `orc:run/spl-agent-login-check.func.sh:60,234`<br>`orc:run/spl-agent-login-proof-start.func.sh:17,31`<br>`orc:run/spl-agent-login-proof.func.sh:25,37`<br>`orc:run/spl-agent-steps-log.func.sh:22,49`<br>`orc:tests/no-literal-paths.baseline` (4 lines) | 4 files, 8 lines | As row 04, for `LOGIN_STATE_DIR` and `AGENT_STEPS_LOG_DIR`. Tests: `orc:tests/spl-agent-login-check.tst.sh`, `spl-agent-login-proof.tst.sh`, `spl-agent-steps-log.tst.sh`, `run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `spl-run-paths.tst.sh`. **Control:** as row 04. | either | claude | simple_coding | 2 (after 04: the baseline) |
| 06 `refactor(r60-06-orc-probe-literal-paths)` | as row 04 | the uplink probe's default and two `@example` key paths | `orc:run/spl-uplink-probe.func.sh:40,57`<br>`orc:run/spl-wire-probe.func.sh:50`<br>`orc:run/spl-box-msg-probe.func.sh:49`<br>`orc:tests/no-literal-paths.baseline` (3 lines) | 3 files, 4 lines | Uplink as row 04 (`UPLINK_PROBE_DIR`, `BOX_CRONS_STATE_DIR`); the two examples carry a placeholder (`ROOT_KEY_JSON=<root key file>`), no path. Tests: `orc:tests/spl-uplink-probe.tst.sh`, `spl-probe-actions.tst.sh`, `file-probe.tst.sh`, `file-door-probe.tst.sh`, `file-streams-measure.tst.sh`, `msg-to-db.tst.sh`, `spawn-agents/tests/test-spawn-hub-dns.sh`, `no-literal-paths.tst.sh`; `iac:tests/action-header-tags.tst.sh` (an `@example` changes). **Control:** as row 04. | either | claude | simple_coding | 3 (after 05: the baseline) |

### 3.1 Lanes and batches

- **Batch 1: rows 01-04, no file in two rows.** Row 01 owns
  `store/fallback_postgres.go`; row 02 a new payments test file and
  `go-coverage-floor.txt`; row 03 three orc action files and
  `param-required-baseline.txt`; row 04 three token-burn files and
  `no-literal-paths.baseline`. No row edits a migration, `csi-spl-cnf/`, a workflow,
  terraform or a file under `csi-spl-wui/`.
- **Batch 2: row 05** edits `no-literal-paths.baseline` after row 04 lands (R1);
  placed within 30 minutes of it (R16).
- **Batch 3: row 06**, the same file, after row 05 lands.

### 3.2 Off every live lane, every queued row and perf round 14 (R3)

- **Perf round 14** (`p14`, planner c-025@sat, SPL-5795): its draft on
  `review/c001-perf-round-14-planner` = `5929030f0` (v0.1), read with
  `git diff --stat origin/master...5929030f0` -> 2 files (the plan and its editor seat
  file), and its section 3: **1 row**, `p14-01-wui-unit-pool`, sites
  `csi-spl-wui/src/node/test/run-unit-tests.mjs` (4 edit ranges) and a new
  `csi-spl-wui/tests/unit/unit-runner-pool.test.mjs`; it also runs
  `unit-runner-coverage.test.mjs` and `cleancode.test.mjs`. **Overlap avoided, file by
  file: none.** This round writes no file under `csi-spl-wui/` (the `send` `WIDE` input
  stays left out, partly for that), and p14 v0.1 writes none of this round's paths. A
  later p14 version that adds rows is re-checked by the holder before this round's
  first row.
- **Unlanded round rows** (2026-11-17T14:32:32Z, on `fd9e5a27a`): rounds 31-33 have
  every row on trunk (the "why now"); `--grep='\(r60-'` -> 0.
- **The written paths: 17 distinct**, plus row 02's new test file: row 01 1, row 02 1,
  row 03 4, row 04 3, row 05 4, row 06 3, and `no-literal-paths.baseline` (rows 04-06,
  serialised in 3.1). Each present on `fd9e5a27a`.
- **Lane map from sat: NOT proven free.** `lane-map.sh --check <the 17 paths and
  payments/handler.go, comma separated> --agent c-041` -> **exit 4** at
  2026-11-17T14:29:25Z: 0 paths owned; 15 `unknown:` lanes, all on the other box, with
  no files recorded: 9 `rotate` lanes (`c-060`, `c-390`, `c-528`, `c-545`, `c-570`,
  `c-669`, `c-924`, `c-927`, `c-939`), two blog drafts (`c-054`, `c-714`), `c-161`
  (tf log mask billing id), `c-167` (b11-02 review-go keyword), `c-382` (csi-rel
  delivery price), `c-888` (cost alloc). Exit code read via `PIPESTATUS`, n=1. **Exit 4
  is not free, and this plan did not clear it**; the holder re-runs the check before
  each row's spawn (R3).
- **Spawn queue (2026-11-17T14:29:34Z):** `do_spl_spawn_queue` -> 3 queued
  (`hand-...-feat-invoice-pdf-month-import-f655b326`,
  `c002-feat-s143-b6-api-orc-sync-per-repo`,
  `hand-...-spl5707-member-phone-i18n-agy-review`), 0 placing. All 3 briefs are on this
  box; grepped for every written basename (`fallback_postgres`, `payments`,
  `go-coverage-floor`, the 13 action basenames as `spl-agent-caps-set` ... `box-msg-probe`,
  `param-required-baseline`, `no-literal-paths`) and p14's (`run-unit-tests`,
  `unit-runner`) -> **0 hits** each (14:29:53Z).
- **Worktrees on this box** (245 lines of `git worktree list`, 14:30:04Z): each one's
  `git diff --name-only origin/master...HEAD` plus `git status --porcelain`, matched by
  basename -> 5 hits, none live: `c-635-red`, `c-635-rev` (`auth/handler.go`, a basename
  match only, not row 02's file), `/tmp/g-015-spl5549-r4` (the landed SPL-5549 review),
  `/tmp/g-265-rev-5617` and `-red` (`spl-agent-login-check.func.sh`, review scratch of
  2026-11-15); `tmux list-windows -a | grep -E 'g-015|g-265|c-635'` -> 0.
- **SPL-5527 round 2:** `git log origin/master -E --grep='SPL-5527' --format='%h %s'`
  names `5eff7c9df`; no queued brief names `no-literal-paths` (above). Rows 04-06 are
  the first part of that round 2.

### 3.3 Tests per row, measured (R2, C4)

Rows 03-06 list every test that names a file's bare basename or its `do_*` function
(round 32's section 3.3 command, `NAMES` the row's basenames, on `fd9e5a27a`):

`pat=$(for n in $NAMES; do printf '%s' "|\b$n(\.func\.sh)?([^a-z0-9_-]|\$)|\bdo_${n//-/_}\b"; done); git grep -lE "${pat#|}" fd9e5a27a -- 'csi-spl-orc/**/tests/*' 'csi-spl-iac/**/tests/*' 'csi-spl-utl/**/tests/*' | grep -v baseline`

n=1 each: row 03 -> 5 (`agent-caps-set`, `agent-split-show`, `hub-agent-kinds`,
`spl-lane-mix`, `spl-review-go`, each `.tst.sh`); row 04 -> 5 tests
(`spl-token-burn-collect`, `-grok-backfill`, `-parse`, `-push-env`, `ws-claude-signin`)
and `orc-shard-weights.txt` (not a test); row 05 -> 4 (`spl-agent-login-check`,
`spl-agent-login-proof`, `spl-agent-steps-log`, `run-eager-files`) and
`orc-shard-weights.txt`; row 06 -> 7 (`test-spawn-hub-dns.sh`, `file-door-probe`,
`file-probe`, `file-streams-measure`, `msg-to-db`, `spl-probe-actions`,
`spl-uplink-probe`) and `orc-shard-weights.txt`. Rows 04-06 add
`no-literal-paths.tst.sh` and `spl-run-paths.tst.sh`. Rows 01-02 run their whole Go
packages (section 2).

## 4. Per row: what the lane does

- **01:** The fallback queries' shared SQL is written once; behaviour kept.
- **02:** `paypalCapture` and `status` error cases; the payments floor gets headroom.
- **03:** Three action headers say `(required)` one way; the baseline empties.
- **04:** The token-burn state dir is derived; 3 baseline lines go.
- **05:** After 04: the login-check and steps-log dirs are derived; 4 lines go.
- **06:** After 05: the uplink dir is derived, two examples lose a key path; 3 lines go.

## 5. Panel and reviewers (R7)

- Editor: c-041@sat (claude). Both seats sign the plan sha (rulebook 3.2).
- **Vendor state** (2026-11-17T14:32:51Z, n=1 each):
  `BOX_PICK_KIND=<k> ./run -a do_spl_box_pick` -> grok `pick=hold` (weekly >= 95% on
  both boxes, 99% each); mistral `pick=sat`; agy picks the other box (153% on high 90%;
  sat has no agy), which the queue reads at 201%, past its overflow mark.
- **Panel seat: requested of the holder c-002@sat** (task `dispatch-refactor-r34`):
  one **mistral** doc seat on sat, as p14 seats `m-031@sat`; mistral is allowed docs
  and reviews (owner 10-17, t1 b61851fb msg 91bf8278), and a plan panel is a doc seat
  (c-001 b71016ad: cbada223 / e895dea6 cover a round's plan panel). If the holder rules
  it out, an agy seat when the other box can take it; else the plan waits. The panel
  seat reviews this plan only, never a row.
- **Row reviewers (code R7):** grok holds on both boxes, so a fresh **claude** seat per
  row under waiver 1a7c70da as re-ruled by c-001 on 2026-11-16 (5fb1bdab: claude R7 on
  a claude author while the grok pick holds on both boxes; it lapses on the first grok
  pick). **Not a mistral code R7** (c-001 b71016ad). The holder re-reads the grok pick
  before each row's reviewer is queued.
- **Conditions per row:** the reviewer is a FRESH session, never the author and never a
  seat already in the work; it reads only the tree. A claude reviewer's brief names
  waiver 1a7c70da and its line says same-vendor under the waiver in `read:`; the waiver
  does not make a row compliant (2.7.5 fails an equal pair; the retro names it).
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| `send` `WIDE` (`channel.ts:540`) | 31 e2e files, 57 lines use its positional form; needs an e2e send helper first; also off `csi-spl-wui/` while p14 runs there | section 2 |
| `CASFleetLease`, `MoveMessage`, `MergeTopic` pairs | 3/5, 5/11, 3/9 non-test/test files; over the 5-site cap. A later round may first route each pair's test calls through one helper per package | section 2 |
| the 9 `[missing]` header files with a `(required)` param | a behaviour change: bug-round input | section 2 |
| the other 17 `no-literal-paths` files (34 lines) | fleet-critical actions and cron installers, one family per row: **input for round 35** | section 2 |
| `internal/blob` coverage (71.9) | the GCS store needs a fake | round 33 section 2 |
| `afterPaid`, `fakePay`, `claim` coverage (60-62%) | row 02 takes the two lowest; the rest after it lands | section 2 |
| shellcheck SC2034, SC2154, vendored `run.sh`; untranslated stale check; `do_provision_firebase_dns`; `hubclient` | as round 33 section 6 | round 33 |

## 7. Counts

| metric | n |
|---|---|
| rows | 6 (refactor 5, test 1; Go 2, Bash 4) |
| vendor | claude 6 |
| kind | simple_coding 5, tests 1 |
| batches | batch 1: 4 rows (01-04); batch 2: 1 (05); batch 3: 1 (06) |
| signed-human predicate copies | 3 -> 1 (row 01) |
| `internal/payments` headroom | 0.0 -> above 0 points (row 02) |
| `param-required` baseline | 7 lines in 3 files -> 0 (row 03) |
| `no-literal-paths` baseline | 27 files / 52 lines -> 17 / 34 (rows 04-06) |
| measured on | `fd9e5a27a`, n=1 per command unless stated |

## 8. Changes

- v0.1: first draft (c-041@sat): 6 rows, slug `r60`, measured on `fd9e5a27a`. Carries
  perf-round-5-retro section 5 items 4 and 5 (rows 01-02, ask 94ae299e), the SPL-5549
  and SPL-5527 ratchets (rows 03-06), and round 33's section 6 re-measured. The earlier
  r34 drafts (SPL-5423, SPL-5451) were read as input, not reused. After v1.0 lands, the
  plan is imported as a Qto `system` doc (`do_spl_doctree_import_md`, `QTO_FS=repo`,
  TENANT_ID=t1), as round 33 was (`e49e68a8c`, SPL-5449).

## 9. Consensus

Both seats sign this plan (rulebook 3.2).

- Editor seat: c-041@sat (claude): drafted v0.1.
- Panel reviewer seat: requested (section 5).
- Row R7 seats: section 5.
