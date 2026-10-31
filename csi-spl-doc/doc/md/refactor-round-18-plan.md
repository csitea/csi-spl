# Refactoring round 18 - plan (7 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-4489  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 7f664194 / 8cb6cc7d: 20-30% of the fleet on refactoring
  ([fleet-rules-index.md](fleet-rules-index.md)). On 2026-10-31 the spawn
  queue reads `refactor 1 3% (band 20-30%: UNDER)`
  (`./run -a do_spl_spawn_queue`, n=1).
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 dc15ad65 msg 686bc1a3: **"keep 2 row lanes in parallel"**.
- owner 10-17 (t1 b61851fb): no mistral coding rows; grok off (0d5b1e8a):
  **vendor claude for every row**.
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, pushes
  aim 1 up to 3 never more than 5, R1-R16).

Round 18 focus: **shrink the shellcheck WARNING baseline** (103 rows, 198
findings) by its largest group and its one-line defects, and put the two
least-tested key packages, `internal/lockkey` and `internal/keydesk`, under
test. Seven rows, not ten: every other input of
[retro 17](refactor-round-17-retro.md) section 7 is either a ratchet with
nothing left to do or owned by another round or queued row (section 6).

**Status: v0.2** (panel findings W1-W6 folded; awaiting the re-review by c-779).

Editor: **c-771** (claude). Panel reviewer: a fresh-session claude seat, placed
by the dispatch lease holder. Dispatch lease holder: the current holder of
`lease.dispatch`.

**One sha:** every count is measured on **`7ef011cd8`** (`origin/master`
7ef011cd812b2028c7a4af58e350bc0c2c515056, 2026-10-31), n=1 per command unless
stated. `git diff --stat 7ef011cd8 e3f795f5e -- <every row site>` -> only
`api:src/bash/tests/go-coverage-floor.txt` changed (row r42-10), so the
lines below hold on `e3f795f5e` too. Inputs:
[refactor-round-17-retro.md](refactor-round-17-retro.md) section 7.

## 1. How to read this

- **Slug prefix `r43`.** Round 17's plan reserved it (its section 1).
  `git log 7ef011cd8 --oneline --grep='r43-' | wc -l` -> 0, the same on
  `e3f795f5e` -> 0, and no brief names it:
  `grep -rl 'r43-' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote | wc -l`
  -> 0 at 11:40Z (later this plan's own panel brief names `r43-`, so the
  grep excludes `*round-18*` briefs). **Panel point P1:** confirmed by the
  panel (c-779: `git log origin/master --grep='r43-'` -> 0). The next
  slug-series cut takes `r44`.
- One row = one practice = one lane, at the sites named and nowhere else,
  with a test that shows behaviour kept or, for a gate change, a **red
  control**: the check fails on the bad input before the change and passes
  after.
- **Paths:** `wui:` = `csi-spl-wui/`, `orc:` = `csi-spl-orc/`,
  `iac:` = `csi-spl-iac/`, `api:` = `csi-spl-api/`,
  `go:` = `csi-spl-api/src/go/spool-hub-api/`,
  `sa:` = `csi-spl-orc/src/bash/features/spawn-agents/scripts/`,
  `/` = the repo root. Lines as of `7ef011cd8`.
- **Box:** the preferred box; the spawner's pick may move a row (no pin).
- **Vendor:** claude for every row (owner 10-17, grok off). **R7 reviewer:
  a fresh-session claude seat** per row, named by the dispatch holder at
  placement, under the same claude-only waiver round 17 ran on (retro 17,
  4.1); each review line names the author's vendor too.
- **Subject** (R6 reads it): `<type>(r43-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
- **Re-measure first:** every row lane re-runs its measure command on the
  `origin/master` it starts from and says in its result if the number moved.
- **Tests per row (R2):** every test file that names a site's basename
  (`git grep -l -F <basename> 7ef011cd8 -- '*tst.sh' '*/tests/*' '*test*.sh'`),
  counted per row below; `sa-t:` = `orc:src/bash/features/spawn-agents/tests/`,
  whose `run-all-tests.sh` runs them all.
- **The baseline rule** (r5-05, round 17 rows 05 and 07): the shellcheck
  gate (`cd csi-spl-iac && ./run -a do_sec_shellcheck`, also the shellcheck
  part of `./run -a do_check_pre_push_lint`) fails both when a file has more
  findings than its baseline row and when it has fewer. A fix and its
  baseline row change land in **one** commit.

## 2. Where the rows come from (measured on `7ef011cd8`)

| source | input | command on `7ef011cd8` | n | row / disposition |
|---|---|---|---|---|
| retro 17 7.1 | SC2034 x62 in the 9 spawn / restore adapters | `shellcheck -S warning -f gcc sa:<file>`; the baseline rows | 9 rows, 62 findings | **Row 04** (4 spawn adapters, 32), **Row 05** (5 restore adapters, 30) |
| retro 17 7.2 | literal words read as code | same | SC2100 x1, SC2209 x1, SC1010 x2 | **Row 01** |
| retro 17 7.2 | unguarded expansions | same | SC2115 x1, SC2206 x1 | **Row 02** |
| retro 17 7.2 | `VAR= cmd` read as a typo | same | SC1007 x3 | **Row 03** |
| retro 17 7.3 | `internal/lockkey` 76.7% | `cd go: && go test -count=1 -cover ./internal/lockkey/` (n=2), `go tool cover -func` | 4 functions under 60% | **Row 06** |
| retro 17 7.4 | `internal/keydesk` 79.1% | same, `./internal/keydesk/` (n=2) | 6 functions under 60% | **Row 07** |
| retro 17 7.5 | `cmd/spool` 77.8 vs target 78.0 | the floor file's comment on `e3f795f5e` | 1 | **Left out:** `hub.go` is named by a queued row (section 6) |
| retro 17 7.6 | shims, unused exports, SFC size, tmp-path, eslint-security | the round 17 retro's commands | 102 / 0 leaves; 33 at cap 33; 0; 0; 0 | **Left out:** nothing to lower |
| retro 17 7.7 | `run.sh`, G101, semgrep, clean-code, `blob`, `-x` scan | see section 6 | | **Left out** |

## 3. The 7 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2 bold: source-text tests) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r43-01-orc-shellcheck-quote-literals)` | quote a literal word | shellcheck reads `box=box-wui` as arithmetic, `=test` as a command, `== done` as the loop keyword | `orc:src/bash/tests/dispatch-inbound-pg.tst.sh:71` (SC2100)<br>`orc:lib/bash/funcs/spl-stripe.func.sh:71` (SC2209)<br>`orc:src/bash/tests/lane-map.tst.sh:249` (SC1010)<br>`orc:src/bash/tests/spec-import-issues.tst.sh:506` (SC1010)<br>`/.shellcheck-warning-baseline.txt` (4 rows) | 4 findings | Quote each word (`box='box-wui'`, `SPL_STRIPE_MODE='test'`, `== 'done'`); delete the 4 rows. Tests: the 3 test files green; `git grep -l 'spl-stripe\|SPL_STRIPE_MODE' 7ef011cd8 -- '*tst*' '*test*'` -> two docs under `refactor-round-3/`, `iac:src/bash/tests/bash-cleancode.tst.sh` and `orc:src/bash/run/spl-checkout-stripe-test-buy.func.sh` (not a test: `*test*` matches its name; it reads `SPL_STRIPE_MODE` at `:54`), so no test sources `spl-stripe.func.sh`: `bash -n` on it and the reviewer reads the one-line diff (a `case` arm, no key read); `sa-t:test-spawn-lane-files.sh` (names `lane-map.tst.sh`); the 3 shellcheck gate tests (`iac:src/bash/tests/sec-shellcheck.tst.sh`, `sec-shellcheck-par.tst.sh`, `check-pre-push-lint.tst.sh`: they name the baseline file), `./run -a do_sec_shellcheck`. **Red control:** rows deleted with one word unquoted fails the shellcheck gate. | sat | claude | simple_coding | 1 (Lane 1) |
| 02 `refactor(r43-02-orc-shellcheck-guarded-expansions)` | guard what expands into `rm` or an array | `rm -rf "$T/root"` with `T` empty deletes `/root`; `ENVS=(${ENVN//,/ })` globs each word | `orc:src/bash/tests/repair-spool-keys.tst.sh:26` (SC2115)<br>`sa:spool-agent.sh:135` (SC2206)<br>`/.shellcheck-warning-baseline.txt` (2 rows) | 2 findings | `rm -rf "${T:?}/root" "${T:?}/home"`; `IFS=, read -ra ENVS <<<"$ENVN"` (the same words on every value that reaches `:135`: `spool-agent.sh:97` admits only `dev`, `prd`, `self`, `dev,prd`, `prd,dev`, and `:133` turns an empty value into `dev`); delete the 2 rows. Tests: `repair-spool-keys.tst.sh`; the 6 that name `spool-agent.sh`: `sa-t:test-spool-agent.sh`, `sa-t:test-desk-box-default.sh`, `sa-t:test-desk-user-hops.sh`, `sa-t:test-harness-parity.sh`, `orc:src/bash/features/spool-install/tests/test-install.sh`, `orc:src/bash/tests/desk-up-caller.tst.sh`; the 3 shellcheck gate tests (`iac:src/bash/tests/sec-shellcheck.tst.sh`, `sec-shellcheck-par.tst.sh`, `check-pre-push-lint.tst.sh`: they name the baseline file), `./run -a do_sec_shellcheck`. **Red control:** as row 01; behaviour: `ENVN='dev,prd'` and `ENVN='self'` give the same `ENVS` before and after (values outside `:97`, e.g. `'A,,B'`, would differ but cannot reach the line). | sat | claude | simple_coding | 2 (Lane 1, after 01) |
| 03 `refactor(r43-03-iac-shellcheck-empty-assign)` | write an empty value as `''` | `GOFLAGS= GOPROXY=...` and `SEC_SCAN= SEC_SCAN_ROOT=...` read as a mistyped space | `iac:src/bash/run/install-lint-tools.func.sh:194`<br>`iac:src/bash/tests/sec-scan.tst.sh:53,57`<br>`/.shellcheck-warning-baseline.txt` (2 rows) | 3 findings | `GOFLAGS=''`, `SEC_SCAN=''`; delete the 2 rows. Tests: `bash csi-spl-iac/src/bash/tests/sec-scan.tst.sh`; the 2 that name `install-lint-tools.func.sh`: `iac:src/bash/tests/satellite-ansible.tst.sh`, `orc:src/bash/tests/curl-time-bounded.tst.sh`; the 3 shellcheck gate tests (`iac:src/bash/tests/sec-shellcheck.tst.sh`, `sec-shellcheck-par.tst.sh`, `check-pre-push-lint.tst.sh`: they name the baseline file), `./run -a do_sec_shellcheck`. **Red control:** as row 01. | sat | claude | simple_coding | 3 (Lane 1, after 02) |
| 04 `refactor(r43-04-orc-shellcheck-spawn-adapter-directive)` | one file-wide directive for declarations a sourced core reads | 32 SC2034 findings: the `SPAWN_*` lines are read by `spawn-core.inc.sh`; `spawn-mistral.sh:31` already does this and has no baseline row | `sa:spawn-claude.sh:11` (`set`; warns 13-20)<br>`sa:spawn-agy.sh:11` (warns 13-20)<br>`sa:spawn-grok.sh:11` (warns 13-20)<br>`sa:spawn-qwen.sh:15,30` (warns 17-28; its `:30` directive covers one line)<br>`/.shellcheck-warning-baseline.txt` (4 rows) | 32 findings | Put `# shellcheck disable=SC2034  # the SPAWN_* declarations are read by spawn-core.inc.sh` directly above `set -uo pipefail` (before the first command, so it covers the file), drop `spawn-qwen.sh:30`'s one-line copy; delete the 4 rows. No other line changes. Tests: `sa-t:run-all-tests.sh` (holds the 16 that name `spawn-claude.sh`, `test-spawn-dry-run.sh` and `test-spawn-requester.sh` for grok and qwen, `test-tmux-close-window.sh` for agy); `orc:src/bash/tests/dispatch-setup-check.tst.sh`, `lane-rotate.tst.sh`, `spl-lane-handover-agy.tst.sh`; the 3 shellcheck gate tests (`iac:src/bash/tests/sec-shellcheck.tst.sh`, `sec-shellcheck-par.tst.sh`, `check-pre-push-lint.tst.sh`: they name the baseline file), `./run -a do_sec_shellcheck`. **Red control:** the directive placed after the first assignment (where `restore-claude.sh:16` has it) leaves warnings, so the gate fails with the rows deleted. | sat | claude | simple_coding | 4 (Lane 1, after 03) |
| 05 `refactor(r43-05-orc-shellcheck-restore-adapter-directive)` | as row 04, for the restore adapters | 30 SC2034 findings; `restore-claude.sh:16`, `restore-grok.sh:16` and `restore-qwen.sh:14` carry the directive after the first assignments, so it covers one line (claude and grok still warn at 11-15 and 19, qwen at 8-12 and 17); `restore-mistral.sh:37` has it right | `sa:restore-claude.sh:10` (`set`)<br>`sa:restore-claude-plain.sh:7`<br>`sa:restore-agy.sh:7`<br>`sa:restore-grok.sh:10`<br>`sa:restore-qwen.sh:7`<br>plus `/.shellcheck-warning-baseline.txt` (5 rows) | 30 findings | Move or add the directive above `set -uo pipefail` (`# ... the RESTORE_* declarations are read by restore-core.inc.sh`), remove the misplaced one-line copies; delete the 5 rows. On a scratch copy, `restore-claude.sh` goes 6 -> 0. Tests: `sa-t:run-all-tests.sh` (holds the 8 `sa-t:` tests that name `restore-claude.sh`, `test-agent-name-shape.sh` for claude-plain, `test-agent-identity-restore-grok.sh` for grok; none names `restore-qwen.sh`); `orc:src/bash/tests/spl-lane-handover.tst.sh`, `wd-heldout-hand-restore.tst.sh`, `spl-lane-handover-agy.tst.sh`; the 3 shellcheck gate tests (`iac:src/bash/tests/sec-shellcheck.tst.sh`, `sec-shellcheck-par.tst.sh`, `check-pre-push-lint.tst.sh`: they name the baseline file), `./run -a do_sec_shellcheck`. **Red control:** as row 04. | sat | claude | simple_coding | 5 (Lane 1, after 04) |
| 06 `test(r43-06-api-coverage-lockkey)` | the lock daemon's liveness and write errors under test | `internal/lockkey` 76.7%: `HolderAlive` (`daemon.go:329`) 0.0, `readPID` (`:333`) 42.9, `pidAlive` (`:345`) 50.0, `writeFile` (`store.go:282`) 44.4 | `go:internal/lockkey/daemon.go:329,333,345`<br>`go:internal/lockkey/store.go:282`<br>`go:internal/lockkey/lockkey_test.go`<br>`api:src/bash/tests/go-coverage-floor.txt` (the `internal/lockkey` line) | 76.7% | Table tests: no pid file, a garbage pid file, a dead pid, this test's own pid; `writeFile` into a read-only temp dir, skipped when `os.Geteuid() == 0` (root writes anyway) (temp dirs and test keys only, no key path on the box). Raise the floor to the n=3 reading, no fixed target (retro 17, 4.2). Tests: `go test -count=1 -race -cover ./internal/lockkey/`, `bash csi-spl-api/src/bash/tests/run-all-tests.sh` (coverage part `ok`). **Red control:** make `readPID` return 0 for a valid file -> a new case fails. | sat | claude | tests | 1 (Lane 2) |
| 07 `test(r43-07-api-coverage-keydesk)` | the key desk's refusals and peer check under test | `internal/keydesk` 79.1% (floor 79.1): `Run` (`keydesk.go:374`) 0.0, `(*Refused).Error` (`:102`) 0.0, `DefaultPeerOK` (`peer_linux.go:44`) 0.0, `procGroups` (`:82`) 0.0, `IdentityPath` (`seal.go:86`) 0.0 | `go:internal/keydesk/keydesk.go:102,374`<br>`go:internal/keydesk/peer_linux.go:44,82`<br>`go:internal/keydesk/seal.go:86`<br>`go:internal/keydesk/keydesk_test.go`<br>`api:src/bash/tests/go-coverage-floor.txt` (the `internal/keydesk` line) | 79.1% | Tests for the refusal text, the peer check: `ParseStatusGroups` / `procGroups` on fixed and own `/proc` input, and `DefaultPeerOK` on this test process with the expected result computed from the same inputs (an error iff `RootEquivalentIn(<this box's /etc/group>, <own gids>) != ""`; the uid running the test may be in `docker` or `sudo`, which `groups.go:10` refuses), plus a peer that does not match via `deskUIDOver`, the identity path, and `Run` stopping on a cancelled context; no real hub, no key on the box. Raise the floor to the n=3 reading. Tests: `go test -count=1 -race -cover ./internal/keydesk/`, `run-all-tests.sh`. **Red control:** `DefaultPeerOK` accepting any uid -> a new case fails. | sat | claude | tests | 2 (Lane 2, after 06: same floor file) |

### 3.1 Lanes and batches

Two row lanes at all times (owner 686bc1a3); disjoint between the two lanes,
shared files serialised inside one lane (R1):
- **Lane 1 (shellcheck):** 01 -> 02 -> 03 -> 04 -> 05. All five edit
  `.shellcheck-warning-baseline.txt`, so they run one after another. After
  all five: 103 -> **86** rows, 198 -> **127** findings.
- **Lane 2 (Go tests):** 06 -> 07, both edit `go-coverage-floor.txt`.
- Row 03 is the only row under `csi-spl-iac/`, and only in a `.func.sh`
  line and a test. No row touches `csi-spl-cnf/`, a migration, a workflow
  or terraform.

### 3.2 Off every live lane (R3)

`lane-map.sh --check <the 26 row paths, comma separated> --agent c-771` on
2026-10-31 (~11:40Z) -> **exit 4**: `no live lane lists <paths>, but 17
live lane(s) record no files`, all on the other box. Seven are rotate seats (c-029,
c-601, c-765, c-862, c-866, c-934, c-988). Nine are lanes whose briefs in
`/var/spool-hub/dispatch/briefs/` name none of the sites
(`grep -cE '<site basenames>|shellcheck|lockkey|keydesk|go-coverage-floor'`
-> 0 each): c-285, c-584, c-624, c-625, c-630, c-634, c-635, c-636 and
c-894. The last, c-633 (`c-633-c001-refactor-round-18-planner`), carries
this plan's own slug: a duplicate placement, reported to c-001 (msg
5b1878e3), which closed and retired it at 11:42Z with nothing committed
(msg b0b0102b). The panel's re-run (c-779, later) read 17 again with c-628 and c-638 new and
c-633, c-635 gone, each brief grep 0. The rotate seats' scopes are **unchecked here**: the spawner asks
them before placing a row, per R3.

The spawn queue (`./run -a do_spl_spawn_queue`, 20 queued + 1 placing):
the same grep over each row's brief -> 0 for all 21. Rows r42-09
(`wui:tests/unit/mjs-shims-exist.test.mjs`) and r42-10 (`go:cmd/spool/key.go`,
`key_test.go`, `go-coverage-floor.txt`) landed on `bd893cc8a` / `7544ccfb0`,
so the floor file is free again; rows r40-01..03 landed; no row here
touches their files.

## 4. Per row: what the lane does

- **01:** Quote the 4 literal words; delete their 4 baseline rows.
- **02:** `${T:?}` on the `rm -rf` line; `read -ra` for `ENVS`; delete 2 rows.
- **03:** `GOFLAGS=''` and the two `SEC_SCAN=''`; delete 2 rows.
- **04:** One file-wide SC2034 directive above `set` in the 4 spawn adapters (qwen's one-line copy removed); delete 4 rows.
- **05:** The same in the 5 restore adapters (3 misplaced copies moved); delete 5 rows.
- **06:** Tests for the 4 named `lockkey` functions; raise the floor to the n=3 reading.
- **07:** Tests for the 5 named `keydesk` functions; raise the floor to the n=3 reading.

## 5. Panel and reviewers (R7)

- Editor: c-771 (claude). Panel reviewer: a fresh-session claude seat, named
  by the dispatch lease holder. Both sign the plan sha (rulebook 3.2).
- Row reviewers: a fresh-session claude seat per row (section 1); lines
  checked with `do_spl_review_line_check`. A row with no reviewer for 15
  minutes reports a blocker (2.7.3).
- **Panel point P1:** confirm `r43` (section 1).
- **Panel point P2:** rows 04 and 05 silence SC2034 for a whole file. That
  also hides a truly unused variable added later to one of the 9 adapters.
  The adapters are declaration lists by design (`restore-mistral.sh:37`,
  `spawn-mistral.sh:31` already do this); the panel confirms the trade or
  asks for per-line directives instead. **Accepted** by the panel (c-779):
  the baseline header's own triage says SC2034 is often read by a sourcing
  caller; the directive's comment must say so (C5). Optional, not a
  condition: a test that every `SPAWN_*` / `RESTORE_*` an adapter declares
  is read in its core, so a truly unused one is still caught.

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| `run.sh` SC2155 / SC2164 / SC2046 / SC2319 (iac, orc, utl) | the baseline header says it is vendored from upstream unchanged; the 3 copies are one file (md5 `38f8b97c`) | `md5sum */run.sh`; the baseline's header |
| `cmd/spool` coverage (77.8, target 78.0 missed) | the remaining gap is in `hub.go`, which the queued row `c002-api-err-r45-shutdown-drain` names | its brief; `go tool cover -func` |
| clean-code `LONG` / `wideFuncs` / bash `LONG` | rows r41-01..03 are briefed (`c003-r41-*`) and hold the three ratchet files; not on master, not queued | `node tests/unit/cleancode.test.mjs` -> `19 listed long, 17 listed wide` |
| gosec G101 x4, semgrep math/rand x1 | triaged false positives (the baselines' own notes) | `.gosec-baseline.txt`, `.semgrep-baseline.txt` |
| `internal/blob` 71.9% | the uncovered part is the GCS backend; needs a fake first | `go tool cover -func` |
| shims, unused exports, SFC size, tmp-path, eslint-security | nothing to lower: 102 with 0 leaves; 33 at cap 33; 0 over 500; 0; 0 | the round 17 retro's commands |
| shellcheck `-x -P SCRIPTDIR` (follow sourced files) in the gate | whole-tree run > 15 min against 6.5 min plain, then stopped for low box memory | one run, n=1, no result |
| `internal/gcal/fakegcal` floor | a test fake at 0.0% | `go test -cover ./...` |

## 7. Counts

| metric | n |
|---|---|
| rows | 7 (refactor 5, test 2; orc 4, iac 1, Go 2) |
| vendor | claude 7 |
| kind | simple_coding 5, tests 2 |
| batches | 5 in Lane 1, 2 in Lane 2 |
| shellcheck baseline after Lane 1 | 103 -> 86 rows, 198 -> 127 findings |
| measured on | `7ef011cd8`, n=1 per command unless stated |

## 8. Changes

- v0.1: first draft (c-771): 7 rows from retro 17 section 7, slug `r43`.
- v0.2: panel review FAIL on `2ba756a05` (c-779, msg 78b88eeb), findings
  W1-W6 folded: W1 row 07 peer test computes its expectation from
  `/etc/group`; W2 every test that names a site, per row; W3 row 05 one
  site per adapter, qwen's warn lines; W4 row 01 quotes the real grep
  output; W5 row 02 cites `:97` and tests reachable values; W6 row 06 skips
  the read-only case as root. P1 `r43` and P2 confirmed.

## 9. Consensus

- Editor seat: c-771 (claude).
- Claude panel reviewer seat: c-779 (claude, fresh session), FAIL on
  `2ba756a05` (W1-W6; P1 and P2 confirmed); re-reviews v0.2.
- v1.0 SIGNED after c-779's PASS; landed after the dispatch holder's GO.
- Dispatch holder: GO on the review diff, then ACCEPTED on origin/master.
  Rows follow without an owner go (rulebook).
