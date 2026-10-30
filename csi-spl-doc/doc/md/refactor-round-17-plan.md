# Refactoring round 17 - plan (10 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-4412  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 7f664194 / 8cb6cc7d: 20-30% of the fleet on refactoring
  ([fleet-rules-index.md](fleet-rules-index.md)). On 2026-10-30 the spawn
  queue reads `refactor 1 2% (band 20-30%: UNDER)`
  (`./run -a do_spl_spawn_queue`, n=1).
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 dc15ad65 msg 686bc1a3: **"keep 2 row lanes in parallel"**.
- owner 10-17 (t1 b61851fb): no mistral coding rows; grok off (0d5b1e8a):
  **vendor claude for every row**.
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, pushes
  aim 1 up to 3 never more than 5, R1-R16).

Round 17 focus: **ratchets that only fall** - the TypeScript shims count (and a
cap so it stops sliding back), the unused-exports `ALLOW` list, the gosec,
eslint-security and shellcheck baselines, and Go coverage floors for the 11
packages that have none.

**Status: v1.0 SIGNED** (editor c-910 and claude panel reviewer c-955, on the
v1.0 sha; section 9).

Editor: **c-910** (claude). Panel reviewer: a fresh-session claude seat, placed
by the dispatch lease holder. Dispatch lease holder: the current holder of
`lease.dispatch`.

**One sha:** every count is measured on **`7e94dbf54`** (`origin/master`
7e94dbf5479a2fea74c01b4794b1b28c6d43d43c, 2026-10-30), n=1 per command unless
stated. Inputs: [refactor-round-16-retro.md](refactor-round-16-retro.md)
section 7.

## 1. How to read this

- **Slug prefix `r42`, not `r17`.** This document series (refactor round
  plans) is at 17; the commit-subject series is at 41, because the CI-refactor
  seat cut rounds r17 .. r41 under its own numbers (retro 16, 4.2).
  `git log 7e94dbf54 --oneline -E --grep='r17-[0-9]{2}' | wc -l` -> 12 (r17-01
  .. r17-10 landed 10-22), so `r17-NN` would break R4 and R6.
  `git log origin/master --oneline --grep='r42-' | wc -l` -> 0, and no brief
  under the dispatch or spawn-remote brief dirs names `r42-`
  (`grep -rl 'r42-' ... | wc -l` -> 0). The next slug-series cut takes
  `r43`. **Panel point P1:** confirmed `r42` by the panel (c-955: `r42-` on
  origin/master -> 0).
- One row = one practice = one lane, at the sites named and nowhere else,
  with a test that shows behaviour kept or, for a gate change, a **red
  control**: the check fails on the bad input before the change and passes
  after.
- **Paths:** `wui:` = `csi-spl-wui/`, `orc:` = `csi-spl-orc/`,
  `api:` = `csi-spl-api/`, `go:` = `csi-spl-api/src/go/spool-hub-api/`,
  `/` = the repo root. Lines as of `7e94dbf54`.
- **Box:** the preferred box; the spawner's pick may move a row (no pin).
- **Vendor:** claude for every row (owner 10-17, grok off). R7 reviewer: a
  seat of another vendor (agy), named per row by the dispatch holder at
  placement (rulebook 2.7.2).
- **Subject** (R6 reads it): `<type>(r42-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
- **Re-measure first** (retro 15 change 1): every row lane re-runs its
  measure command on the `origin/master` it starts from and says in its
  result if the number moved.

## 2. Where the rows come from (measured on `7e94dbf54`)

| source | input | command on `7e94dbf54` | n | row / disposition |
|---|---|---|---|---|
| retro 16 7.1 | shims slid 98 -> 103; one leaf | `grep -c 'declare module' csi-spl-wui/src/types/mjs-shims.d.ts`; `cd csi-spl-wui && node src/node/generate-mjs-shims.mjs --leaves` | 103 blocks; 1 leaf (`~/utils/event-delete.mjs`) | **Row 02** (convert the leaf), **Row 09** (cap the count) |
| retro 16 7.2 | stale `ALLOW` entry | `cd csi-spl-wui && node tests/unit/unused-exports.test.mjs` | `NOTE ALLOW: 'src/utils/id-links.mjs' 'resolveTyped' is no longer an unused export`; 33 unused, cap 34 | **Row 01** |
| retro 16 7.3 | Go packages with no floor | `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./...`, then each package looked up in `csi-spl-api/src/bash/tests/go-coverage-floor.txt` | 12 packages with no floor line | **Row 06** (10 of them), **Row 08** (`keyd`); `gcal/fakegcal` (0.0%, a test fake) left out |
| retro 16 7.4 | `internal/keyd` 75.6% | same, plus `go tool cover -func` | 7 functions under 60% | **Row 08** |
| retro 16 7.5 | gosec G115 x4 | `cd csi-spl-api/src/go/spool-hub-api && gosec -include=G115 ./cmd/spool/ ./internal/sign/` (2.22.4) | 4 issues; `.gosec-baseline.txt` `G115\|cmd/spool/hub.go\|2`, `G115\|internal/sign/pubkey.go\|2` | **Row 04** |
| retro 16 7.6 | eslint-security bidi x7 | `grep -v '^#' .eslint-security-baseline.txt` | `security/detect-bidi-characters\|csi-spl-wui/src/utils/mention-autocomplete.mjs\|7`; one regex literal at `:132` | **Row 03** |
| retro 16 7.7 | shellcheck SC2010 / SC2155 in test files | `shellcheck -S warning -f gcc <file>` | SC2010 x5 in 4 files; SC2155 x3 in 2 files | **Row 05** (SC2010), **Row 07** (SC2155) |
| retro 16 4.4 | `cmd/spool` slid 77.1 -> 76.8 | `go test -count=1 -coverprofile=<f> ./cmd/spool/ && go tool cover -func=<f>` | 76.8%; `key.go` 140 of 289 statements covered (48.4%), the least of any file but `hub.go` | **Row 10** (`key.go`; `hub.go` is Row 04's file) |
| retro 16 7.8 | clean-code `LONG` / `wideFuncs` / bash `LONG` | `node csi-spl-wui/tests/unit/cleancode.test.mjs` | `20 listed long, 17 listed wide` | **Left out:** the three ratchet files belong to rounds r40 / r41 (section 6) |

## 3. The 10 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2 bold: source-text tests) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r42-01-wui-ratchet-unused-exports)` | ratchet, dead-code list | `resolveTyped` gained a caller in `5039f423b` (SPL-4330, `NoteLinks.vue:55`); `ALLOW` still lists it and the cap still allows 34 | `wui:tests/unit/unused-exports.test.mjs:53` (the entry)<br>`wui:tests/unit/unused-exports.test.mjs:72` (`ALLOW_CAP`) | 33 unused, cap 34 | Delete the entry, `ALLOW_CAP` 34 -> 33. Tests: **`node tests/unit/unused-exports.test.mjs`**, `pnpm run typecheck`. **Red control:** cap 33 with the entry still listed fails (`ALLOW lists 34 exports, over ALLOW_CAP 33`); paste the line. | sat | claude | simple_coding | 1 (Lane 1) |
| 02 `refactor(r42-02-wui-ts-convert-event-delete)` | TypeScript migration, drop a shim block (SPL-2170) | the one leaf `--leaves` finds; 40 lines; added 10-30 in `0eab294c8` (SPL-4216) | `wui:src/utils/event-delete.mjs` -> `.ts`<br>`wui:src/pages/monitoring/events/index.vue:21,267` (comment, import)<br>`wui:tests/unit/event-log.test.mjs:21` (import)<br>`wui:src/types/mjs-shims.d.ts` (its block) | 103 blocks | Convert with typed exports (`EVENTS_DELETE_MAX`, `deleteEventIds`, `eventsDeleteErrorKey`), update the two importers and the `index.vue:21` comment that names `utils/event-delete.mjs`, drop the block (103 -> 102). Tests: `pnpm run shims:check`, `pnpm run typecheck`, `node tests/unit/event-log.test.mjs`, **`node tests/unit/mjs-shims-exist.test.mjs`**, unit runner. **Red control:** a stale `event-delete.mjs` block left in `mjs-shims.d.ts` makes `shims:check` rc 1. | sat | claude | simple_coding | 1 (Lane 1, after 01) |
| 03 `refactor(r42-03-wui-bidi-regex-escapes)` | name the invisible: escapes, not raw control characters | `BIDI` (`mention-autocomplete.mjs:132`) is a character class written with 7 raw bidi controls, so the eslint security rule needs a baseline line for the file that strips them | `wui:src/utils/mention-autocomplete.mjs:132`<br>`/.eslint-security-baseline.txt` (its one row) | 7 findings | Write the class with `\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069` (the same set: `sed -n 132p <file> \| od -An -tx1` reads U+061C, U+200E, U+200F, U+202A-U+202E, U+2066-U+2069 on `7e94dbf54`); delete the baseline row. Tests: **`node tests/unit/mention-autocomplete.test.mjs`**, `node tests/unit/eslint-gate.test.mjs`, the eslint-security lint part (`./run -a do_check_pre_push_lint`). **Red control:** the row removed with the raw characters still in the file fails the eslint-security part; behaviour: a test name with each control stripped stays green before and after. | PC | claude | simple_coding | 1 (Lane 2) |
| 04 `refactor(r42-04-api-gosec-g115-bounds)` | bounded conversions instead of a baseline | 4 int -> int32/uint32/uint64 conversions kept green only by `.gosec-baseline.txt` | `go:cmd/spool/hub.go:702-703` (`int32(hc.DBMaxConns)`, `int32(hc.DBMinConns)`)<br>`go:internal/sign/pubkey.go:62` (`uint64(len(b)-4)`)<br>`go:internal/sign/pubkey.go:84` (`uint32(len(pub))`)<br>`/.gosec-baseline.txt` (2 G115 rows) | 4 issues | Clamp or check each value before converting (pool sizes to `math.MaxInt32`, lengths against their fixed key size) with no behaviour change for valid input; delete the two G115 rows. `pubkey.go:62` is already guarded by `len(b) < 4` at `:58`: if gosec still flags a correctly bounded form, the lane stops and reports; a `#nosec` in place of the baseline row is not the fix. Tests: `go test -count=1 ./cmd/spool/ ./internal/sign/`, `cd csi-spl-iac && ./run -a do_sec_gosec`. **Red control:** rows deleted with one conversion restored -> the gosec gate fails on that file. | PC | claude | simple_coding | 1 (Lane 2, after 03) |
| 05 `refactor(r42-05-orc-shellcheck-sc2010-tests)` | `ls \| grep` -> globs | 5 SC2010 warnings in 4 test files, held by the WARNING baseline | `orc:src/bash/features/spawn-agents/tests/test-fleet-send.sh:51`<br>`orc:src/bash/tests/db-owner-split.tst.sh:95`<br>`orc:src/bash/tests/host-spool-no-rebuild.tst.sh:82,215`<br>`orc:src/bash/tests/repair-spool-keys.tst.sh:48`<br>`/.shellcheck-warning-baseline.txt` (4 SC2010 rows) | 5 warnings | Replace each with a glob or `compgen -G`; delete the 4 rows. Tests: each of the 4 test files green, the shellcheck lint part. **Red control:** the rows deleted with one `ls \| grep` left fails the shellcheck part; the fix with the rows kept fails too (count below its line, r5-05). | sat | claude | simple_coding | 2 (Lane 1) |
| 06 `test(r42-06-api-coverage-floor-new-packages)` | every Go package has a floor | 12 packages print `NEW` (`gcal/fakegcal` included) and pass at any coverage; 11 apart from the fake, 10 get a floor here (`keyd` in row 08) | `api:src/bash/tests/go-coverage-floor.txt` (10 new lines: `internal/channelmove` 81.1, `enc` 83.6, `gcal` 85.8, `gcpalerts` 91.8, `hygiene` 90.0, `keydesk` 79.1, `keyexec` 79.7, `pollform` 100.0, `secretfile` 100.0, `vendorkey` 82.4) | 10 packages, n=1 each | Measure each n=3, write the floor at the lowest reading, with the header comment naming the go version and sha. Tests: `bash csi-spl-api/src/bash/tests/run-all-tests.sh` (its coverage part prints `ok` for each, no `NEW` left but `keyd` and `gcal/fakegcal`). **Red control:** one floor written 2 points above its reading prints `FAIL - <pkg> ... under its floor`. | PC | claude | tests | 2 (Lane 2) |
| 07 `refactor(r42-07-orc-shellcheck-sc2155-test-libs)` | assign, then export | 3 SC2155 warnings mask a failing command substitution in the spawn-agents test library | `orc:src/bash/features/spawn-agents/tests/lib.inc.sh:50` (x2)<br>`orc:src/bash/features/spawn-agents/tests/test-spool-agent.sh:43`<br>`/.shellcheck-warning-baseline.txt` (2 SC2155 rows) | 3 warnings | Assign, then export: split `export SPOOL_BOX_USER="$(id -un)" SPOOL_AGENT_USER="$(id -un)"` (`lib.inc.sh:50`) and `export SPOOL_BOX_USER="$(id -un)"` (`test-spool-agent.sh:43`); delete the 2 rows. Tests: the spawn-agents tests that source `lib.inc.sh` (`grep -l 'lib.inc.sh' csi-spl-orc/src/bash/features/spawn-agents/tests/*`), `test-spool-agent.sh`, the shellcheck part. **Red control:** as row 05. | sat | claude | simple_coding | 3 (Lane 1, after 05: same baseline file) |
| 08 `test(r42-08-api-coverage-keyd)` | error paths of the key daemon under test | `internal/keyd` 75.6% with no floor; `StateDir` (`store.go:46`) 0.0, `writeNew` (`store.go:516`) 41.2, `readOnce` (`pass.go:128`) 55.6, `InitAgent` (`store.go:79`) 57.1, `writeScrypt` (`store.go:272`) 59.1 | `go:internal/keyd/store.go:46,79,272,516`<br>`go:internal/keyd/pass.go:128`<br>`go:internal/keyd/store_test.go`<br>`go:internal/keyd/pass_test.go`<br>`api:src/bash/tests/go-coverage-floor.txt` (1 new line) | 75.6% | Table tests for the refusals and write errors of those functions (temp dirs, test keys only; no real key, no key path on the box); floor `internal/keyd` at the n=3 reading (target >= 80.0). Tests: `go test -count=1 -race -cover ./internal/keyd/`. **Red control:** drop one error return in `writeNew` -> a new case fails. | PC | claude | tests | 3 (Lane 2, after 06: same floor file) |
| 09 `test(r42-09-wui-shims-cap)` | a cap that only falls, for the shims | shims went 98 -> 103 in 4 days with nothing to stop it (retro 16, 4.1) | `wui:tests/unit/mjs-shims-exist.test.mjs` (a `SHIMS_CAP` and its check) | 102 after row 02 | `SHIMS_CAP` = the count after row 02 (re-measure), failing when `declare module` blocks exceed it and printing a `NOTE` to lower it when under, in `unused-exports.test.mjs`'s style; the FAIL message names the fix (write the new module as `.ts`, or convert a leaf), since the unit runner runs it in every feature lane (`run-unit-tests.mjs:42`). Tests: **`node tests/unit/mjs-shims-exist.test.mjs`**, `pnpm run shims:check`. **Red control:** one planted block over the cap fails with the cap in the message. | sat | claude | tests | 4 (Lane 1, after 02) |
| 10 `test(r42-10-api-coverage-cmd-spool-key)` | CLI key commands under test | `cmd/spool` slid to 76.8% (floor 77.1); `key.go` is 48.4% covered: `cmdKeyRotate` (`:316`) 0.0, `childEnv` (`:428`) 0.0, `rekeyTo` (`:272`) 28.6, `cmdKeyInit` (`:63`) 54.1 | `go:cmd/spool/key.go:63,272,316,428`<br>`go:cmd/spool/key_test.go`<br>`api:src/bash/tests/go-coverage-floor.txt` (the `cmd/spool` line) | 76.8% | Flag and refusal cases for those four (no process start: `startKeyd` and `waitUnlocked` stay out); raise the floor to the n=3 reading (target >= 78.0). Tests: `go test -count=1 -cover ./cmd/spool/`. **Red control:** flip one refusal in `cmdKeyRotate` -> a new case fails. | PC | claude | tests | 4 (Lane 2, after 08: same floor file) |

### 3.1 Lanes and batches

Two row lanes at all times (owner 686bc1a3); disjoint between the two lanes,
shared files serialised inside one lane (R1):
- **Lane 1 (WUI + orc):** 01 -> 02 -> 05 -> 07 -> 09.
- **Lane 2 (Go + baselines):** 03 -> 04 -> 06 -> 08 -> 10.
- Shared files: `.shellcheck-warning-baseline.txt` (05, 07: Lane 1),
  `go-coverage-floor.txt` (06, 08, 10: Lane 2), `mjs-shims.d.ts` /
  `mjs-shims-exist.test.mjs` count (02, 09: Lane 1). Rows 03 and 04 touch
  different baselines (`.eslint-security-baseline.txt`, `.gosec-baseline.txt`).
- No row touches `csi-spl-iac/`, `csi-spl-cnf/`, a migration or a workflow.

### 3.2 Off every live lane (R3)

`lane-map.sh --check <24 row paths, comma separated; `internal/keyd/pass_test.go` not among them> --agent c-910` on
2026-10-30 -> **exit 4**: `no live lane lists <paths>, but 8 live lane(s)
record no files`. The 8: rotate seats c-613@sat, c-653@sat, c-654@sat,
c-656@sat, c-720@sat, and the lanes c-706@sat (`s150-topic-prio-default`),
c-712@sat (`s168-b3-gate`), c-722@sat (`bug-notes-export-name-erase-undo`).
Their briefs are not readable from this box, so their scopes are **unchecked
here**: the spawner asks them (or reads their briefs on sat) before placing
a row, per R3.

Panel note N1 (c-955, later run): `lane-map.sh --check <16 row paths> --agent c-955`
-> **exit 3**: `cmd/spool/hub.go` is owned by c-951
(`c-951-c003-s090-t034-meta-publish-dispatch`, SPL-4424, hunks at `hub.go:145`
and `:308`; row 04 edits `:702-703`). The spawner re-runs lane-map at
placement; row 04 waits for c-951 to land, or talks to it first.

## 4. Per row: what the lane does

- **01:** Delete `['src/utils/id-links.mjs', ['resolveTyped']],` from `ALLOW`; `ALLOW_CAP` 34 -> 33. Nothing else.
- **02:** `git mv` `src/utils/event-delete.mjs` to `.ts` with exact types; update `pages/monitoring/events/index.vue:267` (and its `:21` comment) and `tests/unit/event-log.test.mjs:21` (a test may need the repo's `.ts` import helper; follow `tests/unit/pane-focus.test.mjs` as row r16-01 did); drop its block (103 -> 102).
- **03:** Rewrite `BIDI` with `\u` escapes covering exactly the same code points (prove with a loop over U+0600..U+206F: the same code points match before and after); delete the baseline row. The regex's comment stays true.
- **04:** Bound the 4 conversions (`pubkey.go:62` is already guarded at `:58`: a gosec flag on a bounded form = stop and report, no `#nosec`); no new exported name; delete `G115|cmd/spool/hub.go|2` and `G115|internal/sign/pubkey.go|2`; update the triage comment in `.gosec-baseline.txt` (it names G115 x4).
- **05:** 5 `ls | grep` uses to globs in the 4 test files; delete their 4 baseline rows.
- **06:** 10 floor lines, measured n=3 each, lowest reading.
- **07:** Assign, then export: split the 2 `export X="$(id -un)"` lines (3 warnings); delete 2 baseline rows.
- **08:** Tests for the 5 named `keyd` functions' error paths; add the `internal/keyd` floor line.
- **09:** Add `SHIMS_CAP` to `mjs-shims-exist.test.mjs`, at the count on the row's own `origin/master`; its FAIL message names the fix (`.ts`, or convert a leaf).
- **10:** Tests for the 4 named `key.go` functions; raise the `cmd/spool` floor.

## 5. Panel and reviewers (R7)

- Editor: c-910 (claude). Panel reviewer: a fresh-session claude seat, named
  by the dispatch lease holder. Both sign the plan sha (rulebook 3.2).
- Row reviewers: an agy seat per row, cross-vendor to the claude author
  (`grep -c 'same vendor'` stays 0); lines checked with
  `do_spl_review_line_check`. A row with no reviewer for 15 minutes reports a
  blocker (2.7.3).
- **Panel point P2:** row 09 makes a new `.mjs` module that a `.ts` / `.vue`
  file imports fail the WUI unit tests unless its shim line replaces another.
  That is the point (SPL-2170), but it lands on feature lanes; the panel
  confirms or drops the row. **Confirmed** by the panel (c-955), on
  condition the FAIL message names the fix (write the new module as `.ts`,
  or convert a leaf): `run-unit-tests.mjs:42` runs every
  `tests/unit/*.test.mjs`, so the cap fires in every feature lane.

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| clean-code `LONG` (WUI), `wideFuncs` (Go), bash `LONG` | rounds r40 (cut 10-29) and r41 (cut) hold `csi-spl-wui/tests/unit/cleancode.test.mjs`, `go:internal/cleancode/cleancode_test.go`, `csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`; neither round is on master (`git log 7e94dbf54 --oneline -E --grep='r4[01]-' \| wc -l` -> 0) and neither is in the spawn queue (`do_spl_spawn_queue` lists no `r40` / `r41`), so they may still be placed | `node tests/unit/cleancode.test.mjs` -> `20 listed long, 17 listed wide` |
| the other 4 new shim modules (`channel-feed-core`, `auth-client-core`, `emoji-core`, `topic-list-order`) | not leaves (`--leaves` lists only `event-delete`); landed 10-29 / 10-30 by feature lanes | `node src/node/generate-mjs-shims.mjs --leaves` |
| `internal/gcal/fakegcal` floor | a test fake at 0.0% | `go test -cover ./...` |
| `.semgrep-baseline.txt` math/rand in `internal/hubclient/backoff.go` | retry jitter; not a security use | the baseline's own triage note |
| SC2178 in `spl-desk-welcome.func.sh`, `spl-tenant-test-purge.func.sh` | shellcheck follows a name across functions; no array reassigned | `shellcheck -S warning` |
| `cmd/spool/hub.go` coverage (52.6%) | row 04 edits the file; next round | `go tool cover -func` |

## 7. Counts

| metric | n |
|---|---|
| rows | 10 (refactor 6, test 4; WUI 4, Go 4, orc 2) |
| vendor | claude 10 |
| kind | simple_coding 6, tests 4 |
| batches | 4, two lanes |
| measured on | `7e94dbf54`, n=1 per command |

## 8. Changes

- v0.1: first draft (c-910): 10 rows from retro 16 section 7, slug `r42`.
- v1.0: panel PASS on `c19b76232` (c-955, msg 7b02c992), notes N1-N6 folded
  as wording: N1 the `hub.go` lane in 3.2, N2 row 07 "assign, then export",
  N3 row 06 package count, N4 row 02 `index.vue:21` comment, N5 row 04
  `pubkey.go:62` guard, N6 P2 confirmed with a FAIL message naming the fix;
  P1 `r42` confirmed. Status v1.0 SIGNED.

## 9. Consensus

- Editor seat: c-910 (claude), signs on the v1.0 sha.
- Claude panel reviewer seat: c-955 (claude, fresh session), PASS on c19b76232; signs v1.0 if the diff from c19b76232 is only N1-N6 wording, the status and the changes line.
