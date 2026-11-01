# Refactoring round 21 - plan (10 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-4577  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 7f664194 / 8cb6cc7d: 20-30% of the fleet on refactoring
  ([fleet-rules-index.md](fleet-rules-index.md)).
- msg b8e22a15: reach consensus in the panel and start, no owner input;
  msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 dc15ad65 msg 686bc1a3: **"keep 2 row lanes in parallel"**: rows 01-09
  share no file (section 3.1), so any two of them can run at once.
- owner 10-17 (t1 b61851fb): no mistral coding rows: **vendor claude for
  every row**. Code reviews grok or claude only (msg cf7a7ee5).
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, pushes
  aim 1 up to 3 never more than 5, R1-R16).

**Why now.** The fleet's refactor share is under its band: c-001@sat
blocker 1a7cff23 (task spawn-share, 2026-11-01T22:2xZ): refactor 16%, 4 of
24 classed live lanes, and no refactor row queued. Round 20
([plan](refactor-round-20-plan.md), v1.0) has rows 06 and 07 on master
(`git log 2acffb02e -E --grep='r46-0[0-9]' --format='%h %s'` -> 2:
`a012b7a71` r46-07, `bc2a481da` r46-06); since then row 08 landed too
(`5cc8ead51` on `b4cefd7b4`, same command). Rows 01 and 09 run on the other
box (lanes c-171, c-186), and rows 02-05 wait behind row 01 (one shared
baseline): open round 20 rows are 01-05 and 09. **No round 20 retro yet**: not due while rows are open
(rulebook 2.8). This plan re-measures round 20's section 6 inputs (section
2) and takes only what does **not** wait on an open round 20 row.

Round 21 focus: **every row but the last can run at once**. Three rows
split six bash functions over the 75-line cap, one splits two WUI
composables one line over it, five put small untested Go functions under
test (among them the box key loader and the key desk's defaults), and one
closing row deletes the clean-code list lines the split rows leave stale.

**Status: v0.2 DRAFT**, for the panel.

Editor: **c-908** (claude; agy is out of quota until 2026-11-03T12:42Z and
claude is the specs_and_docs backup). Panel reviewer: a cross-vendor grok
seat placed by the dispatch lease holder (the claude-only waiver 1a7c70da
ended). Dispatch lease holder: the current holder of `lease.dispatch`.

**One sha:** every count is measured on **`2acffb02e`** (`origin/master`
2acffb02ed72cea8d2cbeeb1a0aa2ff5f577075c, 2026-11-01T22:22Z), n=1 per
command unless stated. Go: go1.26.10. Box: sat. Bash, Go and WUI runs are
on a `git archive 2acffb02e` copy, never on a live checkout.

## 1. How to read this

- **Slug prefix `r47`.** `git log 2acffb02e --oneline -E --grep='r47-' | wc -l`
  -> 0; `grep -rl 'r47-' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote | wc -l`
  -> 0 (2026-11-01T22:5xZ). No r47 lane. The next planner proves its
  prefix free the same way, and discounts briefs that only quote the search.
- One row = one practice = one lane, at the sites named and nowhere else,
  with a test that shows behaviour kept or, for a test row, a **red
  control**: the new case fails on a planted defect and passes after.
- **Paths:** `iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`,
  `utl:` = `csi-spl-utl/`, `wui:` = `csi-spl-wui/`,
  `go:` = `csi-spl-api/src/go/spool-hub-api/`; `run/` = `src/bash/run/`,
  `t/` = `src/bash/tests/` of the sub-project named. Lines as of
  `2acffb02e`; a bash or WUI site's line is the function's first line.
- **Box:** the preferred box; the spawner's pick may move a row (no pin).
- **Vendor:** claude for every row. **R7 reviewer:** a cross-vendor seat
  per row (grok on a claude author while grok has quota), named by the
  dispatch holder at placement. Each review line names the author's vendor.
- **Subject** (R6 reads it): `<type>(r47-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
- **Re-measure first:** every row lane re-runs its measure command on the
  `origin/master` it starts from and says in its result if the number moved.
- **Tests per row (R2):** every test file that names a site's basename or a
  function it defines
  (`git grep -l -F -e <basename> -e <function> 2acffb02e -- '*tst.sh' '*/tests/*' '*test*.sh'`),
  listed per row; for Go, the package's tests; for WUI, the unit tests
  that read the file's source and the e2e files the pre-push map selects.
- **The clean-code lists only NOTE a stale line.** All three gates
  (`iac:t/bash-cleancode.tst.sh` `LONG`, `wui:tests/unit/cleancode.test.mjs`
  `LONG`, Go `cleancode_test.go` `longFuncs`) fail a function over the cap
  that is not listed, or over its ceiling, but print only a `NOTE` for a
  listed function now under the cap (`check_long` in the bash test, the
  `notes` of the WUI test, `staleKeys` in Go). So a split row needs **no
  edit to the gate file**: rows 01-04 leave their lines, and row 10 deletes
  every stale line in one commit, after them. That is what lets rows 01-04
  share batch 1 (R1): otherwise all three bash rows would edit one file.

## 2. Where the rows come from (measured on `2acffb02e`)

| source | input | command on `2acffb02e` | n | row / disposition |
|---|---|---|---|---|
| round 20 6 | 16 more declare-first iac files, movable once row 01's loader lands | `awk '/^#-+$/{exit} /^declare -F .*\|\| source/{f=1; exit} END{exit !f}'` over the iac, orc, utl run dirs | **37**: reproduces (rows 02-05 not landed) | **Deferred**: each needs r46-01's loader (`git log 2acffb02e --grep='r46-01' --oneline \| wc -l` -> 0) and edits `iac:t/action-header-tags-baseline.txt`, which rows 02-05 hold in turn |
| round 20 6 | `gcp-002-delete-project-service-account`, `gcp-export-dns-settings` (also need an `@example`) | as above | 2: reproduce | **Deferred**: same reason |
| round 20 6 | the 4 long-example files after row 01 | `bash iac:t/action-header-tags.tst.sh` | `measured 765 files: 55 missing, 31 long-example`: row 01 not landed, so still 31 | **Deferred**: they wait on row 01, and their fix deletes `[long-example]` lines of the shared baseline |
| round 20 6 | the `(required)` files in `[missing]` | `grep -ciE '^# *@param .*\(required\)'` on the 55 | **9**: reproduces | **Left out**: a bug-round input, as round 20 said |
| round 20 6 | floor raises for `marketing`, `wire`, `hubclient`, `payments` | `cd go: && go test -count=1 -coverprofile=c.out ./...` (no DSN) | `marketing` 84.2 (83.9 before r46-06), `wire` 87.4 (84.5 before r46-07), `hubclient` 83.5, `payments` 80.9 (rows 08, 09 open); `git log 2acffb02e --grep='r44-09' --oneline \| wc -l` -> 0 | **Deferred**: `go-coverage-floor.txt` is held by round 19 row 09 (brief rule) and two of the four rows are open; input for round 22 |
| round 20 6 | `internal/keydesk` `logf` | the same run | 50.0: reproduces; also `peerOK` 66.7 | **Row 08** |
| round 20 6 | `cmd/spool` 77.8, `store` 47.7, `repodocs` 55.8, `auth` 80.4 | the same run | reproduces (store 47.5 -> 47.7) | **Left out**: Postgres or the hub's boot path, as round 20 |
| round 20 6 | `gcal` `ListCalendars`, `mail` `encodeWord` / `Send` / `Messages` / `EmbedRelink` | the same run: all 0.0; `ls /var/spool-hub/dispatch/briefs \| grep -c 'api-err-r[78]'` -> 2; `git log 2acffb02e -E --grep='api-err-r[78]' --oneline \| wc -l` -> 0 | reproduces | **Left out**: the api-err briefs still name both areas |
| fresh | Go functions at 0.0 or under 70 in packages no live lane, queued row or round 19/20 row holds | the same run, `go tool cover -func` | `msg` `ValidKind` 0.0, `ValidBoxID` 0.0; `rbac` `Access.List` 0.0, `Fixed.Roles` 0.0, `FixedSet.Roles` 0.0; `sign` `LoadPrivate` 54.5 (package 82.6, floor 82.9: inside the gate's 1.0 slack); `config` `OperatorWorkspace` 0.0, `DemoTenant` 66.7 | **Rows 05, 06, 07, 09** |
| fresh | `blob` GCS backend (`OpenGCS`, `Put`, `Promote`, ... 17 functions at 0.0) | the same run | package 71.9 | **Left out**: needs a GCS fake, not a small row |
| fresh | bash functions over the 75-line cap, listed in `LONG` | `bash iac:t/bash-cleancode.tst.sh` and the test's own `measure` awk per file | 22 `LONG` lines, **21** still over 75 (`no function over 75 lines outside LONG or over its ceiling (21 listed)`), and `NOTE LONG: '...spl-desk-up.func.sh spl_desk_sidecar' is no longer over 75 lines` | **Rows 01-03** take 6 (77-79 lines, each with a dedicated test); **row 10** deletes the stale `spl_desk_sidecar` line |
| fresh | the other 15 bash `LONG` functions | the same | `spl-desk-reply` (queued bug row 881adc37), `spl-tenant-create` (briefed r41-03), `spl-secret-unused-list` and `provision-firebase-dns` (round 20 header inputs), `spl-dispatch-lease`, `spawn-core.inc.sh`, `spl-agent-identity-restore` (fleet-critical, 9-26 tests each), 8 more at 76-80 | **Left out**: owned, or for a later round |
| fresh | WUI functions over 75, listed in `LONG` | `node wui:tests/unit/cleancode.test.mjs` (node_modules of another worktree, read only) | `12514 functions, 19 listed long, 17 listed wide`, no NOTE | **Row 04** takes two at ceiling 76 (`useCardReactions`, `useSidebarRailNav`); `useCalendarDeepLinks` is r41-01's |
| round 20 6 | clean-code `wideFuncs` / r41-01..03 | `git log 2acffb02e -E --grep='r41-0[1-3]' --oneline \| wc -l` -> 0; 3 briefs in `dispatch/briefs` | not landed | **Left out**: still named by r41-01..03; no row here touches their files |
| round 20 6 | WUI raw-text ratchet | `cd wui: && node src/node/i18n/i18n-gates.mjs raw` | 14 in 12 files: reproduces | **Left out**: codes and brand words |
| round 20 6 | gosec G101, semgrep | `grep -v '^#' <baseline> \| grep -c .` | `.gosec-baseline.txt` 4, `.semgrep-baseline.txt` 1: reproduces | **Left out**: as retro 17 section 7.7 |
| round 20 6 | shellcheck WARNING baseline | `git log 2acffb02e -E --grep='r43-0[45]' --oneline \| wc -l` -> 0 | not landed | **Left out**: still round 18's rows 04, 05 |

## 3. The 10 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r47-01-utl-split-long-box-checks)` | a function over the 75-line cap is split into named steps | two utl box actions are listed over the cap (79 each); a long action hides which step failed and grows back to its ceiling with the next fix | `utl:run/box-beat-telemetry.func.sh:64` (`do_box_beat_telemetry_check`, 79)<br>`utl:run/box-disk-guard-install.func.sh:52` (`do_box_disk_guard_install`, 79) | 2 functions, 79 -> at most 75 | Per function: move whole steps into named helpers in the same file, each defined before its first caller; same arguments, same output lines, same return codes; no renamed env var. Do **not** edit `iac:t/bash-cleancode.tst.sh` (row 10 deletes the lines). Tests: `utl:t/box-beat-telemetry.tst.sh`, `utl:t/box-disk-guard.tst.sh`, `orc:t/box-name-from-cnf.tst.sh`, `orc:t/reliability-checks-cron.tst.sh`, `iac:t/bash-cleancode.tst.sh` (must print `NOTE LONG: ... no longer over 75 lines` for both), the utl suite, `do_check_pre_push_lint`. **Control:** every named test passes on the parent sha and after (behaviour kept, C2), and the gate's NOTE appears only after. | either | claude | simple_coding | 1 |
| 02 `refactor(r47-02-orc-split-long-db-and-ports)` | as row 01 | the db backup verify count step and the loopback ports editor are listed over the cap (78 each) | `orc:run/spl-db-backup-verify.func.sh:100` (`spl_db_backup_restore_counts`, 78)<br>`orc:run/spl-box-ports-loopback.func.sh:97` (`spl_bpl_edit`, 78) | 2 functions, 78 -> at most 75 | As row 01. `spl_bpl_edit` edits a config file: the lane diffs the file it writes in the test's sandbox before and after (equal). Tests: `orc:t/spl-db-backup.tst.sh`, `orc:t/spl-db-restore.tst.sh`, `orc:t/spl-db-restore-drill.tst.sh`, `utl:t/docker-test-container-prune.tst.sh`, `orc:t/spl-box-ports-loopback.tst.sh`, `iac:t/bash-cleancode.tst.sh` (the NOTE for both), `do_check_pre_push_lint`. **Control:** as row 01. | either | claude | simple_coding | 1 |
| 03 `refactor(r47-03-orc-split-long-probe-and-dns)` | as row 01 | the stripe webhook probe (78) and the all-zones dns export (77) are listed over the cap | `orc:run/spl-stripe-webhook-probe.func.sh:29` (`do_spl_stripe_webhook_probe`, 78)<br>`orc:run/export-all-dns-settings.func.sh:27` (`do_export_all_dns_settings`, 77) | 2 functions, 77-78 -> at most 75 | As row 01. No prd call: both are tested with their fakes only; the probe reads no real key. The action header (`@param`, `@example`) stays above the action function, unchanged. Tests: `orc:t/stripe-webhook-probe.tst.sh`, `orc:t/cloud-actions.tst.sh`, `orc:t/dns-ops.tst.sh`, `iac:t/action-header-tags.tst.sh` (no new missing / long-example), `iac:t/bash-cleancode.tst.sh` (the NOTE for both), `do_check_pre_push_lint`. **Control:** as row 01. | either | claude | simple_coding | 1 |
| 04 `refactor(r47-04-wui-split-long-composables)` | as row 01, in the WUI | two composables are one line over the cap (ceiling 76) | `wui:src/composables/useCardReactions.ts:19` (`useCardReactions`, 76)<br>`wui:src/composables/useSidebarRailNav.ts:38` (`useSidebarRailNav`, 76) | 2 functions, 76 -> at most 75 | Extract one named inner step per composable into a function **in the same file** (the source-reading unit tests read these files through `tests/unit/lib/message-card-src.mjs` and `channel-sidebar-src.mjs`, which list the file, not a new one). Same returned object, same refs, no new import, no new text (i18n gates unchanged). Do **not** edit `cleancode.test.mjs`. Tests: `pnpm run typecheck`; `node tests/unit/cleancode.test.mjs` (no FAIL; NOTE for both); the unit tests that import `message-card-src.mjs` (17) or `channel-sidebar-src.mjs` (19), and `events-rail.test.mjs`; the e2e files `cd iac: && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e` selects, against a generated bundle. **Control:** as row 01, plus the e2e set green before and after. | either | claude | complex_coding | 1 |
| 05 `test(r47-05-api-msg-validators)` | the hub's message validators under test | `ValidKind` decides which `kind` a message may carry and `ValidBoxID` which box id the hub accepts; both are 0.0 | `go:internal/msg/msg.go:59` (`ValidKind`)<br>`go:internal/msg/msg.go:270` (`ValidBoxID`)<br>`go:internal/msg/msg_validators_test.go` (new) | 2 functions at 0.0 | Table tests: every kind of `KindList` -> true, `""`, `"Task"`, `"task "`, `"other"` -> false (and `KindList` split on `\|` equals the accepted set); `ValidBoxID` against `boxRe` (`msg.go:76`, `^[a-z0-9][a-z0-9-]{0,31}$`): a 1-char and a 32-char id -> true, `""`, a leading `-`, an upper-case letter, 33 chars and `a/b` -> false. A new test file; helper names prefixed `mv`. Tests: `go test -count=1 -race -cover ./internal/msg/`; `bash api:src/bash/tests/run-all-tests.sh` (coverage part `ok`, floors unchanged). **Red control:** `ValidKind` returning `true` -> the new false cases fail. | either | claude | tests | 1 |
| 06 `test(r47-06-api-rbac-list-and-fixed-roles)` | the permission list and the fixed roles under test | `Access.List` is what a member's permissions read back as (sorted, granted only) and `Fixed` / `FixedSet` `.Roles` answer the default roles; all three 0.0 | `go:internal/rbac/rbac.go:354` (`Access.List`)<br>`go:internal/rbac/rbac.go:514` (`Fixed.Roles`)<br>`go:internal/rbac/rbac.go:536` (`FixedSet.Roles`)<br>`go:internal/rbac/rbac_list_roles_test.go` (new) | 3 functions at 0.0 | `List` of an `Access` with granted, denied (`false`) and unsorted perms -> only the granted, sorted; of an empty one -> empty, no panic. `Roles` of both -> equal to `DefaultRoles()`. A new test file; helper names prefixed `lr`. Tests: `go test -count=1 -race -cover ./internal/rbac/`; `run-all-tests.sh`. **Red control:** `List` keeping a `false` perm -> the denied case fails. | either | claude | tests | 1 |
| 07 `test(r47-07-api-sign-load-private-errors)` | the box key loader's refusals under test | `LoadPrivate` reads the key a box signs with; its missing, undecodable and wrong-size branches are untested (54.5), and `sign` sits 0.3 under its floor 82.9 (82.6, inside the gate's 1.0 slack) | `go:internal/sign/sign.go:52` (`LoadPrivate`)<br>`go:internal/sign/load_private_test.go` (new) | 1 function at 54.5 | In `t.TempDir()` only, keys generated in the test: no file -> `errors.Is(err, ErrUnpinned)`; non-base64 -> a decode error naming the id; base64 of 10 bytes -> the wrong-size error; a key the package writes itself -> loads and signs what the matching public key verifies. Never a real key path. Helper names prefixed `lp`. No floor change. Tests: `go test -count=1 -race -cover ./internal/sign/`; `run-all-tests.sh`. **Red control:** delete the size check -> the wrong-size case fails. | either | claude | tests | 1 |
| 08 `test(r47-08-api-keydesk-server-defaults)` | the key desk's nil defaults under test | `Server.logf` with no `Log` (50.0) and `peerOK` with no `PeerOK` (66.7, falls back to `DefaultPeerOK`) are the paths a desk runs when its caller sets neither; round 20 named `logf` as round 21 input | `go:internal/keydesk/keydesk.go:164` (`logf`)<br>`go:internal/keydesk/keydesk.go:235` (`peerOK`)<br>`go:internal/keydesk/server_defaults_test.go` (new) | 2 functions under 70 | `logf` on a `Server` with `Log == nil` -> no panic, and with a `Log` -> the formatted line once; `peerOK` with `PeerOK == nil` -> the same answer as `DefaultPeerOK` for the same `Peer` (the lane picks a `Peer` `DefaultPeerOK` refuses, e.g. another uid, and states it), with `PeerOK` set -> its answer. No socket, no real secret. Helper names prefixed `sd`. Tests: `go test -count=1 -race -cover ./internal/keydesk/`; `run-all-tests.sh`. **Red control:** `peerOK` returning `nil` when `PeerOK` is nil -> the refused case fails. | either | claude | tests | 1 |
| 09 `test(r47-09-api-config-operator-workspace)` | the bootstrap workspace getters under test | `OperatorWorkspace` names the operator workspace until the database flags one (0.0); `DemoTenant` names the demo one, `""` while off (66.7) | `go:internal/config/config.go:651` (`OperatorWorkspace`)<br>`go:internal/config/config.go:659` (`DemoTenant`)<br>`go:internal/config/operator_workspace_test.go` (new) | 2 functions under 70 | `OperatorWorkspace`: `OperatorTenant` set -> it, even with an apex; unset -> `WUIApexTenant`; both unset -> `""`. `DemoTenant`: off -> `""` even with a name; on -> the name. Struct literals only, no env. Helper names prefixed `ow`. Tests: `go test -count=1 -race -cover ./internal/config/`; `run-all-tests.sh`. **Red control:** `OperatorWorkspace` checking the apex first -> the "both set" case fails. | either | claude | tests | 1 |
| 10 `test(r47-10-gates-drop-stale-long-lines)` | a clean-code list holds only what is still over the cap | the lists "may only shrink", but a stale line lets a function grow back up to its old ceiling unnoticed; `spl_desk_sidecar` is stale today | `iac:t/bash-cleancode.tst.sh:38` (`spl_desk_sidecar`, the one stale line today)<br>`wui:tests/unit/cleancode.test.mjs:37` (the count comment, only if a WUI line goes) | 1 line today, up to 9 once rows 01-04 land | The other lines are the `LONG` lines rows 01-04 leave stale, named here, not as sites (as round 20 v0.3 row 01): `bash-cleancode.tst.sh` `:30`, `:34`, `:35`, `:43`, `:46`, `:47` and `cleancode.test.mjs` `:44`, `:50` on `2acffb02e` (same on `b4cefd7b4`). Delete exactly the lines whose `NOTE LONG ... no longer over` the gates print on the lane's start sha, no other line; a row of 01-04 not landed yet leaves its lines for the next round. Tests: `bash iac:t/bash-cleancode.tst.sh` and `node wui:tests/unit/cleancode.test.mjs` print no `NOTE LONG ... no longer over` after; `bash iac:t/run-all-tests.sh`; `cd wui: && pnpm run test:unit` if the WUI file changed. R9 (a gate's list): run under `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. **Control:** the NOTE lines before (quoted), none after; FAIL count 0 both times. | either | claude | tests | 2 (after 01-04) |

### 3.1 Lanes and batches

- **Batch 1: rows 01-09, no file in two rows.** Rows 01-03 each own two
  bash files, row 04 two WUI files, rows 05-09 one Go package each plus one
  new test file. None edits a clean-code list (section 1), a floor, a
  baseline, a migration, `csi-spl-cnf/`, a workflow or terraform.
- **Batch 2: row 10**, placed within 30 minutes of the last of rows 01-04
  landing (R16), or once the round's other rows are done if one of 01-04
  is dropped.
- Under "keep 2 row lanes in parallel" (686bc1a3) the dispatch holder
  places any two batch 1 rows, then the next as each lands. Suggested
  order: one bash or WUI row with one Go row, so the two lanes run
  different suites.

### 3.2 Off every live lane and every queued row (R3)

- **Excluded by the brief:** every site of round 20 rows 01-09 (its
  section 3), `iac:t/action-header-tags-baseline.txt`,
  `api:src/bash/tests/go-coverage-floor.txt` (round 19 row 09),
  `orc:run/spl-review-line-check.func.sh` (queued 826558fa),
  `spl-dispatch-setup` / `spl-desk-reply` / `spl-take` (queued 881adc37),
  `spool-send.sh` (g-121 N1). No row here names any of them.
- **Live lanes:** `lane-map.sh --check <the 16 site and gate files of rows
  01-10, comma separated> --agent c-908` -> **exit 4** (sat,
  2026-11-01T22:48Z, the exit code read from the command, never through a
  pipe). No path is printed as owned; 8 live lanes record no files:
  `c-171`, `c-180`, `c-186` (round 20 rows 01, 08, 09: their sites are in
  round 20's table, none is here), `c-862`, `c-866`, `c-934`, `g-214`
  (rotation seats, `*-rotate*` slugs), `c-894` (spec 169 docs: its brief
  names only `csi-spl-doc/doc/md/channel-workspace-move.md` and
  `specs/169-channel-workspace-move`). Exit 4 is not free: the dispatch
  holder re-runs the check before each row's spawn and asks any
  `unknown:` lane it cannot place this way.
- **Spawn queue:** `./run -a do_spl_spawn_queue` -> 34 queued, 0 placing.
  For each queued brief, `grep -oE` for the site basenames, the five Go
  package paths and file names, `bash-cleancode`, `cleancode.test`,
  `useCardReactions`, `useSidebarRailNav` -> hits in 3 of 33 briefs
  (`c002-bug-gh-runner-health-token-file`,
  `c002-bug-desk-pause-blocks-post-boot-reseat`, `c002-s150-b10`), each
  only telling its lane to **run** bash-cleancode, none editing it. 1 brief
  is not on this box (ask 75077182, a read-only
  DNS bug of the other box, **unchecked**).
- The keyexec bug row (`c002-bug-keyexec-lease-gostring`) and the
  marketing bug row are other packages.

## 4. Per row: what the lane does

- **01:** Split the two utl box checks over 75 lines into named steps.
- **02:** The same for the db backup verify counts and the loopback ports
  editor.
- **03:** The same for the stripe webhook probe and the all-zones dns
  export.
- **04:** One extracted step each in two WUI composables at 76 lines.
- **05:** Tests for `msg.ValidKind` and `ValidBoxID`.
- **06:** Tests for `rbac.Access.List` and the fixed roles.
- **07:** Tests for `sign.LoadPrivate`'s three refusals and the good path.
- **08:** Tests for the key desk's nil `Log` and nil `PeerOK` defaults.
- **09:** Tests for `config.OperatorWorkspace` and `DemoTenant`.
- **10:** Delete the clean-code list lines the gates print as stale.

## 5. Panel and reviewers (R7)

- Editor: c-908 (claude). Panel reviewer: a grok seat named by the
  dispatch lease holder. Both sign the plan sha (rulebook 3.2).
- Row reviewers: a cross-vendor seat per row (section 1); lines checked
  with `do_spl_review_line_check`. A row with no reviewer for 15 minutes
  reports a blocker (2.7.3).
- **P1, for the panel:** rows 01-04 leave a stale line in a clean-code
  list until row 10. The gates allow it (a NOTE, not a FAIL), and it keeps
  four rows parallel instead of four serial batches. The editor prefers
  that over the serial shape of round 20's header track.
- **P2, for the panel:** rows 05-09 are `test` rows in a refactor round,
  as round 20 rows 06-09 were: they guard code a later refactor will move
  (the box key loader, the key desk, the message validators).
- **P3, for the panel:** no round 20 retro yet (rows open); allowed as in
  rounds 19 and 20 (rulebook 2.8 R8 and 1.4).

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| round 20's 16 + 2 declare-first iac files, the 4 long-example files | wait on r46-01's loader and the shared header baseline held by r46-02..05; **input for round 22** once r46-05 lands | section 2 |
| floor raises for `marketing`, `wire`, `hubclient`, `payments`, and for `msg`, `rbac`, `sign`, `keydesk`, `config` after rows 05-09 | `go-coverage-floor.txt` is held by r44-09; one row raises every line after it lands; **input for round 22** | `go test -coverprofile` per package |
| the 9 `(required)` header files | a behaviour change: the next bug round | section 2 |
| the other 15 bash `LONG` functions | 2 owned or briefed, 2 round 20 header inputs, 3 fleet-critical with 9-26 tests; the other 8 (76-80 lines) are input for round 22 at 2 per row | `bash iac:t/bash-cleancode.tst.sh` |
| the other 17 WUI `LONG` functions (76-80), 17 `WIDE` | `useCalendarDeepLinks` is r41-01's; the rest are input for round 22 | `node wui:tests/unit/cleancode.test.mjs` |
| Go `longFuncs` (`Server.Handler`, `ProvisionMember`) and `wideFuncs` | the hub's router and a Postgres store path; `lockStatementOK` is r41-02's | `cleancode_test.go` |
| `blob` GCS backend, `gcal` / `mail` 0.0 functions, `cmd/spool`, `store`, `repodocs`, `auth` | section 2 | `go tool cover -func` on `2acffb02e` |
| WUI raw text, gosec / semgrep, shellcheck WARNING baseline | section 2 | section 2 |

## 7. Counts

| metric | n |
|---|---|
| rows | 10 (refactor 4, test 6; utl 1, orc 2, wui 1, Go 5, gate lists 1) |
| vendor | claude 10 |
| kind | simple_coding 3, complex_coding 1, tests 6 |
| batches | batch 1: rows 01-09 (9 at once); batch 2: row 10 |
| bash functions over 75 | 21 -> 15 after rows 01-03 |
| WUI functions over 75 | 19 -> 17 after row 04 |
| stale clean-code list lines | 1 today, 0 after row 10 |
| Go functions taken | 6 at 0.0, 4 under 70 |
| measured on | `2acffb02e`, n=1 per command unless stated |

## 8. Changes

- v0.1: first draft (c-908): 10 rows, slug `r47`; no round 20 retro (not
  due).
- v0.2 (c-908, on g-910 FAIL 09cc77a4 and c-002 dffa4ea6): W1 row 10 back
  to at most 5 sites (rulebook 3.1): the sites cell names the one stale line
  and the WUI count comment; the `LONG` lines rows 01-04 leave stale move to
  the test cell, as round 20 v0.3 did. N1 round 20 row 08 landed
  (`5cc8ead51`); open round 20 rows are 01-05 and 09. N2-N5: no change
  asked.

## 9. Consensus

- Editor seat: c-908@sat (claude): drafted v0.1, folded v0.2.
- Grok panel reviewer seat: g-910@sat (grok): FAIL on v0.1 `1d3f343ff` (W1); re-reviews v0.2.
