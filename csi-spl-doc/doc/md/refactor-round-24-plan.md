# Refactoring round 24 - plan (10 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-4779  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 7f664194 / 8cb6cc7d: 20-30% of the fleet on refactoring
  ([fleet-rules-index.md](fleet-rules-index.md)).
- msg b8e22a15: reach consensus in the panel and start, no owner input;
  msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 dc15ad65 msg 686bc1a3: **"keep 2 row lanes in parallel"**: rows 01-08
  share no file (section 3.1), so any two of them can run at once, and batch 2
  rows 09 and 10 are disjoint from each other too.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows: **vendor
  claude for every row**. Code reviews grok or claude only (msg cf7a7ee5).
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, pushes
  aim 1 up to 3 never more than 5, R1-R16).

**Why now.** The fleet's refactor share is under its band:
`./run -a do_spl_spawn_queue` (2026-11-04T09:35Z, this session) prints
`refactor 1 4% (band 10-20%: UNDER), bug 8 34% (band 15-20%: OVER), feature 14 60% (band 60-%: ok); 343 bypass(es); phase day; last 24 h (51 sample(s)): refactor 14% (band 20-30%: UNDER)`
of 23 known live lanes (14 unknown left out), and 0 refactor rows in the 86
queued asks. Round 23 ([plan](refactor-round-23-plan.md), v1.0, slug `r49`) has
landed all 10 of its rows on `origin/master`:
`git log af48d0fcb -E --grep='r49-[0-9]{2}' --format=%s | grep -c '^[a-z]*(r49-'` -> 10
(`946f07629` r49-01 through `63e0a785d` r49-10). Round 22
([plan](refactor-round-22-plan.md), v1.0, slug `r48`) has also landed all 10 of
its rows (`git log af48d0fcb -E --grep='r48-[0-9]{2}' --format=%s | grep -c '^[a-z]*(r48-'` -> 10,
including `c4fe23eca` `r48-09` coverage floors raise and `0c2494c38` `r48-10`
stale LONG lines). Neither `refactor-round-22-retro.md` nor
`refactor-round-23-retro.md` is on `af48d0fcb` yet (`ls
csi-spl-doc/doc/md/refactor-round-*-retro.md` ends at
[refactor-round-21-retro.md](refactor-round-21-retro.md)). Section 2 re-measures
round 23's section 6 and deferred inputs on `af48d0fcb`.

Round 24 focus: **8 of the 10 rows can run at once in batch 1, and both batch 2
closing rows are disjoint from each other**. Three rows split the six remaining
unblocked WUI functions over the 75-line cap across four composables/components
and `stores/channel.ts`, five rows put thirteen under-tested Go functions across
`internal/github`, `internal/hours`, `internal/spool`, `internal/mail` and
`internal/files` under unit test, one batch 2 row raises the nine coverage floor
lines in `api:src/bash/tests/go-coverage-floor.txt` for round 23's five Go
packages and round 24's Go packages, and one batch 2 row deletes the six
clean-code `LONG` list lines in `wui:tests/unit/cleancode.test.mjs` that rows
01-03 leave stale.

**Status: v0.2 DRAFT** (editor a-924; claude panel reviewer c-110@sat; section 9).

Editor: **a-924** (agy). Panel reviewer: **c-110@sat** (claude). Dispatch lease
holder: the current holder of `lease.dispatch`.

**One sha:** every count is measured on **`af48d0fcb`** (`origin/master`
af48d0fcb7e56fc836087b7d5dd1e64785bd52b6, 2026-11-04T10:05:03+01:00 /
2026-11-04T09:05:03Z), n=1 per command unless stated. Go: go1.26.10. Node:
v20.20.2. Bash, Go and WUI runs are on `af48d0fcb` (WUI runs on a `git archive
af48d0fcb` copy borrowing another checkout's `node_modules`, read only).

## 1. How to read this

- **Slug prefix `r50`.** `git log af48d0fcb --oneline -E --grep='r50-' | wc -l`
  -> 0; `grep -rl 'r50-' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote /var/spool-hub/asks 2>/dev/null | wc -l`
  -> 0; `git branch -r | grep -c 'r50-'` -> 0. No `r50` lane. `r49` is taken:
  10 row commits on `af48d0fcb` (`r49-01..10`). The next planner proves its
  prefix free the same way, and discounts briefs that only quote the search.
- One row = one practice = one lane, at the sites named and nowhere else,
  with a test that shows behaviour kept or, for a test row, a **red
  control**: the new case fails on a planted defect and passes after.
- **Paths:** `iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`,
  `utl:` = `csi-spl-utl/`, `api:` = `csi-spl-api/`, `wui:` = `csi-spl-wui/`,
  `go:` = `csi-spl-api/src/go/spool-hub-api/`; `run/` = `src/bash/run/`,
  `t/` = `src/bash/tests/` of the sub-project named. Lines as of
  `af48d0fcb`; a bash or WUI site's line is the function's first line.
- **Box:** `either` for every row (no pin); the spawner's pick may place a row
  on either box.
- **Vendor:** claude for every row. **R7 reviewer:** a cross-vendor seat
  per row (grok on a claude author while grok has quota), named by the
  dispatch holder at placement. Each review line names the author's vendor.
- **Subject** (R6 reads it): `<type>(r50-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
- **Re-measure first:** every row lane re-runs its measure command on the
  `origin/master` it starts from and says in its result if the number moved.
- **Tests per row (R2):** every test file that names a site's basename or a
  function it defines
  (`git grep -l -F -e <basename> -e <function> af48d0fcb -- '*tst.sh' '*/tests/*' '*test*.sh'`),
  listed per row; for Go, the package's tests; for WUI, the unit tests
  that read the file's source and the e2e files the pre-push map selects.
- **The clean-code lists only NOTE a stale line**, as rounds 21-23 section 1
  say (`checkLong` in `wui:tests/unit/cleancode.test.mjs`). So a split row does
  **not** edit the gate file: row 10 deletes every stale line in one commit,
  after rows 01-03.
- **The floor file is raised once in batch 2 (row 09).** Round 22's `r48-09`
  (`c4fe23eca`) has landed, so `api:src/bash/tests/go-coverage-floor.txt` is
  free. To keep batch 1 rows 04-08 disjoint on `go-coverage-floor.txt` (matching
  round 22's batch 1 + row 09 split), rows 04-08 leave `go-coverage-floor.txt`
  untouched (a deliberate deviation from its `:4-5` same-commit rule) and row 09
  raises all nine lines in section 3.3 in one batch 2 commit after rows 04-08.

## 2. Where the rows come from (measured on `af48d0fcb`)

| source | input | command on `af48d0fcb` | n | row / disposition |
|---|---|---|---|---|
| round 23 6 | coverage floor raises for `search`, `lockkey`, `marketing`, `spool`, `wire` (`api:src/bash/tests/go-coverage-floor.txt`) | `cd go: && go test -count=1 -cover ./internal/{search,lockkey,marketing,spool,wire}/`; `git log af48d0fcb --grep='r48-09' --oneline \| wc -l` | `r48-09` landed (`c4fe23eca`, 1 commit); `search` `98.1` (floor `95.6`), `lockkey` `79.3` (`78.7`), `marketing` `86.5` (`84.2`), `spool` `92.6` (`86.4`), `wire` `91.0` (`90.1`) | **Row 09** (batch 2, together with the 4 other round 24 Go packages in section 3.3) |
| round 23 2 & 6 | round 20's 30 remaining declare-first iac files, the 4 long-example files, `spl_secret_unused_table` (76), `do_provision_firebase_dns` (169) | `awk 'FNR==1{h=0;d=0} /^# *@(description\|param\|example)/{if(d){print FILENAME;nextfile};h=1} /^declare /{if(!h)d=1}' iac:run/*.func.sh orc:run/*.func.sh utl:run/*.func.sh \| wc -l`; `bash iac:t/action-header-tags.tst.sh`; `git log af48d0fcb -E --grep='r46-0[45]' --format=%s \| grep -vc '^docs'` | **30** declare-first files; `measured 771 files: 48 missing, 4 long-example`; `r46-04` and `r46-05` commits: **0** | **Deferred**: still waits on `r46-04` and `r46-05` and the shared baseline `iac:t/action-header-tags-baseline.txt` |
| round 23 2 & 6 | the 9 `(required)` header files | `awk '/^\[missing\]/{m=1;next} /^\[/{m=0} m && /^csi-spl-/' iac:t/action-header-tags-baseline.txt \| xargs grep -l '(required)' \| wc -l` | **9**: reproduces (note round 23's `grep -E '^\[missing\]'` matched the section header line and printed 0; walking the `[missing]` section reproduces 9) | **Left out**: a behaviour change (bug-round input), as rounds 20-23 said |
| round 23 6 | the 7 remaining bash `LONG` functions (`do_provision_firebase_dns` 169, `spl_secret_unused_table` 76, `spl_desk_pick` 80, `do_spl_tenant_create` 76, `spl_fleet_role_tick` 78, `_spawn_worktree` 79, `do_spl_agent_identity_restore` 80) | `bash iac:t/bash-cleancode.tst.sh`; queue check | `PASS: the walk measured 6235 functions in 1124 files`, `PASS: no function over 75 lines outside LONG or over its ceiling (7 listed)`, 0 `NOTE LONG:` lines (`r48-10` and `r49-10` deleted all 8+2 stale lines) | **Left out / deferred**: 2 header inputs (`r46`), 1 queued (`881adc37` `c002-bug-dispatch-desk-hop-desk-roots`), 1 briefed (`r41-03`), 3 fleet-critical |
| round 23 6 | the 9 remaining WUI `LONG` functions (77-80), 17 `WIDE` | `node wui:tests/unit/cleancode.test.mjs` | `cleancode: 12900 functions, 9 listed long, 17 listed wide, none deeper than 4 or wider than 5`, 0 `NOTE LONG:` lines | **Rows 01, 02, 03** take all 6 unblocked round 23 inputs (`useDocTree` 79, `useDocPictures` 79, `useFileTreeDrag` 80, `useOmniboxGripSize` 79, `stores/channel.ts` `sidebarSteps` 79 and `liveSendSteps` 77); `useCalendarDeepLinks` (78) is `r41-01`'s; `useCardMove` (80) and `useCardMessageActions` (80) wait on queued `dda94828` (`c003-move-to-topic-all-channels`) |
| round 23 6 | `github` `messageOf` (66.7), `Client.Blob` (66.7) | `cd go: && go test -count=1 -coverprofile=c.out ./internal/github && go tool cover -func=c.out \| awk '$NF+0 < 75.0'` | both reproduce (`client.go:186` 66.7, `repo.go:100` 66.7; the only `< 75%` functions in `internal/github`); package `86.7` (floor `86.7`) | **Row 04** takes both in `internal/github` |
| round 23 6 | `hours` `minTime` (66.7), `DefaultCategoryRules` (71.4) | `cd go: && go test -count=1 -coverprofile=c.out ./internal/hours && go tool cover -func=c.out \| awk '$NF+0 <= 75.0'` | `minTime` 66.7 (`across.go:353`), `DefaultCategoryRules` 71.4 (`categories.go:124`), `appendInterval` 75.0 (`across.go:394`), `minuteOf` 75.0 (`suggest.go:266`); package `98.5` (floor `98.0`) | **Row 05** takes `minTime` (66.7), `appendInterval` (75.0) and `minuteOf` (75.0); `DefaultCategoryRules` is **dropped** (already called at `categories_test.go:171`; its two uncovered `err != nil` branches at `:127,131` parse the valid package `const` strings `DefaultEveningWindow` and `DefaultNightWindow`, unreachable without changing non-test code) |
| round 23 2 & 6 | `spool` `Store.warnOut` (66.7), `writeFileAtomic` (64.7) | `cd go: && go test -count=1 -coverprofile=c.out ./internal/spool && go tool cover -func=c.out \| awk '$NF+0 < 75.0'` | both reproduce (`spool.go:49` 66.7, `spool.go:627` 64.7; the only `< 75%` functions left in `internal/spool`); package `92.6` (floor `86.4`) | **Row 06** takes both in `internal/spool` |
| fresh | `mail` functions under 75% (`macedonian` 66.7, `deliver` 53.8, `loadAndExec` 69.2) | `cd go: && go test -count=1 -coverprofile=c.out ./internal/mail && go tool cover -func=c.out \| awk '$NF+0 < 75.0'` | 3 functions under 75% (`duration.go:159` 66.7, `mail.go:254` 53.8, `templates.go:140` 69.2; the only `< 75%` functions left in `internal/mail`); package `91.2` (floor `91.2`) | **Row 07** takes all 3 in `internal/mail` |
| fresh | `files` functions under 75% (`PutDir` 74.1, `writeBlob` 71.4, `copyVerify` 72.7, `SniffBytes` 71.4) | `cd go: && go test -count=1 -coverprofile=c.out ./internal/files && go tool cover -func=c.out \| awk '$NF+0 < 75.0'` | 4 functions under 75% (`files.go:57` 74.1, `files.go:252` 71.4, `files.go:288` 72.7, `sniff.go:67` 71.4); package `83.5` (floor `82.9`) | **Row 08** takes 3 (`writeBlob`, `copyVerify`, `SniffBytes`); `PutDir` (74.1) is input for round 25 |
| fresh | `keyexec` (`Exhausted` 66.7, `tokenOr` 66.7, `noVibeEnvFile` 66.7, `writeClaudeSettings` 66.7, `exitCode` 66.7) and `keydesk` (`peerOf` 71.4, `Seal` 66.7, `LoadOrCreateIdentity` 72.2) | `cd go: && go test -count=1 -coverprofile=c.out ./internal/keyexec ./internal/keydesk && go tool cover -func=c.out \| awk '$NF+0 < 75.0'` | 5 functions in `keyexec` (package `81.7`, floor `81.7`), 3 in `keydesk` (package `88.7`, floor `88.7`) | **Left out**: `keyexec` has live lane `c-079@sat` (`c002-bug-keyexec-lease-gostring`); both are **input for round 25** |
| round 23 2 & 6 | Go `longFuncs` and `wideFuncs`, `blob` GCS backend, `gcal` `ListCalendars`, `cmd/spool`, `store`, `repodocs`, `auth`, WUI raw text, gosec / semgrep, shellcheck WARNING baseline | `cleancode_test.go`, `go tool cover`, `i18n-gates.mjs raw`, baselines | reproduce (`r41-01..03` and `r43-04..05` still not landed: `git log af48d0fcb -E --grep='r41-0[1-3]\|r43-0[45]' --oneline \| wc -l` -> 0) | **Left out**: same reasons as rounds 22 and 23 section 2 |

## 3. The 10 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r50-01-wui-split-long-doctree-and-pictures)` | a function over the 75-line cap is split into named steps | the workspace doctree API client composable `useDocTree` (79) and the document picture composable `useDocPictures` (79) are listed over the cap | `wui:src/components/workspace-docs/-doctree-api.ts:111` (`useDocTree`, 79)<br>`wui:src/composables/useDocPictures.ts:89` (`useDocPictures`, 79) | 2 functions, 79 -> at most 75 | Extract named steps **in the same file** (each helper defined before its first caller and taking at most 5 parameters). Same returned object, same refs, no new import, no new text (i18n gates unchanged). Do **not** edit `cleancode.test.mjs` (row 10 deletes the lines). No unit test loads `-doctree-api.ts` or `useDocPictures.ts` (`git grep -l -e doctree-api -e useDocPictures af48d0fcb -- csi-spl-wui/tests` matches only `tests/unit/cleancode.test.mjs`), so behaviour is kept by `pnpm run typecheck` plus the e2e set. Tests: `pnpm run typecheck`; `node tests/unit/cleancode.test.mjs` (no FAIL; `NOTE LONG:` for both); the e2e files that drive the composables' users (`WorkspaceDoc*.vue`): `tests/e2e/workspace-doctree.test.mjs`, `tests/e2e/own-picture.test.mjs`, `tests/e2e/qto-unified-explorer.test.mjs`, and the e2e files `cd iac: && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e` selects (`workspace-doctree.test.mjs`, `issues-mobile.test.mjs`, `qto-sidebar-entry.test.mjs`, `issues.test.mjs`, `docs.test.mjs`, `release-notes.test.mjs`), against a generated bundle. **Control:** `pnpm run typecheck` and the named + selected e2e files pass on the parent sha and after (behaviour kept, C2), `cleancode.test.mjs` prints `NOTE LONG:` for both only after, and its FAIL count is 0 both times. | either | claude | complex_coding | 1 |
| 02 `refactor(r50-02-wui-split-long-file-tree-and-grip-size)` | as row 01 | the file-tree pointer drag composable `useFileTreeDrag` (80) and the omnibox grip resize composable `useOmniboxGripSize` (79) are listed over the cap | `wui:src/composables/useFileTreeDrag.ts:31` (`useFileTreeDrag`, 80)<br>`wui:src/composables/useOmniboxGripSize.ts:17` (`useOmniboxGripSize`, 79) | 2 functions, 79-80 -> at most 75 | Extract named steps **in the same file** (each helper taking at most 5 parameters). Same returned object, same refs, no new import, no new text. Do **not** edit `cleancode.test.mjs`. No unit test loads `useFileTreeDrag.ts` or `useOmniboxGripSize.ts` (`git grep -l -e useFileTreeDrag -e useOmniboxGripSize af48d0fcb -- csi-spl-wui/tests` matches only `tests/unit/cleancode.test.mjs`), so behaviour is kept by `pnpm run typecheck` plus the e2e set. Tests: `pnpm run typecheck`; `node tests/unit/cleancode.test.mjs` (no FAIL; `NOTE LONG:` for both); the e2e files that drive the composables' users (`UiFileTree.vue`, `OmniboxGrip.vue`): `tests/e2e/qto-tree-reorder.test.mjs`, `tests/e2e/qto-unified-explorer.test.mjs`, `tests/e2e/omnibox-grip.test.mjs`, `tests/e2e/omnibox-bottom.test.mjs`, and the e2e files `cd iac: && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e` selects (`omnibox-grip.test.mjs`, `qto-sidebar-entry.test.mjs`, `omnibox-resize-align.test.mjs`, `omnibox-phone-zoom.test.mjs`, `qto-tree-reorder.test.mjs`, `phone-composer-target.test.mjs`), against a generated bundle. **Control:** as row 01. | either | claude | complex_coding | 1 |
| 03 `refactor(r50-03-wui-split-long-channel-store-steps)` | as row 01 | both `sidebarSteps` (79) and `liveSendSteps` (77) in `stores/channel.ts` are listed over the cap | `wui:src/stores/channel.ts:184` (`sidebarSteps`, 79)<br>`wui:src/stores/channel.ts:593` (`liveSendSteps`, 77) | 2 functions, 77-79 -> at most 75 | Extract named steps **in the same file**: 24 unit test files in `tests/unit/` read or exercise `src/stores/channel.ts`. Keep `sendLive`'s 6-parameter signature unchanged (`src/stores/channel.ts sendLive` is listed in `WIDE`); any newly extracted helper must take at most 5 parameters and be at most 75 lines. Same returned store surface, same refs, no new import, no new text. Do **not** edit `cleancode.test.mjs`. Tests: `pnpm run typecheck`; `node tests/unit/cleancode.test.mjs` (no FAIL; `NOTE LONG:` for both `src/stores/channel.ts` entries); the 24 unit tests that reference `stores/channel` (`agent-at-box`, `await-reply`, `catch-up-delta`, `channel-archive`, `channel-create-dialog`, `channel-door`, `channel-feed`, `channel-paging`, `composer-files`, `composer-kind`, `dm-counts-parity`, `feed-rows-shallow`, `file-preview`, `load-more-30`, `mention-poke`, `newest-live`, `offline-queue`, `omnibox-topic`, `pane-send-lost`, `reply-counts`, `send-failure`, `send-fallback-note`, `topic-in`, `topic-reply-index`); the e2e files `cd iac: && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e` selects, against a generated bundle. **Control:** every named unit test, `pnpm run typecheck` and the selected e2e set pass on the parent sha and after (behaviour kept, C2), the gate's `NOTE LONG:` appears for both only after, and its FAIL count is 0 both times. | either | claude | complex_coding | 1 |
| 04 `test(r50-04-api-github-message-and-blob)` | the GitHub error-message extractor and blob fetcher under test | `messageOf` (66.7) extracts and caps GitHub's `"message"` field without quoting raw error bodies, and `Client.Blob` (66.7) has its HTTP error and non-base64 encoding branches untested; round 23 named both as round 24 input (`github` reads `86.7`, floor `86.7`) | `go:internal/github/client.go:186` (`messageOf`, 66.7)<br>`go:internal/github/repo.go:100` (`Client.Blob`, 66.7)<br>`go:internal/github/blob_message_test.go` (new) | 2 functions at 66.7 | In `package github` (internal test file so unexported `messageOf` is called directly as well as through `Client.Blob`) against `httptest.NewServer` only (no live network, keys generated in the test): `messageOf(raw)`: non-JSON `raw` -> `""`, JSON with `message` over 200 bytes (e.g. 250 bytes) -> truncated to 200 bytes (`len == 200`), short `message` -> returned as is; `Client.Blob(ctx, sha)`: server answering 404/500 -> `*APIError`, server answering 200 with `encoding: "utf-8"` (non-`"base64"`) -> `[]byte(content)` unchanged, server answering 200 with `encoding: "base64"` and embedded `\n` -> decoded bytes. Non-test code unchanged. Do **not** edit `api:src/bash/tests/go-coverage-floor.txt` (row 09 raises it in batch 2; deliberate deviation from its `:4-5` same-commit rule). Helper names prefixed `bm`. Tests: `go test -count=1 -race -cover ./internal/github/`; `bash api:src/bash/tests/run-all-tests.sh` (coverage part `ok`). **Red control:** `messageOf` skipping the `len(m.Message) > 200` cap -> the >200-byte message case fails. | either | claude | tests | 1 |
| 05 `test(r50-05-api-hours-min-time-and-intervals)` | the hours overlap interval merger, time minimum and Unix minute floor under test | `minTime` (66.7) has its `a.Before(b)` branch uncovered, `appendInterval` (75.0) has its adjacent-stretch merge branch uncovered, and `minuteOf` (75.0) has its negative non-minute-aligned floor branch uncovered; round 23 named `hours` (`98.5`, floor `98.0`) as round 24 input | `go:internal/hours/across.go:353` (`minTime`, 66.7)<br>`go:internal/hours/across.go:394` (`appendInterval`, 75.0)<br>`go:internal/hours/suggest.go:266` (`minuteOf`, 75.0)<br>`go:internal/hours/intervals_mintime_test.go` (new) | 1 function at 66.7, 2 at 75.0 | `minTime(a, b)`: `a.Before(b)` -> `a` (`:355`), `a.After(b)` -> `b`, `a.Equal(b)` -> `b`. `appendInterval(out, from, to, open)`: when `out` ends at `from` with the same sorted workspace set -> merges in place (`len(out)` unchanged, `out[n-1].End.Equal(to)`), when `out` is empty, has a gap (`!out[n-1].End.Equal(from)`), or has a different workspace set -> appends a new `OverlapInterval`. `minuteOf(t)`: negative Unix seconds not divisible by 60 (e.g. `time.Unix(-1, 0).UTC()` and `time.Unix(-61, 0).UTC()`) -> `-1` and `-2` (`s/60 - 1`), exact negative minute (`time.Unix(-60, 0).UTC()`) -> `-1`, non-negative (`time.Unix(61, 0).UTC()`) -> `1`. Non-test code unchanged. Do **not** edit `api:src/bash/tests/go-coverage-floor.txt` (row 09's; deliberate deviation from `:4-5`). Helper names prefixed `im`. Tests: `go test -count=1 -race -cover ./internal/hours/`; `run-all-tests.sh`. **Red control:** `minTime` returning `b` when `a.Before(b)` -> the `a < b` case fails. | either | claude | tests | 1 |
| 06 `test(r50-06-api-spool-warn-and-write-atomic)` | the on-box spool's stderr warn fallback and atomic file writer under test | `Store.warnOut` (66.7) and `writeFileAtomic` (64.7) are the only two functions under 75% left in `internal/spool`; round 23 named both as round 24 input (`spool` reads `92.6`, floor `86.4`) | `go:internal/spool/spool.go:49` (`Store.warnOut`, 66.7)<br>`go:internal/spool/spool.go:627` (`writeFileAtomic`, 64.7)<br>`go:internal/spool/write_atomic_test.go` (new) | 2 functions at 64.7-66.7 | In `t.TempDir()` only: `warnOut()`: on a `Store` with `warn == nil` -> returns `os.Stderr` (`:53`), with a custom `io.Writer` -> returns that writer; `writeFileAtomic(path, data, mode)`: when `filepath.Dir(path)` is an existing regular file (`os.MkdirAll` fails, `:628-630`) -> non-nil error, when `filepath.Dir(path)` is an existing read-only directory (`0500`, restored via `t.Cleanup`, so `os.CreateTemp` fails at `:631-634`, skipped if `os.Geteuid() == 0`) -> non-nil error, and on a valid path -> writes `data` with permissions `mode`. Non-test code unchanged. Do **not** edit `api:src/bash/tests/go-coverage-floor.txt` (row 09's; deliberate deviation from `:4-5`). Helper names prefixed `wa`. Tests: `go test -count=1 -race -cover ./internal/spool/`; `run-all-tests.sh`. **Red control:** `warnOut` returning `nil` when `s.warn == nil` -> the nil-writer fallback case fails. | either | claude | tests | 1 |
| 07 `test(r50-07-api-mail-deliver-and-duration)` | the mail package's remaining three `< 75%` functions under test | `macedonian` (66.7), `deliver` (53.8) and `loadAndExec` (69.2) are the only functions under 75% left in `internal/mail` (`mail` reads `91.2`, floor `91.2`) | `go:internal/mail/duration.go:159` (`macedonian`, 66.7)<br>`go:internal/mail/mail.go:254` (`deliver`, 53.8)<br>`go:internal/mail/templates.go:140` (`loadAndExec`, 69.2)<br>`go:internal/mail/deliver_duration_test.go` (new) | 3 functions at 53.8-69.2 | `macedonian`: `n=1, m10=1, m100=1` and `n=21, m10=1, m100=21` -> `catOne` (`:160-162`, plus `Duration("mk", 21*time.Hour)`), `n=11, m10=1, m100=11` and `n=2, m10=2, m100=2` -> `catOther`. `deliver(c, from, to, raw)` against an in-process `net.Listener` speaking scripted SMTP responses only (no real network): 550 on `MAIL FROM` -> error prefixed `"mail: MAIL FROM:"`, 550 on `RCPT TO` -> error prefixed `"mail: RCPT TO:"`, 554 on `DATA` -> error prefixed `"mail: DATA:"`, 554 after body dot (`w.Close()`) -> error prefixed `"mail: close body:"`, 250/354/250/221 -> `nil`. `loadAndExec`: missing template ID or unknown locale (e.g. `loadAndExec("no_such", "en", TemplateData{})` and `loadAndExec(TemplatePasswordReset, "zz", TemplateData{})`, plus `Render("no_such", "sv", TemplateData{})` exercising the `:133-136` fallback retry) -> error prefixed `"mail: missing templates/..."` (`:143-145`, raising `loadAndExec` from 69.2% to 76.9%; `:147/:150/:153` stay uncovered because `templateFS` is an `embed.FS` package var where every `.subject` has its `.txt` and `TemplateData` is a struct at `:61` so `missingkey=error` never fails on a valid embedded template), valid `TemplateData` -> non-empty `(subject, text, nil)`. Non-test code unchanged. Do **not** edit `api:src/bash/tests/go-coverage-floor.txt` (row 09's; deliberate deviation from `:4-5`). Helper names prefixed `dd`. Tests: `go test -count=1 -race -cover ./internal/mail/`; `run-all-tests.sh`. **Red control:** `macedonian` omitting `m100 != 11` -> the `11` case returns `catOne` and fails. | either | claude | tests | 1 |
| 08 `test(r50-08-api-files-sniff-and-copy-verify)` | the blob writer, hash-verified file copy and magic-byte sniffer under test | `writeBlob` (71.4), `copyVerify` (72.7) and `SniffBytes` (71.4) have untested error and magic-signature branches (`files` reads `83.5`, floor `82.9`) | `go:internal/files/files.go:252` (`writeBlob`, 71.4)<br>`go:internal/files/files.go:288` (`copyVerify`, 72.7)<br>`go:internal/files/sniff.go:67` (`SniffBytes`, 71.4)<br>`go:internal/files/sniff_copy_test.go` (new) | 3 functions at 71.4-72.7 | In `t.TempDir()` only: `writeBlob(filesDir, r)`: when `filesDir` is an existing regular file (`os.MkdirAll` fails, `:253-255`) -> error, when `r` returns a read error (`io.Copy` fails, `:264-267`) -> error and leaves no `.blob-*` file, when `r` succeeds twice with identical bytes -> returns the same sha256 `id` and `size` (dedupe at `:273-275`). `copyVerify(src, dest, want)`: when `filepath.Dir(dest)` is an existing regular file (`:297-299`) -> error, when `src` is a directory (`io.Copy` fails, `:307-310`) -> error, when `want` mismatches -> `ErrHashMismatch`, when `want` matches -> writes `dest`. `SniffBytes(b, full)`: RIFF `WAVE` (`"RIFF\x00\x00\x00\x00WAVE"`, `:77-78`) -> `"wav"`, RIFF `WEBP` -> `"webp"`, ISO-BMFF `ftyp` (prefixing bytes `0..4` with `"\x00\x00\x00\x18"`, never `"\x00\x00\x01\x00"` which matches `ico` at `sniff.go:52`) with `"avif"`/`"avis"` (`:83-84`) -> `"avif"`, `"heic"`/`"heix"`/`"mif1"` (`:85-86`) -> `"heic"`, `"qt  "` (`:87-88`) -> `"mov"`, other `ftyp` -> `"mp4"`. Non-test code unchanged. Do **not** edit `api:src/bash/tests/go-coverage-floor.txt` (row 09's; deliberate deviation from `:4-5`). Helper names prefixed `sc`. Tests: `go test -count=1 -race -cover ./internal/files/`; `run-all-tests.sh`. **Red control:** `SniffBytes` dropping the `"WAVE"` branch -> the `"wav"` case fails. | either | claude | tests | 1 |
| 09 `test(r50-09-api-coverage-floors-raise)` | a lane that adds tests raises its package's floor (the floor file's own rule, `:4-5`) | round 23's five Go test rows (`r49-05..09`) deferred their floor raises while `r48-09` held the file (`spool` floor `86.4`, reads `92.6`; `search` floor `95.6`, reads `98.1`), and rows 04-08 add tests across five packages (`spool` shared) | `api:src/bash/tests/go-coverage-floor.txt` (the 9 lines in section 3.3) | 9 lines | Raise each of the 9 lines in section 3.3 to the **lowest of n=3** readings of `go test -count=1 -cover ./internal/<pkg>/` on the lane's start sha, and re-read all 9 packages (especially `internal/marketing`, which the queued `key-types-print-hardening` lane may touch without editing the floor file) just before pushing after rebase, with a comment in the file's own format (sha, go version, n, what it read). A line that reads below its floor is reported, never lowered; a line whose reading equals its floor after rows 04-08 is noted in the comment and left at that value. Only this file. R9 (a gate's list): `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. Tests: `bash api:src/bash/tests/run-all-tests.sh` (coverage part `ok`). **Red control:** on a throwaway copy, one raised line set 2 points above its reading -> the gate fails; restored -> green. | either | claude | tests | 2 (after 04-08) |
| 10 `test(r50-10-wui-drop-stale-long-lines)` | a clean-code list holds only what is still over the cap | the lists "may only shrink", but a stale line lets a function grow back up to its old ceiling unnoticed; rows 01-03 leave 6 stale lines in `cleancode.test.mjs` | `wui:tests/unit/cleancode.test.mjs` (the `LONG` list and its count comment) | 0 lines today, up to 6 once rows 01-03 land | The lines rows 01-03 leave stale, named here by line number on `af48d0fcb` and `LONG` key (`<file> <function>`): in `wui:tests/unit/cleancode.test.mjs`, `41` (`src/components/workspace-docs/-doctree-api.ts useDocTree`), `45` (`src/composables/useDocPictures.ts useDocPictures`), `46` (`src/composables/useFileTreeDrag.ts useFileTreeDrag`), `47` (`src/composables/useOmniboxGripSize.ts useOmniboxGripSize`), `48` (`src/stores/channel.ts liveSendSteps`) and `49` (`src/stores/channel.ts sidebarSteps`), and recompute the count comment at line `38` (`9 left after r49-10` -> `3 left after r50-10` if all 6 land) on the lane's start sha. Delete only the lines whose `NOTE LONG:` the gate prints on the start sha; a row of 01-03 not landed yet leaves its lines for the next round. Tests: `node wui:tests/unit/cleancode.test.mjs` prints no `NOTE LONG:` after; `cd wui: && pnpm run test:unit`. R9: `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. **Control:** the NOTE lines before (quoted), none after; FAIL count 0 both times. | either | claude | tests | 2 (after 01-03) |

### 3.1 Lanes and batches

- **Batch 1: rows 01-08, no file in two rows.** Rows 01-03 own five WUI `.ts`
  files (`-doctree-api.ts` + `useDocPictures.ts` in row 01, `useFileTreeDrag.ts`
  + `useOmniboxGripSize.ts` in row 02, `stores/channel.ts` in row 03), and rows
  04-08 own one Go package each (`github`, `hours`, `spool`, `mail`, `files`)
  plus one new `*_test.go` file each. None edits a clean-code list, a coverage
  floor, a baseline, a migration, `csi-spl-cnf/`, a workflow or terraform. Rows
  04-08 change no non-test code.
- **Batch 2: rows 09 and 10, disjoint from each other.** Row 09 owns only
  `api:src/bash/tests/go-coverage-floor.txt` and is placed within 30 minutes of
  the last of rows 04-08 landing (R16). Row 10 owns only
  `wui:tests/unit/cleancode.test.mjs` and is placed within 30 minutes of the
  last of rows 01-03 landing (R16). Because rows 09 and 10 share no file, both
  batch 2 rows can also run in parallel.
- Under "keep 2 row lanes in parallel" (686bc1a3) the dispatch holder
  places any two batch 1 rows, then the next as each lands. Suggested
  order: one WUI row with one Go row, so the two lanes run different suites.

### 3.2 Off every live lane and every queued row (R3)

- **Live lanes:** `lane-map.sh --check <the 22 site, new-test and gate files of
  rows 01-10, comma separated> --agent a-924` -> **exit 4** (`<box>`,
  2026-11-04T09:50:36Z and re-run 2026-11-04T17:30:55Z, exit code read directly
  from the command, never through a pipe). No path is printed as owned; at
  17:30:55Z 8 live lanes on `sat` record no files (`a-106`, `a-107`, `c-097`,
  `c-099`, `c-100`, `c-101`, `c-105`, `c-613`), and at 17:25Z the panel reviewer
  (`c-110@sat`) ran `lane-map.sh --check` from `sat` (exit 4, 0 paths owned, 19
  `<box>` lanes with no files recorded) and verified that 0 of 113 queued asks on
  `sat` name a row path or function, while `internal/keyexec` stays left out for
  `c-079` and `key-types-print-hardening`
  (`internal/{keyexec,keydesk,store,vendorkey,marketing}`). Exit 4 is not free:
  the dispatch holder re-runs the check before each row's spawn and asks any
  `unknown:` lane it cannot place this way.
- **Spawn queue (2026-11-04T09:35Z):** `./run -a do_spl_spawn_queue` -> 86
  queued, 0 placing (all 86 queued on `sat`, so their `.md` brief files are on
  `sat`, **unchecked** here; every queued ask's `/var/spool-hub/asks/<id>.json`
  record is synced here). Grepping all `/var/spool-hub/asks/*.json` with
  `"state":"queued"` for the site basenames, function names and package paths of
  rows 01-10 returned **0** matches. WUI card-move composables `useCardMove` and
  `useCardMessageActions` remain held back while `dda94828`
  (`c003-move-to-topic-all-channels`) is queued.
- **Open rows from earlier rounds:** `r46-04` and `r46-05` hold
  `iac:t/action-header-tags-baseline.txt`; `r41-01..03` and `r43-04..05` hold
  their respective files. No row here touches any of them, and all 10 rows of
  round 22 (`r48-01..10`) and round 23 (`r49-01..10`) have landed on
  `af48d0fcb`.

### 3.3 Row 09's lines (reading n=1 on `af48d0fcb`; the lane takes its own n=3 after rows 04-08)

| line | package | floor | reads on `af48d0fcb` | from |
|---|---|---|---|---|
| 70 | `internal/files` | 82.9 | 83.5 (+ row 08) | prior + row 08 |
| 73 | `internal/github` | 86.7 | 86.7 (+ row 04) | row 04 |
| 75 | `internal/hours` | 98.0 | 98.5 (+ row 05) | prior + row 05 |
| 101 | `internal/lockkey` | 78.7 | 79.3 | r49-06 |
| 103 | `internal/mail` | 91.2 | 91.2 (+ row 07) | row 07 |
| 104 | `internal/marketing` | 84.2 | 86.5 | r49-07 |
| 116 | `internal/search` | 95.6 | 98.1 | r49-05 |
| 119 | `internal/spool` | 86.4 | 92.6 (+ row 06) | r49-08, row 06 |
| 129 | `internal/wire` | 90.1 | 91.0 | r49-09 |

## 4. Per row: what the lane does

- **01:** Split `useDocTree` and `useDocPictures` into named steps in the same files.
- **02:** Split `useFileTreeDrag` and `useOmniboxGripSize` into named steps in the same files.
- **03:** Split `sidebarSteps` and `liveSendSteps` in `stores/channel.ts` into named steps.
- **04:** Unit tests for `github.messageOf` and `Client.Blob`.
- **05:** Unit tests for `hours.minTime`, `appendInterval` and `minuteOf`.
- **06:** Unit tests for `spool.Store.warnOut` and `writeFileAtomic`.
- **07:** Unit tests for `mail.macedonian`, `deliver` and `loadAndExec`.
- **08:** Unit tests for `files.writeBlob`, `copyVerify` and `SniffBytes`.
- **09:** Raise the 9 coverage floor lines of section 3.3 in `go-coverage-floor.txt`.
- **10:** Delete the 6 clean-code `LONG` list lines in `cleancode.test.mjs` that rows 01-03 leave stale.

## 5. Panel and reviewers (R7)

- Editor: a-924 (agy). Panel reviewer: a cross-vendor claude seat named by the
  dispatch lease holder. Both sign the plan sha (rulebook 3.2).
- Row reviewers: a cross-vendor seat per row (section 1); lines checked
  with `do_spl_review_line_check`. A row with no reviewer for 15 minutes
  reports a blocker (2.7.3).
- **P1, for the panel:** rows 04-08 leave `api:src/bash/tests/go-coverage-floor.txt`
  to batch 2 row 09 (a deliberate deviation from `go-coverage-floor.txt:4-5`),
  so all five Go test rows in batch 1 can run in parallel without colliding on
  the shared floor file, and row 09 raises both round 23's five packages and
  round 24's packages in one commit.
- **P2, for the panel:** round 23 section 6 named `hours.DefaultCategoryRules`
  (71.4); inspection of `categories.go:52-55,124-134` shows it is already called
  by `categories_test.go:171` and its only two uncovered statements parse the
  valid package constants `DefaultEveningWindow` and `DefaultNightWindow`, so it
  is dropped in favour of `hours.appendInterval` (75.0) and `hours.minuteOf`
  (75.0) alongside `hours.minTime` (66.7).
- **P3, for the panel:** neither round 22's retro nor round 23's retro has
  landed yet on `af48d0fcb`, while the fleet's refactor share is 4% live / 14%
  24h (UNDER its 20-30% band) with 0 refactor rows queued; drafting round 24
  now follows rulebook 1.4 ("rounds run continuously").
- Process lessons from round 21 retro ([refactor-round-21-retro.md](refactor-round-21-retro.md)
  4.2, 4.3, 4.4): every row reviewer's `ran:` field must match the row's test
  column (including `run-all-tests.sh` on Go rows 04-09) and name the author's
  vendor.

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| round 20's 30 remaining declare-first iac files, the 4 long-example files, `spl_secret_unused_table` (76), `do_provision_firebase_dns` (169) | wait on `r46-04` and `r46-05` and the shared header baseline; **input for round 25** once `r46-05` lands | section 2 |
| the 9 `(required)` header files | a behaviour change: bug-round input | section 2 |
| 7 bash `LONG` functions | 2 header inputs (`do_provision_firebase_dns` 169, `spl_secret_unused_table` 76), 1 queued (`881adc37`: `spl_desk_pick` 80), 1 briefed (`r41-03`: `do_spl_tenant_create` 76), 3 fleet-critical (`spl_fleet_role_tick` 78, `_spawn_worktree` 79, `do_spl_agent_identity_restore` 80) | `bash iac:t/bash-cleancode.tst.sh` |
| 3 WUI `LONG` functions, 17 `WIDE` | `useCalendarDeepLinks` (78) is `r41-01`'s; `useCardMove` (80) and `useCardMessageActions` (80) wait on queued `dda94828` (`c003-move-to-topic-all-channels`); **input for round 25** once `dda94828` lands | `node wui:tests/unit/cleancode.test.mjs` |
| `hours` `DefaultCategoryRules` (71.4) | **dropped**: already called by `categories_test.go:171`; its 2 uncovered branches parse valid package `const` strings (`categories.go:52-55,127,131`) | section 2 |
| `keyexec` (`Exhausted` 66.7, `tokenOr` 66.7, `noVibeEnvFile` 66.7, `writeClaudeSettings` 66.7, `exitCode` 66.7); `keydesk` (`peerOf` 71.4, `Seal` 66.7, `LoadOrCreateIdentity` 72.2); `files` `PutDir` (74.1) | `keyexec` has live lane `c-079@sat` (`c002-bug-keyexec-lease-gostring`), and the round is full; **input for round 25** | `go tool cover -func` on `af48d0fcb` |
| Go `longFuncs` and `wideFuncs`, `blob` GCS backend, `gcal` `ListCalendars`, `cmd/spool`, `store`, `repodocs`, `auth`, WUI raw text, gosec / semgrep, shellcheck WARNING baseline | section 2 | section 2 |

## 7. Counts

| metric | n |
|---|---|
| rows | 10 (refactor 3, test 7; wui 3, Go 5, coverage floors 1, gate list 1) |
| vendor | claude 10 |
| kind | complex_coding 3, tests 7 |
| batches | batch 1: rows 01-08 (8 at once); batch 2: rows 09-10 (2 at once, disjoint) |
| bash functions over 75 | 7 (unchanged) |
| WUI functions over 75 | 9 -> 3 after rows 01-03 |
| stale clean-code list lines | 0 today, +6 after `r50-01..03`, 0 after `r50-10` |
| Go functions taken | 11 at 53.8-72.7, 2 at 75.0 |
| coverage floor lines raised | 9 in `go-coverage-floor.txt` (row 09) |
| measured on | `af48d0fcb`, n=1 per command unless stated |

## 8. Changes

- v0.1: first draft (a-924): 10 rows, slug `r50`, measured on `af48d0fcb`.
- v0.2: folded `c-110@sat` panel review findings W1 (row 07: drop unreachable
  missing-key `loadAndExec` case; `:147/:150/:153` noted uncovered, `:143-145` raises
  `loadAndExec` to 76.9%), W2 (rows 01-02: drop unit tests that do not import the
  four composables; control rests on `pnpm run typecheck` plus the named +
  selected e2e files), and notes N1-N4 (refreshed section 3.2 `lane-map.sh`
  check, row 09 re-reads `marketing` before push, row 04 specifies `package
  github`, row 08 specifies `"\x00\x00\x00\x18ftyp"`).

## 9. Consensus

- Editor seat: a-924 (agy): drafted v0.1, folded W1-W2 and N1-N4 in v0.2.
- Claude panel reviewer seat: c-110@sat (claude): reviewed v0.1 (`b619aee60`), awaiting v0.2 re-review.
