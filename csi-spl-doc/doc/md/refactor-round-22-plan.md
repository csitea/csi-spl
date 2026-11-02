# Refactoring round 22 - plan (10 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-4640  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 7f664194 / 8cb6cc7d: 20-30% of the fleet on refactoring
  ([fleet-rules-index.md](fleet-rules-index.md)).
- msg b8e22a15: reach consensus in the panel and start, no owner input;
  msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 dc15ad65 msg 686bc1a3: **"keep 2 row lanes in parallel"**: rows 01-08
  share no file (section 3.1), so any two of them can run at once.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows: **vendor
  claude for every row**. Code reviews grok or claude only (msg cf7a7ee5).
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, pushes
  aim 1 up to 3 never more than 5, R1-R16).

**Why now.** The fleet's refactor share is under its band: c-001@sat
blocker 39c08437 (task spawn-share, 2026-11-02T11:40Z): refactor 16%, 4 of
24 classed live lanes, and no refactor row queued. It has fallen since:
`./run -a do_spl_spawn_queue` (sat, 2026-11-02, this session) prints
`refactor 1 4% (band 10-20%: UNDER)` of 21 known live lanes, 15 unknown left
out. Round 21 ([plan](refactor-round-21-plan.md), v1.0) is on master:
`git log 7f3da5f69 -E --grep='r47-[0-9]' --format='%h %s' | wc -l` -> 10
(row 10 is `6ad816ae4`; the brief, written before it landed, still named row
10 as open). **No round 21 retro yet**: `ls csi-spl-doc/doc/md | grep -E 'refactor-round-[0-9]+-retro'`
ends at round 17. Rulebook 2.8 makes the round 21 retro due, so its input list
is not available to this plan; section 2 re-measures round 21's section 6
instead.

Round 22 focus: **every row but the two closing ones can run at once**. Three
rows split six bash functions over the 75-line cap, one splits two WUI
functions, four put small untested Go functions under test (among them the
mail subject encoding, the signed payload's reference encoder and the PayPal
certificate URL boundary), and two closing rows raise the coverage floors
deferred since round 19 and delete the clean-code list lines the split rows
leave stale.

**Status: v0.2 DRAFT**, for the panel (v0.1 `88d36bb62`: g-960 FAIL, folded; section 8).

Editor: **c-952** (claude; agy is out of quota and claude is the
specs_and_docs backup). Panel reviewer: a cross-vendor grok seat placed by the
dispatch lease holder. Dispatch lease holder: the current holder of
`lease.dispatch`.

**One sha:** every count is measured on **`7f3da5f69`** (`origin/master`
7f3da5f6965cb418e2df87723bde7b6d416697c6, 2026-11-02T11:55Z), n=1 per
command unless stated. Go: go1.26.10. Box: sat. Bash, Go and WUI runs are on a
`git archive 7f3da5f69` copy, never on a live checkout. The WUI runs borrow
another worktree's `node_modules`, read only.

## 1. How to read this

- **Slug prefix `r48`.** `git log 7f3da5f69 --oneline -E --grep='r48-' | wc -l`
  -> 0; `grep -rl 'r48-' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote | wc -l`
  -> 0 (2026-11-02T12:4xZ, sat only; the other box's copies are unchecked). No
  r48 lane. `r47` is taken: 10 commits. The next planner proves its prefix free
  the same way, and discounts briefs that only quote the search.
- One row = one practice = one lane, at the sites named and nowhere else,
  with a test that shows behaviour kept or, for a test row, a **red
  control**: the new case fails on a planted defect and passes after.
- **Paths:** `iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`,
  `api:` = `csi-spl-api/`, `wui:` = `csi-spl-wui/`,
  `go:` = `csi-spl-api/src/go/spool-hub-api/`; `run/` = `src/bash/run/`,
  `t/` = `src/bash/tests/` of the sub-project named. Lines as of
  `7f3da5f69`; a bash or WUI site's line is the function's first line.
- **Box:** the preferred box; the spawner's pick may move a row (no pin).
- **Vendor:** claude for every row. **R7 reviewer:** a cross-vendor seat
  per row (grok on a claude author while grok has quota), named by the
  dispatch holder at placement. Each review line names the author's vendor.
- **Subject** (R6 reads it): `<type>(r48-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
- **Re-measure first:** every row lane re-runs its measure command on the
  `origin/master` it starts from and says in its result if the number moved.
- **Tests per row (R2):** every test file that names a site's basename or a
  function it defines
  (`git grep -l -F -e <basename> -e <function> 7f3da5f69 -- '*tst.sh' '*/tests/*' '*test*.sh'`),
  listed per row; for Go, the package's tests; for WUI, the unit tests
  that read the file's source and the e2e files the pre-push map selects.
- **The clean-code lists only NOTE a stale line**, as round 21 section 1 says
  (`check_long` in `iac:t/bash-cleancode.tst.sh`, `checkLong` in
  `wui:tests/unit/cleancode.test.mjs`). So a split row does **not** edit the
  gate file: row 10 deletes every stale line in one commit, after them.
- **The floor file is one file for many rows.** Its own rule (`:4-5`) says a
  lane that adds tests raises its package's line in the same commit. Rows
  05-08 would then all edit one file, so they share batch 1 only by leaving it
  alone (R1), and row 09 raises every line after them (r44-09's shape).

## 2. Where the rows come from (measured on `7f3da5f69`)

| source | input | command on `7f3da5f69` | n | row / disposition |
|---|---|---|---|---|
| round 21 6 | round 20's 16 + 2 declare-first iac files | the `awk` of round 21 section 2 over `iac:run/`, `orc:run/`, `utl:run/` | **35** (37 on `2acffb02e`): reproduces | **Deferred**: round 21 said "once r46-05 lands". `git log 7f3da5f69 -E --grep='r46-0[345]' --oneline \| wc -l` -> 0. r46-03 is now a live lane (c-963@sat), 04 and 05 follow one at a time (section 3.2) |
| round 21 6 | the 4 long-example files | `bash iac:t/action-header-tags.tst.sh` | `measured 765 files: 53 missing, 4 long-example`: reproduces | **Deferred**: their fix deletes `[long-example]` lines of `iac:t/action-header-tags-baseline.txt`, which r46-03..05 hold in turn |
| round 21 6 | the 9 `(required)` header files | `grep -ciE '^# *@param .*\(required\)'` over the 53 `[missing]` lines | **9**: reproduces | **Left out**: a bug-round input, as rounds 20 and 21 said |
| round 21 6 | floor raises for `marketing`, `wire`, `hubclient`, `payments`, `msg`, `rbac`, `sign`, `keydesk`, `config` | `cd go: && go test -count=1 -coverprofile=c.out ./...` (no DSN); floors from `grep -v '^#' api:src/bash/tests/go-coverage-floor.txt` | all reproduce (table in row 09); `git log 7f3da5f69 --grep='r44-09' --oneline \| wc -l` -> 0; `ls /var/spool-hub/dispatch/briefs \| grep -c r44-09` -> 0 | **Row 09**. Round 21 deferred it because r44-09 held the file; no r44-09 lane, brief or queue row exists, so this row takes r44-09's three lines too (`action`, `billing`, `keyexec`). See P1 |
| round 21 6 | the other 15 bash `LONG` functions | `bash iac:t/bash-cleancode.tst.sh` | `(15 listed)`, no stale NOTE: reproduces | **Rows 01-03** take 6; the other 9 below |
| round 21 6 | `spl_secret_unused_table` (76), `do_provision_firebase_dns` (169) | the same | reproduces | **Deferred**: both files are round 20 header inputs (baseline lines) |
| round 21 6 | `do_secrets_seed_gcp` (77) | `git grep -l -F -e spl-secrets-seed-all -e do_secrets_seed_gcp 7f3da5f69 -- <R2 globs>` | 2 files: the gate and `run-loader-convention.tst.sh`, no dedicated test | **Left out**: a split with nothing to prove behaviour kept; a test row first |
| round 21 6 | `spl_disp_rotate_auto` (78) | `grep -l dispatch-rotate` over the 52 queued briefs | 1: `c002-spl4507-followup-stale-vendor` adds red tests in `dispatch-rotate.tst.sh` | **Left out**: queued work on its one test |
| round 21 6 | `spl_desk_pick`, `do_spl_tenant_create`, `spl_fleet_role_tick`, `_spawn_worktree`, `do_spl_agent_identity_restore` | queue, briefs, R2 grep | queued 881adc37; briefed r41-03 (`git log 7f3da5f69 -E --grep='r41-0[1-3]' --oneline \| wc -l` -> 0); `spl_fleet_role_tick` has 27 test files naming it or its file | **Left out**: owned, or fleet-critical with many tests |
| round 21 6 | the 17 WUI `LONG` functions (76-80) | `node wui:tests/unit/cleancode.test.mjs` | `12597 functions, 17 listed long, 17 listed wide`: reproduces | **Row 04** takes 2 (`stores/search.ts` store 76, `useTenantSwitch` 78). `useCalendarDeepLinks` is r41-01's; the other 14 are input for round 23 |
| round 21 6 | Go `longFuncs` and `wideFuncs` | `cleancode_test.go:33,44` | 2 long; `lockStatementOK` still r41-02's | **Left out**: the hub's router and a Postgres store path; `internal/hub` is spec 169's |
| round 21 6 | `mail` `encodeWord` / `Send` / `Messages` / `EmbedRelink` | the same Go run, `go tool cover -func`: all 0.0 | reproduces. Round 21 left them out for the api-err briefs; both landed under other subjects (`70079d6e4` SPL-4491, `96f9170a4` SPL-4492), so the reason is gone | **Row 05** |
| round 21 6 | `gcal` `ListCalendars` | the same: 0.0 | reproduces | **Left out**: queued `c001-s169-t7c-gcal-sync-cycle` (spec 169) |
| round 21 6 | `cmd/spool` 77.8, `store` 46.8, `repodocs` 55.8, `auth` 80.4 | the same | reproduce (`store` 47.7 -> 46.8) | **Left out**: Postgres or the hub's boot path, as before |
| round 21 6 | `blob` GCS backend | the same | package 71.9 | **Left out**: needs a GCS fake, not a small row |
| round 21 6 | WUI raw text | `cd wui: && node src/node/i18n/i18n-gates.mjs raw` | 12 files: reproduces | **Left out**: codes and brand words |
| round 21 6 | gosec G101, semgrep | `grep -v '^#' <baseline> \| grep -c .` | `.gosec-baseline.txt` 4, `.semgrep-baseline.txt` 1: reproduces | **Left out**: as retro 17 section 7.7 |
| round 21 6 | shellcheck WARNING baseline | `git log 7f3da5f69 -E --grep='r43-0[45]' --oneline \| wc -l` -> 0 | not landed | **Left out**: still round 18's rows 04, 05 |
| fresh | `wire.canonicalDecode` | the same Go run: 0.0, `Canonical` 71.4; `git grep -c canonicalDecode 7f3da5f69 -- 'csi-spl-api/src/go/spool-hub-api/internal/wire/*_test.go' \| wc -l` -> 0 of the package's 10 test files | `wire.go:494` claims Canonical's output is byte-identical to it; no test compares them | **Row 06** |
| fresh | `github` `APIError.Error` 0.0, `parseKey` 58.3 | the same | package 82.9, exactly on its floor | **Row 07** |
| fresh | `payments` `fetchCert` 0.0, `validatePayPalCertURL` 66.7 | the same; `grep -n 'validatePayPalCertURL\|fetchCert' internal/payments/*_test.go` -> no line | the SSRF boundary is named by no test | **Row 08** |
| fresh | `search` `StatusDoc`, `Query.Rank`; `lockkey` `checkIDs` 60.0, `writeFile` 55.6, `shred` 62.5; `marketing` `Error`, `Permalink` 0.0 | the same | 7 functions | **Left out**: real, but the round is full; **input for round 23** |

## 3. The 10 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r48-01-orc-split-long-lde-and-idp-seed)` | a function over the 75-line cap is split into named steps | the lde config action (76) and the idp secret seed (80) are listed over the cap; a long action hides which step failed and grows back to its ceiling with the next fix | `orc:lib/bash/funcs/lde-cnf.func.sh:33` (`do_lde_cnf`, 76)<br>`orc:run/spl-auth-idp-secret-seed.func.sh:29` (`do_spl_auth_idp_secret_seed`, 80) | 2 functions, 76-80 -> at most 75 | Per function: move whole steps into named helpers in the same file, each defined before its first caller; same arguments, same output lines, same return codes; no renamed env var. Do **not** edit `iac:t/bash-cleancode.tst.sh` (row 10 deletes the lines). No real secret: the seed runs with its test's fakes only. Tests: `iac:t/compose-bridge-network.tst.sh`, `orc:t/lde-up.tst.sh`, `orc:t/wui-actions.tst.sh`, `orc:t/auth-idp-secret-seed.tst.sh`, `orc:t/secrets-check-seed-all.tst.sh`, `iac:t/action-header-tags.tst.sh`, `iac:t/bash-cleancode.tst.sh` (must print `NOTE LONG: ... no longer over 75 lines` for both), `do_check_pre_push_lint`. **Control:** every named test passes on the parent sha and after (behaviour kept, C2), and the gate's NOTE appears only after. | either | claude | simple_coding | 1 |
| 02 `refactor(r48-02-orc-split-long-tf-import-and-welcome)` | as row 01 | the cloud run import (80) and the desk welcome (80) are listed over the cap | `orc:run/tf-030-import-existing-cloud-run.func.sh:20` (`do_tf_030_import_existing_cloud_run`, 80)<br>`orc:run/spl-desk-welcome.func.sh:43` (`do_spl_desk_welcome`, 80) | 2 functions, 80 -> at most 75 | As row 01. No terraform, no GCP call and no live desk: both are tested with their fakes only. The action header stays above the action function, unchanged. Tests: `orc:t/tf-030-import-existing-cloud-run.tst.sh`, `iac:t/comment-refs-exist.tst.sh`, `orc:t/desk-welcome.tst.sh`, `orc:t/peer-restart.tst.sh`, `orc:t/tests-hermetic.tst.sh`, `iac:t/action-header-tags.tst.sh`, `iac:t/bash-cleancode.tst.sh` (the NOTE for both), `do_check_pre_push_lint`. **Control:** as row 01. | either | claude | simple_coding | 1 |
| 03 `refactor(r48-03-orc-split-long-mcp-install-and-desk-pin)` | as row 01 | the agent MCP install (80) and the desk pin (78) are listed over the cap | `orc:run/spl-agent-mcp-install.func.sh:73` (`do_spl_agent_mcp_install`, 80)<br>`orc:run/spl-desk-pin.func.sh:49` (`do_spl_desk_pin`, 78) | 2 functions, 78-80 -> at most 75 | As row 01. Dry runs stay dry: the lane diffs the dry-run output of the two tests' sandboxes before and after (equal). Spec 069's desk move changed `spl-desk-pin` on 2026-11-01 (`git log -1 -- <file>`: SPL-4536): the lane rebases right before its review. Tests: `spawn-agents/tests/test-harness-parity.sh`, `orc:t/agent-mcp.tst.sh`, `orc:t/desk-user-mcp.tst.sh`, `iac:t/satellite-ansible.tst.sh`, `spool-install/tests/test-install.sh`, `orc:t/box-workspace-isolation.tst.sh`, `orc:t/desk-dir-follows-desk-user.tst.sh`, `orc:t/desk-pin.tst.sh`, `orc:t/desk-rebox.tst.sh`, `orc:t/desk-up-all.tst.sh`, `iac:t/action-header-tags.tst.sh`, `iac:t/bash-cleancode.tst.sh` (the NOTE for both), `do_check_pre_push_lint`. **Control:** as row 01. | either | claude | simple_coding | 1 |
| 04 `refactor(r48-04-wui-split-long-search-and-tenant-switch)` | as row 01, in the WUI | the search store (76) and the tenant switch composable (78) are listed over the cap | `wui:src/stores/search.ts:67` (the `defineStore` callback, `<anon>#4`, 76)<br>`wui:src/composables/useTenantSwitch.ts:18` (`useTenantSwitch`, 78) | 2 functions, 76-78 -> at most 75 | Extract named steps **in the same file**: the source-reading unit tests read these files. Same returned object, same refs, no new import, no new text (i18n gates unchanged). `search.ts` keeps its `await import` off the first paint (027 budget). Do **not** edit `cleancode.test.mjs`. Tests: `pnpm run typecheck`; `node tests/unit/cleancode.test.mjs` (no FAIL; NOTE for both); `tests/unit/search.test.mjs`, `search-door.test.mjs`, `tenant-switcher.test.mjs`, `tenant-host.test.mjs`; the e2e files `cd iac: && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e` selects (`tests/e2e/tenant-keyboard.test.mjs` and `tenant-combobox.test.mjs` name the composable; the map's selection is the lane's to read), against a generated bundle. **Control:** as row 01, plus the e2e set green before and after. | either | claude | complex_coding | 1 |
| 05 `test(r48-05-api-mail-subject-and-sinks)` | the mail subject encoding and the sender pick under test | a non-ASCII subject goes through `encodeWord` (0.0, `encodeSubject` 66.7) in every translated mail; `Config.Sender` (50.0) picks what actually sends; `EmbedRelink` (0.0) carries a single-use link | `go:internal/mail/mail.go:317` (`encodeWord`)<br>`go:internal/mail/mail.go:350,361` (`Recorder.Send`, `Messages`)<br>`go:internal/mail/config.go:124` (`Sender`)<br>`go:internal/mail/templates.go:237` (`EmbedRelink`)<br>`go:internal/mail/subject_sinks_test.go` (new) | 5 functions at 0.0 or 50.0 | `encodeSubject`: ASCII unchanged; a non-ASCII subject -> `=?UTF-8?B?...?=` that `mime.WordDecoder` decodes back. `Recorder`: `Err` set -> returned and nothing recorded; `Messages` is a copy (editing it leaves the next read equal). `Sender`: smtp -> `*SMTP` with the config's fields, log -> `Log`, any other transport -> `None`, whose `Send` returns nil. `EmbedRelink`: `Message` holds site and link in `en` and one other locale the lane names. No real address, no socket. Helper names prefixed `ss`. Tests: `go test -count=1 -race -cover ./internal/mail/`; `bash api:src/bash/tests/run-all-tests.sh` (coverage part `ok`, floors unchanged). **Red control:** `Recorder.Send` ignoring `Err` -> the error case fails. | either | claude | tests | 1 |
| 06 `test(r48-06-api-wire-canonical-reference)` | the signed payload's two encoders are compared | `wire.go:494` says `Canonical` is byte-identical to `canonicalDecode`, its fallback; no test calls `canonicalDecode` (0.0), so the claim about the bytes a box signs is unchecked | `go:internal/wire/wire.go:496` (`Canonical`, 71.4)<br>`go:internal/wire/wire.go:510` (`canonicalDecode`, 0.0)<br>`go:internal/wire/canonical_reference_test.go` (new) | 1 function at 0.0, 1 at 71.4 | Table, per value: `Canonical(v)` equals `canonicalDecode(json.Marshal(v))`: unsorted and nested maps, `<>&`, non-ASCII, U+2028, escaped quotes, `json.Number` past float precision, empty map, slice and string, nil, a struct with tags. `Canonical` of an unmarshalable value (a `chan`) -> the error. The fallback at `:505`: the lane reaches it, or says in its result that it found no input `json.Marshal` can produce, and how it looked. Non-test code unchanged. Helper names prefixed `cr`. Tests: `go test -count=1 -race -cover ./internal/wire/`; `run-all-tests.sh`. **Red control:** delete `enc.SetEscapeHTML(false)` in `canonicalDecode` -> the `<>&` case fails. | either | claude | tests | 1 |
| 07 `test(r48-07-api-github-parse-key)` | the App key parser's refusals under test | `parseKey` reads the key the hub signs its GitHub JWT with (58.3); its comment promises a bad PEM is never quoted; `APIError.Error` is 0.0; the package sits exactly on its floor 82.9 | `go:internal/github/jwt.go:20` (`parseKey`)<br>`go:internal/github/errors.go:31` (`APIError.Error`)<br>`go:internal/github/parse_key_test.go` (new) | 1 function at 58.3, 1 at 0.0 | Keys generated in the test only (`rsa.GenerateKey`, `ed25519.GenerateKey`), never a PEM literal. PKCS#1 and PKCS#8 RSA -> the same key back; not PEM, PEM of junk, PKCS#8 of an ed25519 key -> `errBadKey`, and the error text holds none of the input. `APIError`: `Status` 0 and 404 -> the two formats. Helper names prefixed `pk`. Tests: `go test -count=1 -race -cover ./internal/github/`; `run-all-tests.sh`. **Red control:** return an error that quotes `pemBytes` -> the no-quote case fails. | either | claude | tests | 1 |
| 08 `test(r48-08-api-payments-cert-url-boundary)` | the PayPal certificate fetch under test | `paypal-cert-url` arrives from the network and `validatePayPalCertURL` is, in its own comment, "the SSRF boundary"; no test names it (66.7), and `fetchCert` is 0.0 | `go:internal/payments/paypal_signature.go:198` (`validatePayPalCertURL`)<br>`go:internal/payments/paypal_signature.go:213` (`fetchCert`)<br>`go:internal/payments/paypal_cert_url_test.go` (new) | 1 function at 66.7, 1 at 0.0 | Accept: `https://paypal.com/x`, `https://api.paypal.com/x`, upper-case scheme and host. Refuse with `ErrSigBad`: `http://`, `https://notpaypal.com/x`, `https://paypal.com.example.com/x`, `https://paypal.com@example.com/x`, `https://example.com/?h=paypal.com`, a URL that does not parse. `fetchCert` against `httptest.NewServer` only: 200 -> the body; 404 -> `ErrSigBad`; a closed server -> `ErrSigBad`; a body over 1 MiB -> cut at 1 MiB. No real network, no real key. Helper names prefixed `pc`. Tests: `go test -count=1 -race -cover ./internal/payments/`; `run-all-tests.sh`. **Red control:** `paypalCertHostSuffix` without its dot -> the `notpaypal.com` case fails. | either | claude | tests | 1 |
| 09 `test(r48-09-api-coverage-floors-raise)` | a lane that adds tests raises its package's floor (the floor file's own rule, `:4-5`) | rounds 19-22 added tests without touching the shared file: a package can drop back up to 20 points unnoticed (`marketing` floor 63.6, reads 84.2) | `api:src/bash/tests/go-coverage-floor.txt` (the 14 lines in section 3.3) | 14 lines | Raise each line to the **lowest of n=3** readings of `go test -count=1 -cover ./internal/<pkg>/` on the lane's start sha, with a comment in the file's own format (sha, go version, n, what it read). A line that reads below its floor is reported, never lowered. `hubclient` has timing paths (the comment above its line): n=3 plain and n=3 `-race`, the lowest of the six. Only this file. R9 (a gate's list): `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. Tests: `bash api:src/bash/tests/run-all-tests.sh` (coverage part `ok`). **Red control:** on a throwaway copy, one raised line set 2 points above its reading -> the gate fails; restored -> green. | either | claude | tests | 2 (after 05-08) |
| 10 `test(r48-10-gates-drop-stale-long-lines)` | a clean-code list holds only what is still over the cap | the lists "may only shrink", but a stale line lets a function grow back up to its old ceiling unnoticed; rows 01-04 leave 8 | `iac:t/bash-cleancode.tst.sh` (the `LONG` list)<br>`wui:tests/unit/cleancode.test.mjs` (the `LONG` list and its count comment) | 0 lines today, up to 8 once rows 01-04 land | The lines rows 01-04 leave stale, named here, not as sites (as round 21 row 10), lines as of `7f3da5f69`: `bash-cleancode.tst.sh` 28, 31, 32, 33, 35, 40; `cleancode.test.mjs` 51, 57, and its count comment at 38. Delete exactly the lines whose `NOTE LONG ... no longer over` the gates print on the lane's start sha, no other line; a row of 01-04 not landed yet leaves its lines for the next round. Tests: `bash iac:t/bash-cleancode.tst.sh` and `node wui:tests/unit/cleancode.test.mjs` print no `NOTE LONG ... no longer over` after; `bash iac:t/run-all-tests.sh`; `cd wui: && pnpm run test:unit`. R9: `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. **Control:** the NOTE lines before (quoted), none after; FAIL count 0 both times. | either | claude | tests | 2 (after 01-04) |

### 3.1 Lanes and batches

- **Batch 1: rows 01-08, no file in two rows.** Rows 01-03 each own two bash
  files, row 04 two WUI files, rows 05-08 one Go package each plus one new test
  file. None edits a clean-code list, a floor, a baseline, a migration,
  `csi-spl-cnf/`, a workflow or terraform. Rows 05-08 change no non-test code.
- **Batch 2: rows 09 and 10**, disjoint from each other. Row 09 is placed within
  30 minutes of the last of rows 05-08 landing, row 10 of the last of rows 01-04
  (R16), or once the round's other rows are done if one is dropped.
- Under "keep 2 row lanes in parallel" (686bc1a3) the dispatch holder
  places any two batch 1 rows, then the next as each lands. Suggested
  order: one bash or WUI row with one Go row, so the two lanes run
  different suites.

### 3.2 Off every live lane and every queued row (R3)

- **Excluded by the brief:** `orc:run/spl-lane-map.func.sh`,
  `spl-watchdog.func.sh`, `spl-agent-login-check.func.sh`,
  `iac:run/check-pre-push.func.sh`, `do_spl_agent_id_reap`'s file,
  `go:internal/hubclient/hubclient.go`, `go:internal/hub/box_lane.go`, every
  spec 169 file, `ChannelSidebar.vue`. No row names any of them. Row 09 edits
  `hubclient`'s floor line, not its code.
- **Live lanes:** `lane-map.sh --check <the 18 site and gate files of rows
  01-10, comma separated> --agent c-952` -> **exit 4** (sat,
  2026-11-02T12:39Z, the exit code read from the command, never through a
  pipe). No path is printed as owned; 9 live lanes record no files: `c-386`,
  `c-401`, `g-519` (spec 169: `grep -rl` of the site paths over
  `csi-spl-doc/specs/169-*/` -> 0), `c-894` (spec 169 docs), `c-579` (spec 154
  B9) and `c-577` (lane origin links): the briefs of these last three name no
  site (`grep -cE` of the site names -> 0 each), `c-587` (CI reds, brief not
  read), `c-862`, `c-934` (seats on other repos' topics by their lane-map scope, briefs
  not read). Exit 4 is not free: the dispatch holder re-runs the check before each
  row's spawn and asks any `unknown:` lane it cannot place this way.
- **Spawn queue:** `./run -a do_spl_spawn_queue` -> 53 queued, 0 placing. For
  each queued brief, `grep -qi` for the site basenames and functions,
  `paypal`, `jwt.go`, `wire.go`, `mail.go`, `internal/mail`, `internal/github`,
  `go-coverage`, `cleancode.test` -> no hit in the 52 briefs on this box;
  `bash-cleancode` -> 3 (`c002-bug-desk-pause-blocks-post-boot-reseat`,
  `c002-bug-gh-runner-health-token-file`, `c003-s150-b10b`), each only telling
  its lane about the gate, none editing it. 1 brief is not on this box
  (ask 75077182, a DNS bug of the other box, **unchecked**).
- **Round 20 rows 03-05: 03 is live, 04 and 05 are neither landed nor placed.**
  v0.1 said no brief and no queue row; the dispatch holder queued r46-03 at
  12:46Z, after v0.1's reading (ask 091dfe99), and c-001 placed it at 14:25Z as
  c-963@sat (`spool tail --task dispatch-r46`). At 14:32Z:
  `ls /var/spool-hub/dispatch/briefs | grep -E 'r46-0[345]'` -> the r46-03 brief
  only; `do_spl_spawn_queue | grep -E 'r46'` -> no line;
  `git log origin/master -E --grep='r46-0[345]' --oneline` -> no line. No row
  here touches a site of the three (compared over whole rows: 0 shared).
- **The one shared file is serial, and it is theirs:** r46-03 edits
  `iac:t/action-header-tags-baseline.txt`, and 04 and 05 hold it in turn. Rows
  01-03 only run `iac:t/action-header-tags.tst.sh` and must not edit that
  baseline; a row that finds it must, stops and tells the dispatch holder.
- **Re-read for v0.2:** the same `--check` at 14:34Z -> **exit 4** (read from
  the command), no path owned, 10 `unknown:` lanes on the other box: `c-386`,
  `c-401`, `c-577`, `c-579`, `c-587`, `c-615`, `c-862`, `c-894`, `c-934`,
  `g-625`. Six of them (`c-401`, `c-587`, `c-615`, `c-862`, `c-934`, `g-625`)
  have no brief on this box, **unread**, so the holder's check before each spawn
  still stands.

### 3.3 Row 09's lines (reading n=1 on `7f3da5f69`; the lane takes its own n=3)

| line | package | floor | reads | from |
|---|---|---|---|---|
| 27 | `internal/action` | 80.8 | 90.8 | r44-06, r44-07 |
| 39 | `internal/billing` | 80.8 | 100.0 | r44-08 |
| 61 | `internal/config` | 89.7 | 91.2 | r47-09 |
| 67 | `internal/github` | 82.9 | 82.9 | row 07 |
| 75 | `internal/hubclient` | 83.0 | 85.9 | r46-08 |
| 88 | `internal/keydesk` | 88.1 | 88.7 | r47-08 |
| 89 | `internal/keyexec` | 79.7 | 81.7 | r44-08 |
| 96 | `internal/mail` | 85.0 | 86.4 | row 05 |
| 97 | `internal/marketing` | 63.6 | 84.2 | r46-06 |
| 99 | `internal/msg` | 84.9 | 90.8 | r47-05 |
| 105 | `internal/payments` | 80.9 | 81.7 | r46-09, row 08 |
| 108 | `internal/rbac` | 89.3 | 98.9 | r47-06 |
| 111 | `internal/sign` | 82.9 | 86.2 | r47-07 |
| 122 | `internal/wire` | 81.7 | 87.7 | r46-07, row 06 |

## 4. Per row: what the lane does

- **01:** Split the lde config action and the idp secret seed into named steps.
- **02:** The same for the cloud run import and the desk welcome.
- **03:** The same for the agent MCP install and the desk pin.
- **04:** Named steps out of the search store and `useTenantSwitch`.
- **05:** Tests for the mail subject encoding, `Recorder`, `Sender`, `EmbedRelink`.
- **06:** Compare `wire.Canonical` with its reference `canonicalDecode`.
- **07:** Tests for `github.parseKey`'s refusals and `APIError.Error`.
- **08:** Tests for the PayPal certificate URL boundary and `fetchCert`.
- **09:** Raise the 14 coverage floor lines of section 3.3.
- **10:** Delete the clean-code list lines the gates print as stale.

## 5. Panel and reviewers (R7)

- Editor: c-952 (claude). Panel reviewer: a grok seat named by the dispatch
  lease holder. Both sign the plan sha (rulebook 3.2).
- Row reviewers: a cross-vendor seat per row (section 1); lines checked
  with `do_spl_review_line_check`. A row with no reviewer for 15 minutes
  reports a blocker (2.7.3).
- **P1, closed:** row 09 takes r44-09's three lines (`action`, `billing`,
  `keyexec`), so r44-09 is not placed once this plan is signed. Round 19's row
  stays open in its own plan; one floor commit, not two lanes on one file. g-960
  agrees (not landed, no brief).
- **P2, ruled by the dispatch holder (msg 078a6e82):** round 20 rows 03-05 run
  serially on one shared baseline: r46-03 is placed (section 3.2), then 04 and 05
  one at a time. They unblock the deferred inputs of section 6.
- **P3, closed:** rows 05-09 stay `test` rows in a refactor round, as in rounds 20
  and 21: they guard code a later refactor will move. g-960 accepts (rulebook
  1.1 caps the items and does not require every subject to be refactor).
- **P4, with the dispatch holder (msg 078a6e82, queued, ask fe825cae):** the round 21 retro is due (rulebook 2.8) and not written;
  rounds 18-20 have none either, none due while rows are open (r43-04/05, r44-09, r46-03..05). This plan goes ahead on measured inputs instead,
  and the retro lane runs when the holder's queue places it.

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| round 20's 16 + 2 declare-first iac files, the 4 long-example files, `spl_secret_unused_table`, `do_provision_firebase_dns` | wait on r46-03..05 and the shared header baseline; **input for round 23** once r46-05 lands | section 2 |
| the 9 `(required)` header files | a behaviour change: the next bug round | section 2 |
| 9 bash `LONG` functions | 2 header inputs, 1 no dedicated test, 1 queued work on its test, 2 owned or briefed, 3 fleet-critical | `bash iac:t/bash-cleancode.tst.sh` |
| 15 WUI `LONG` functions, 17 `WIDE` | `useCalendarDeepLinks` is r41-01's; the other 14 are input for round 23 | `node wui:tests/unit/cleancode.test.mjs` |
| Go `longFuncs` and `wideFuncs` | the hub's router and a Postgres store path; `lockStatementOK` is r41-02's | `cleancode_test.go` |
| `search` `StatusDoc`, `Query.Rank`; `lockkey` `checkIDs`, `writeFile`, `shred`; `marketing` `Error`, `Permalink` | the round is full; **input for round 23** | `go tool cover -func` on `7f3da5f69` |
| `blob` GCS backend, `gcal` `ListCalendars`, `cmd/spool`, `store`, `repodocs`, `auth` | section 2 | `go tool cover -func` on `7f3da5f69` |
| WUI raw text, gosec / semgrep, shellcheck WARNING baseline | section 2 | section 2 |
| `fetchCert` default client follows redirects | I read, not tested: `grep -n CheckRedirect internal/payments/*.go` -> no line, and the default `http.Client` follows them, so a redirect from a paypal.com URL leaves the host check behind. A behaviour change, not a test row: **input for the next bug round**, to be proven there first | the grep; `paypal_signature.go:213-217` |

## 7. Counts

| metric | n |
|---|---|
| rows | 10 (refactor 4, test 6; orc 3, wui 1, Go 4, floor file 1, gate lists 1) |
| vendor | claude 10 |
| kind | simple_coding 3, complex_coding 1, tests 6 |
| batches | batch 1: rows 01-08 (8 at once); batch 2: rows 09, 10 |
| bash functions over 75 | 15 -> 9 after rows 01-03 |
| WUI functions over 75 | 17 -> 15 after row 04 |
| stale clean-code list lines | 0 today, 8 after rows 01-04, 0 after row 10 |
| Go functions taken | 7 at 0.0, 4 under 72 |
| coverage floor lines raised | 14 |
| measured on | `7f3da5f69`, n=1 per command unless stated |

## 8. Changes

- v0.1: first draft (c-952): 10 rows, slug `r48`; no round 21 retro (P4).
- v0.2 (c-952): folds g-960 FAIL on `88d36bb62` (msg cef83054). W1: row 10's site
  cell named 9 lines, max 5; it names the two gate files, the lines move to its
  test cell. W2: section 2 and 3.2 said r46-03..05 had no brief or queue row;
  r46-03 is live as c-963@sat, and its baseline is serial against rows 01-03. N1:
  section 7 said 8 at 0.0 and 5 under 72; the row cells give 7 and 4. P1 and P3
  closed, P2 and P4 as the holder ruled. No row added, dropped or re-batched, and
  every count stays on `7f3da5f69`; only the times stated in 3.2 are newer.

## 9. Consensus

- Editor seat: c-952@sat (claude): drafted v0.1, folded v0.2.
- Grok panel reviewer seat: g-960@sat (grok): FAIL on v0.1 `88d36bb62` (W1, W2; msg cef83054).
