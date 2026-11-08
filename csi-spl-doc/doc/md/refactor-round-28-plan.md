# Refactoring round 28 - plan (10 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5095  
Topic: b4b264a7-95e9-40aa-a863-529c8637c181  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 7f664194 / 8cb6cc7d: the refactoring share of the fleet
  ([fleet-rules-index.md](fleet-rules-index.md)).
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 dc15ad65 msg 686bc1a3: **"keep 2 row lanes in parallel"**: the 7 rows of
  batch 1 share no file (section 3.1), so any two of them can run at once.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows: **vendor
  claude for every row**.
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, pushes
  aim 1 up to 3 never more than 5, R1-R16).

**Why now.** c-001's SPAWN SHARE ba4d6ce8 (task spawn-share, 2026-11-08 15:4xZ,
quoted from this lane's brief, the message itself not read): refactor 6%, and no
refactor row queued. `./run -a do_spl_spawn_queue` (`cd orc:`, 2026-11-08, about
16:3xZ, this session) prints `65 queued, 0 placing (fleet main)` and
`share of 30 known live lanes (12 unknown, left out): refactor 5 16% (band 10-20%: ok), bug 17 56% (band 15-20%: OVER), feature 8 26% (band 60-%: UNDER)`,
and `last 24 h (130 sample(s)): refactor 10% (band 20-30%: UNDER)`. Every row printed
in that output's tail is a `bug`.

Round 27 ([plan](refactor-round-27-plan.md), v1.0, slug `r53`) has rows 01, 02, 03,
04, 06, 07, 08 and 09 on `681cf8c63`:
`git log 681cf8c63 --format=%s | grep -oE 'r53-[0-9]+' | sort -u` -> those 8. The
brief listed 09 as in a lane; it landed before this measurement. Rows 05 and 10 have
no commit there (`git log 681cf8c63 --oneline --grep='r53-<NN>' | wc -l` -> 0 each).
**This round touches no site of r53-05, r53-09 or r53-10**, as the brief says. No
round 22-27 retro is on `681cf8c63`
(`git ls-tree --name-only 681cf8c63 csi-spl-doc/doc/md/ | grep -E 'refactor-round-.*retro' | sort -V | tail -1`
-> `refactor-round-21-retro.md`); section 2 re-measures round 27's inputs instead.

Round 28 focus: **7 of the 10 rows run at once in batch 1.** One row fixes the
boot-time regex; two put eight action headers where `./run` help reads them; two
clear the gate lines rounds 26 and 27 left stale; two put 7 under-tested key
functions under unit test; three take WUI functions off the wide list, one per
batch, because all three edit `MessageCard.vue`.

**Status: v0.1 DRAFT**, awaiting the panel seat (section 5).

Editor: **c-393** (claude). Panel reviewer: placed by the dispatch lease holder
(section 5).

**One sha:** every count is measured on **`681cf8c63`** (`origin/master`
681cf8c63971208963f71442006cf32fcd3f99b9, 2026-11-08T18:21:10+02:00 / 16:21:10Z),
n=1 per command unless stated. Go: go1.26.10. Go and Bash reads are in this lane's
worktree at `681cf8c63` (clean). WUI runs and the header probes are on a
`git archive 681cf8c63` copy, the WUI part borrowing another checkout's
`node_modules`, read only. Go coverage is one
`go test -count=1 -coverprofile=<f> ./...` without Postgres (the store and hub
Postgres tests skip; rc 0, 0 `^FAIL` lines), read with `go tool cover -func=<f>`.
Queue and lane readings are live state, so they carry their own time, not this sha.

## 1. How to read this

- **Slug prefix `r54`.** `git log 681cf8c63 --oneline -E --grep='r54-' | wc -l`
  -> 0; `git branch -r | grep -c 'r54-'` -> 0;
  `grep -rl 'r54-' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote /var/spool-hub/asks 2>/dev/null | wc -l`
  -> 0 on this box. `r53` is taken (8 commits, 13 branches).
- One row = one practice = one lane, at the sites named and nowhere else,
  with a test that shows behaviour kept or, for a test row, a **red
  control**: the new case fails on a planted defect and passes after.
- **Paths:** `iac:` = `csi-spl-iac/`, `wui:` = `csi-spl-wui/`,
  `api:` = `csi-spl-api/`, `go:` = `csi-spl-api/src/go/spool-hub-api/`;
  `run/` = `src/bash/run/`, `t/` = `src/bash/tests/` of the sub-project named.
  Lines as of `681cf8c63`; a function's site is its first line.
- **Box:** `either` for every row (no pin).
- **Vendor:** claude for every row. **R7 reviewer:** as the holder rules (section 5).
- **Subject** (R6 reads it): `<type>(r54-NN-<slug>, SPL-<row issue>): ...`.
- **Topic:** every row brief carries the `Topic:` line above.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
- **Re-measure first:** every row lane re-runs the command that measured its input
  in section 2 on the `origin/master` it starts from and says in its result if the
  number moved.
- **Tests per row (R2):** every test file that names a site's basename or a function
  it defines (`git grep -l -F -e <name> 681cf8c63 -- '*tst.sh' '*/tests/*' '*test*.sh' '*.test.mjs'`),
  listed per row; **bold** = it reads the site's source text. The bold marks on the
  Bash rows come from `grep -cE '(grep|sed|awk) .*func\.sh'` on each test, a rough
  filter: the row lane corrects them. For Go, the package's tests plus
  `bash api:src/bash/tests/run-all-tests.sh`; for WUI, the unit tests and the e2e
  files the pre-push map selects
  (`cd iac: && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e`).
- **What a probe did and did not show:** "probed" means it ran on the scratch copy,
  n=1. **No red control and no break named in a row has been planted, in any row.**
  The cases of rows 06, 07 and 10 are read from the source and the coverage profile:
  none has been written or run.

## 2. Where the rows come from (measured on `681cf8c63`)

**Taken:**

| source | input | command on `681cf8c63` | n | row |
|---|---|---|---|---|
| `round-28-input-hubclient-boottime-regex.md` (c-001 d35be041) | the boot-time regex matches inside `usec` | `grep -n "sec = " go:internal/hubclient/host.go`; a scratch `go run` of both patterns | `:288`, as the input says (its sha was `bf1ac6caf`). **Reproduces**: `sec = (\d+)` on `{ usec = 7 }` -> `["sec = 7" "7"]`; `\bsec = (\d+)` -> no match, and the same on `{ sec = 1696000000, usec = 0 } Mon` -> `1696000000` for both | **Row 01** |
| round 27 2 | the plain-move declare-first files | `awk 'FNR==1{h=0;d=0} /^# *@(description\|param\|example)/{if(d){print FILENAME;nextfile};h=1} /^declare /{if(!h)d=1}' iac:run/*.func.sh orc:run/*.func.sh utl:run/*.func.sh \| wc -l`; `bash iac:t/action-header-tags.tst.sh` | **10** files; `measured 797 files: 28 missing, 4 long-example`. Of the 10: 6 plain moves, 2 with no `@example`, 2 with `(required)` | **Rows 02, 03** take the 6 and the 2 |
| round 27 2 | `gcp-002-delete-project-service-account`, `gcp-export-dns-settings` | a scratch copy with the header moved, `do_parse_metadata <f> \| grep -c '^example='` | 0 each (`description=` 1 each): the move alone does not clear their `[missing]` lines, as round 27 said | **Row 03** adds one `@example` each |
| round 27 1, 6 | the stale `WIDE` lines | `node tests/unit/cleancode.test.mjs` (archive copy) | `cleancode: 13236 functions, 0 listed long, 15 listed wide, none deeper than 4 or wider than 5`; 2 `NOTE WIDE`: `useEditKeys`, `useCardGrip`. r52-10 landed (`b58d818fb`), so the file is free | **Row 04** |
| round 27 2, 6 | the floor raises | package coverage against `api:src/bash/tests/go-coverage-floor.txt`; r52-06 landed (`cc31bc4fe`) | read / floor: `cicdlogs` 90.2 / 89.0, `files` 89.0 / 87.1, `hubclient` 89.6 / 87.8, `invitemail` 87.8 / 85.3, `mcp` 90.0 / 88.7 | **Row 05** takes these 5 |
| round 27 2, 6 | `keyexec`, `keydesk` `< 75%` | `go tool cover -func=<f> \| awk '$NF+0 < 75.0 && $1!="total:"'` | `keyexec` 5: `Exhausted`, `tokenOr`, `noVibeEnvFile`, `writeClaudeSettings`, `exitCode`, all 66.7; `keydesk` 3: `peerOf` 71.4, `Seal` 66.7, `LoadOrCreateIdentity` 72.2. No queued brief names either (64 briefs grepped) | **Rows 06, 07**. `exitCode` stays out (a signal path; 5-site cap) |
| round 27 2, 6 | `useCardTouchLift`, `useCardSwipeFlags`, `useCardSwipe` `WIDE` | the same gate; `grep -n` on their callers | each has one caller, in `MessageCard.vue` (`:754`, `:740`, `:742`) | **Rows 08, 09, 10**, one batch each. `useCardEdit` stays out (below) |

**Deferred or dropped:**

| source | input | command on `681cf8c63` | n | disposition |
|---|---|---|---|---|
| round 27 2 | the `(required)` header files | `awk '/^\[missing\]/{m=1;next} /^\[/{m=0} m && /^csi-spl-/' iac:t/action-header-tags-baseline.txt \| xargs grep -l '(required)' \| wc -l` | **9**: reproduces | **Left out**: a move adds `validate-params`' check, a behaviour change (bug-round input), as rounds 20-27 |
| round 27 2 | `useCardEdit` `WIDE` | `grep -n` on `MessageCard.vue:658` | 6 params; its one caller also edits `MessageCard.vue`; r53-04 only just pinned its keys | **Round 29**: this round is full, and it would be a fourth serial batch |
| round 27 2 | `useCardMove`, `useCardMessageActions`, `useCardTopicActions` `WIDE` | `lane-map.sh --check` per path, 2026-11-08 about 16:3xZ; `grep -F` on the 64 queued briefs | rc 4, no owner printed; lanes c-246 and c-259 are not among the 85 of `lane-map.sh --json`. Queued `c002-bug-constitution-drift-gate-missing` names `useCardTopicActions` | **Round 29**: round full; `useCardTopicActions` on that queued row |
| round 27 2 | `send`, `sendLive` (`channel.ts`); `liveReader`, `sessionMethods` (`spool-client.mjs`); `perfFeedPair` | `lane-map.sh --check` per path (`channel.ts`, `spool-client.mjs`), same time | rc 4, no owner printed; c-023 and c-262 are not among the 85. `perf-rum.mjs` not checked | **Round 29**: round full, and exit 4 is not free |
| round 27 2 | the other Go `< 75%` functions | as rows 06, 07 | 42 in all, less the 7 taken and `exitCode`: 34, among them `hubclient` 7 (no queued brief names `internal/hubclient` now, a change from round 27), `keyd` 10, `lockkey` 6, and the one-line entry points | **Round 29** for `hubclient`; `keyd`, `lockkey` **left out** while queued `c002-bug-keyd-openscrypt-limit-tests` and `c002-bug-lockkey-seal-shred-loses-recovery-code` stand |
| round 27 2, r53-09, r53-10 | `action`, `sign`, `config` floor lines | section 1 of round 27 | r53-10 has no commit | **Round 29**, with the rows of this round |
| round 27 2 | `notify`, `keyd`, `lockkey`, `keyexec`, `keydesk` floors | as row 05 | `notify` 96.6 / 94.8; `keydesk` 88.8 / 88.7, `keyexec` 81.8 / 81.7 | **Round 29**: the 5-site cap; rows 06, 07 will move the last two |
| round 27 2 | `spl_desk_pick` (80) | `grep -F spl-desk-reply` on the queued briefs | queued `c002-bug-desk-reply-stub-rc0` | **Left out** |
| round 27 2 | `do_provision_firebase_dns` (169) | `LONG` in `iac:t/bash-cleancode.tst.sh:26` | still listed; round 27's port-pin reading, not re-read here | **Dropped**, as rounds 26, 27 |
| round 27 2 | `spl_fleet_role_tick` (78), `_spawn_worktree` (79), `do_spl_agent_identity_restore` (80) | `LONG` in the same file (`:27`, `:28`, `:30`) | all three listed | **Left out**: fleet-critical, as rounds 22-27 |
| round 27 2 | Go `longFuncs`, `wideFuncs` | `go test -count=1 -v ./internal/cleancode/ \| grep -c 'no longer'` | 0 stale, rc 0 | **Left out**: `store`, `auth`, `hub`, as rounds 22-27 |
| round 27 2 | `store`, `hub`, `auth`, `gcal`, `github`, `repodocs`, `blob`, `cmd/spool`, `vendorkey`, `marketing`, `payments` | the same `< 75%` read | 2489 in all. **No Postgres in this run**, so `store`, `hub`, `auth` read low | **Left out**, as rounds 22-27 |
| round 27 2 | WUI raw text | `node tests/unit/i18n-no-raw-text.test.mjs` (archive copy) | `# pass 5`, `# fail 0` | **Left out**, as rounds 22-27 |
| round 27 2 | shellcheck WARNING baseline, gosec, semgrep | **NOT re-measured**: each takes minutes (round 27: 127 s, no verdict at 280 s, 267 s), and no row of this round would take them | none | **Left out**, as rounds 22-27 |

## 3. The 10 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(r54-01-api-hubclient-boottime-regex)` | a pattern matches its whole field, and compiles once | `sec = (\d+)` also matches inside `usec = 7`, so a line with `usec` and no `sec` reports a boot time near 1970 (c-001 d35be041). Normal output prints `sec` first: an edge case, and no one has run it on the real platform | `go:internal/hubclient/host.go:288`<br>`go:internal/hubclient/host_boottime_test.go` (new) | 1 pattern | A package-level `regexp.MustCompile` of `\bsec = (\d+)`. In `package hubclient`, a `hostEnv` keyed on the whole argv (as `host_probes_test.go`), `goos: "darwin"`: the `:287` sample -> `BootAt` from `1696000000`; `{ usec = 7 }` -> `BootAt` empty. Helpers prefixed `bt`. Tests: the new file; `go test -count=1 -race -cover ./internal/hubclient/`; `run-all-tests.sh`. **Probed:** the two patterns on both lines (section 2), not the table test. **Red control:** the old pattern back -> the `usec` case fails. | either | claude | simple_coding | 1 |
| 02 `refactor(r54-02-iac-header-declare-below-keys-sync)` | an action opens with its header, its `declare` line below it (`r46-03`, `r51-04`, `r53-01`) | the loader stops at the first command, so a `declare` line above the header leaves `./run` help blank for the action | `iac:run/gcp-sync-src-s3-to-tgt-s3-silent.func.sh:2`<br>`iac:run/spl-compute-sa-editor-drop.func.sh:2`<br>`iac:run/spl-gh-app-key-put.func.sh:2`<br>`iac:run/spl-vendor-key-grant-check.func.sh:2`<br>`iac:run/spl-vendor-key-pepper-put.func.sh:2` (+ their 5 `[missing]` lines in `iac:t/action-header-tags-baseline.txt`) | 5 files | As `r53-01`: the lines above the first `#---` after the shebang move unchanged to just below the header's closing `#---`; nothing else moves; the 5 `[missing]` lines are deleted in the same commit. These change GCP or secrets when run: the row only moves lines and runs none outside their stubbed tests. **Probed**, rows 02 and 03's moves applied together with 6 baseline lines deleted on a full archive: tags test `22 missing`, `ALL PASS`. Tests: **`action-header-tags.tst.sh`** (`28 missing` -> `23`), **`gcp-key-path-no-eval.tst.sh`**, `spl-compute-sa-editor-drop.tst.sh`, `spl-vendor-key-grant-check.tst.sh`, `spl-vendor-key-pepper-put.tst.sh`, `github-app-key-put-rotate.tst.sh`, **`hub-github-app-key-030.tst.sh`**, `spl-gh-app.tst.sh`, **`gcp-actions-isolated-config.tst.sh`**, **`orc:t/parse-metadata-nofork.tst.sh`** (the last not probed); `./run -a do_check_pre_push_lint`. R9 (a gate's list): `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. **Red control:** on the parent sha `do_parse_metadata <f> \| grep -c '^description='` -> 0 per file; after -> 1, 15, 10, 19, 13 (scratch copies); `^example=` -> 1, 2, 1, 1, 1; longest 91 characters (limit 200); `(required)` -> 0 per file. | either | claude | simple_coding | 1 |
| 03 `refactor(r54-03-iac-header-below-add-examples)` | as row 02, and a header that lacks an `@example` gets one | one more plain move with a longer block above its header, and the two files a move alone cannot clear | `iac:run/spl-secret-unused-list.func.sh:2`<br>`iac:run/gcp-002-delete-project-service-account.func.sh:2`<br>`iac:run/gcp-export-dns-settings.func.sh:2` (+ their 3 `[missing]` lines) | 3 files | As row 02, on the start sha after row 02 lands. `spl-secret-unused-list` has 7 lines above its header (`:2-8`): they move as one block. The other two get one `@example` line each, `ORG=csi APP=csi-spl ENV=dev ./run -a <action>`; no `@param`, so no new `validate-params` refusal. **Probed:** the moves only (row 02); the `@example` lines not. Tests: **`action-header-tags.tst.sh`** (`23 missing` -> `20`), **`spl-secret-unused-list.tst.sh`**, `box-name-from-cnf.tst.sh`, `gcp-002-delete-project-service-account.tst.sh`, `return-not-exit-gcp.tst.sh`, **`orc:t/parse-metadata-nofork.tst.sh`**; `./run -a do_check_pre_push_lint`. R9 as row 02. **`return-not-exit-gcp.tst.sh` has no verdict:** rc 124 at a 280 s timeout on the archive with 3 `PASS` and 0 `FAIL:` before it stopped; the row runs it to the end. **Red control:** as row 02; after the move `spl-secret-unused-list` -> 25 description lines, 1 example, longest 42; the other two -> `^example=` 0, then 1 with the new line. | either | claude | simple_coding | 2 (after 02) |
| 04 `test(r54-04-wui-drop-stale-wide-lines)` | a gate's list holds no stale line (`r52-10`) | r53-03 and r53-04 took `useCardGrip` and `useEditKeys` under the cap and left their lines, as round 27 said | `wui:tests/unit/cleancode.test.mjs:49` (`useEditKeys`)<br>`wui:tests/unit/cleancode.test.mjs:50` (`useCardGrip`) | 2 lines | Delete exactly the two lines the gate NOTEs; `alertSteps` stays (r53-05's). Tests: `node tests/unit/cleancode.test.mjs` (`15 listed wide` -> `13`, no `NOTE WIDE`); `pnpm run test:unit`. R9 as row 02. **Red control:** delete a still-wide line instead (`useCardSwipe`) -> the gate fails naming it, restored. | either | claude | tests | 1 |
| 05 `test(r54-05-api-coverage-floors-raise)` | a coverage floor follows what the tests hold (`r52-06`) | five packages read 1.2 to 2.5 points over their floor, so a lost test goes unnoticed. A package fails only when more than 1.0 under | `api:src/bash/tests/go-coverage-floor.txt:73` (`cicdlogs`)<br>`:81` (`files`)<br>`:93` (`hubclient`)<br>`:96` (`invitemail`)<br>`:116` (`mcp`) | 5 lines | Each raised to the lowest of n=3 `go test -count=1 -race -cover`, in the file's comment format, as `r52-06` did; the reads in section 2 are n=1, plain. Lines of `action`, `sign`, `config`, `keyexec`, `keydesk` not touched. Tests: `run-all-tests.sh`. R9 as row 02. **Red control:** `hubclient` at 99.0 -> the suite fails naming it, restored. | either | claude | tests | 1 |
| 06 `test(r54-06-api-keyexec-desk-env-refusals)` | a key helper's refusals under test | `Exhausted` (66.7): no socket and a refused reply; `tokenOr` (66.7): an empty token; `noVibeEnvFile`, `writeClaudeSettings` (66.7): the seat refusals (the profile's zero blocks `desk.go:113-125`, `env.go:177`, `:189-199`) | `go:internal/keyexec/desk.go:111` (`Exhausted`, 66.7)<br>`go:internal/keyexec/desk.go:122` (`tokenOr`, 66.7)<br>`go:internal/keyexec/env.go:175` (`noVibeEnvFile`, 66.7)<br>`go:internal/keyexec/env.go:188` (`writeClaudeSettings`, 66.7)<br>`go:internal/keyexec/desk_env_refusals_test.go` (new) | 4 functions | `t.TempDir()` only; fake strings, never a real key. `SockDesk{}` -> `no desk key socket`. A desk answering `OK: false` with a token and with none -> `*RefusedError` carrying the token, then `refused` (the fake desk is at `keyexec_test.go:81`; whether it can answer that was not read, else a local listener). `noVibeEnvFile`: no `HOME` -> nil; `.vibe/.env` present -> the error; absent -> nil. `writeClaudeSettings`: an empty seat dir, mode 0755, a blank helper -> each its error; a good one -> mode 0600 and the helper in the body. Non-test code unchanged; floor file not edited. Helpers prefixed `dr`. Tests: `go test -count=1 -race -cover ./internal/keyexec/`; `run-all-tests.sh`. **Red control:** `if !r.OK` (`desk.go:116`) -> `if false`: the refused case fails. | either | claude | tests | 1 |
| 07 `test(r54-07-api-keydesk-seal-identity-refusals)` | a key desk's refusals under test | `peerOf` (71.4), `Seal` (66.7), `LoadOrCreateIdentity` (72.2): the profile's zero blocks (`peer_linux.go:21`, `seal.go:44-57`, `:104-118`). `Open` shares the file: its `:63`, `:71`, `:77` too | `go:internal/keydesk/peer_linux.go:19` (`peerOf`, 71.4)<br>`go:internal/keydesk/seal.go:42` (`Seal`, 66.7)<br>`go:internal/keydesk/seal.go:95` (`LoadOrCreateIdentity`, 72.2)<br>`go:internal/keydesk/seal_refusals_test.go` (new, `//go:build linux`) | 3 functions | `t.TempDir()` only, keys generated in the test and never printed. `net.Pipe` -> `not a unix connection`. `Seal` to a recipient whose `Wrap` fails -> an error, no output. `Open`: a body that does not decrypt; a plaintext with an unknown field -> its message. `LoadOrCreateIdentity`: a garbage identity file -> a parse error; a path under a missing directory -> an error and no file. `TestIdentityFile` (`keydesk_test.go:393`) has the mode case. `peerOf`'s `Control` failures stay out (a kernel error only). Non-test code unchanged; floor file not edited. Helpers prefixed `sf`. Tests: `go test -count=1 -race -cover ./internal/keydesk/`; `run-all-tests.sh`. **Red control:** `peerOf`'s `!ok` branch (`:21`) returning `Peer{}, nil` -> the `net.Pipe` case fails. | either | claude | tests | 1 |
| 08 `refactor(r54-08-wui-pin-touch-lift-object)` | pin a wide function's untested rules, then pass its inputs as one object (`r53-03`) | `useCardTouchLift` takes 6 parameters and is listed in `WIDE`; no unit test runs it (`git grep -l useCardTouchLift 681cf8c63 -- csi-spl-wui/tests` -> `cleancode.test.mjs` and **`lib/message-card-src.mjs`**, both source readers) | `wui:src/composables/useCardTouchLift.ts:59` (6 params)<br>`wui:src/components/MessageCard.vue:754` (its one caller)<br>`wui:tests/unit/card-touch-lift.test.mjs` (new) | 1 function, 1 caller, 3 pins | With `importTsStubbed`, stubbing `~/utils/touch-ui`, `~/utils/move-drag` (`createHandleDrag` captures its options), `~/composables/useMobileStack`, `~/composables/useCardSwipe` (`buzz`), and a global `document`. **Probed**, one scratch test, n=1: it loads; `touchLift` follows `editing`; `onStart` calls `stopOthers` and `close`, sets the picker false; a no-travel `onDrop` opens the menu at the lift point. **Pin first:** **(E)** no lift while editing (break: `:63` without `!editing.value`); **(S)** a lift stops the card's other gestures (break: `:76` deleted); **(D)** a drop with no travel opens the menu (break: `:96` deleted). Each red only under its own break (paste the `not ok`), restored; the breaks were not planted. **Then** `useCardTouchLift({ rowEl, editing, pickerOpen }, mv, stopOthers, menu)`. Leave the `WIDE` line (round 29). Tests: the new file; the 17 readers of **`lib/message-card-src.mjs`**; `pnpm run typecheck`; `pnpm run test:unit`; `node tests/unit/cleancode.test.mjs` (a `NOTE WIDE:` after); the e2e files the map selects. **Control:** the three pins red under their breaks, green before and after. | either | claude | simple_coding | 1 |
| 09 `refactor(r54-09-wui-pin-swipe-flags-object)` | as row 08 | `useCardSwipeFlags` takes 6 parameters and is listed in `WIDE`; no test names it but the gate (`git grep -l useCardSwipeFlags 681cf8c63 -- csi-spl-wui/tests` -> `cleancode.test.mjs`) | `wui:src/composables/useCardSwipe.ts:59` (6 params)<br>`wui:src/components/MessageCard.vue:740` (its one caller)<br>`wui:tests/unit/card-swipe-flags.test.mjs` (new) | 1 function, 1 caller, 3 pins | With `importTsStubbed`, stubbing `~/utils/touch-ui`, `~/utils/swipe-archive.mjs`, `~/utils/reselect-row.mjs`, `~/utils/undo-timer`, `~/composables/useHiddenCards`, `~/composables/useMobileStack`, `~/stores/live`, `~/stores/topic`. **Probed**, one scratch test, n=1: it loads; `swipeOn` follows `editing`; a sent reply's left swipe is `hide`, a pending one's `null`. **Pin first:** **(E)** no swipe while editing (break: `:70` without `!editing.value`); **(P)** a pending reply is not hidden (break: `:88` without the `pending` test); **(A)** the archive rule in the topic view (break: `:75` without `mayArchive()`; not probed). Each red only under its own break, restored. **Then** `useCardSwipeFlags(props, { editing, rowEl, inPane, showTopicArchive }, mayArchive)`; returned keys unchanged. Leave the `WIDE` line. Tests: the new file; the readers of **`lib/message-card-src.mjs`**; `card-move-steps.test.mjs`; `pnpm run typecheck`; `pnpm run test:unit`; `node tests/unit/cleancode.test.mjs`; the e2e files the map selects. **Control:** as row 08. | either | claude | simple_coding | 2 (after 08) |
| 10 `refactor(r54-10-wui-pin-swipe-commit-object)` | as row 08 | `useCardSwipe` takes 6 parameters and is listed in `WIDE`; the only test naming it other than the source readers stubs its `buzz` (`card-move-steps.test.mjs:48`) | `wui:src/composables/useCardSwipe.ts:124` (6 params)<br>`wui:src/components/MessageCard.vue:742` (its one caller)<br>`wui:tests/unit/card-swipe-commit.test.mjs` (new) | 1 function, 1 caller, 3 pins | As row 09's stubs, `createSwipe` capturing its options. **Not probed.** **Pin first:** **(L)** a swipe lock stops the card's other gestures (break: `:146` deleted); **(M)** a menu commit closes the picker (break: `:160` deleted); **(B)** the shell's Back zone refuses a right swipe (break: `:143` -> `canRight: () => true`). Each red only under its own break, restored. **Then** `useCardSwipe({ props, rowEl, swipeLeft, pickerOpen }, menu, peer)`; `peer` and the returned keys unchanged. Leave the `WIDE` line. Tests: as row 09. **Control:** as row 08. | either | claude | simple_coding | 3 (after 09) |

### 3.1 Lanes and batches

- **Batch 1: rows 01, 02, 04, 05, 06, 07, 08, no file in two rows.** Row 01 owns
  `host.go` and its new test; row 02 its 5 actions and
  `action-header-tags-baseline.txt`; row 04 `cleancode.test.mjs`; row 05
  `go-coverage-floor.txt`; rows 06 and 07 one new test file each, in `keyexec` and
  `keydesk`; row 08 `useCardTouchLift.ts`, `MessageCard.vue` and its new test. Rows
  04-07 change no non-test code. None edits a migration, `csi-spl-cnf/`, a workflow
  or terraform.
- **Batch 2: rows 03, 09.** Row 03 shares the baseline file with row 02; row 09
  shares `MessageCard.vue` with row 08. Each placed within 30 minutes of its
  prerequisite landing (R16); they share no file with each other.
- **Batch 3: row 10** shares `useCardSwipe.ts` and `MessageCard.vue` with row 09.
- Under "keep 2 row lanes in parallel" (686bc1a3) the dispatch holder places any two
  batch 1 rows, then the next as each lands. Suggested order: row 02 and row 08 first,
  since each one opens a later batch.

### 3.2 Off every live lane and every queued row (R3)

- **Live lanes:** `lane-map.sh --check <the 25 paths of the 10 rows, the new files included, comma separated> --agent c-393`
  -> **exit 4** (2026-11-08T16:36:30Z, exit code read directly, not piped). No path is
  printed as owned. Ten live lanes on the other box record no files: `c-110`, `c-417`,
  `c-785`, `c-820`, `c-828`, `c-847`, `c-863`, `c-870`, `c-890`, `c-923`. **Exit 4 is
  not free, and this plan did not clear it:** the other box's worktrees cannot be read
  from here (its gate allows no shell). Of the briefs reachable on this box, the three
  named by slug plus c-785's earlier slug, `grep -cE <the row paths>` -> 0 hits each.
  That shows what those four briefs name, not what those lanes have edited; the six
  `-rotate` lanes were not read at all. The dispatch holder re-runs the check before
  each row's spawn (R3).
- **`lane-map.sh --json`** prints `files: []` for all 85 lanes, so this plan used
  `--check`, not the JSON, for ownership.
- **Spawn queue (2026-11-08, about 16:3xZ):** `./run -a do_spl_spawn_queue` -> 64 rows
  parsed; all 64 briefs read on this box, grepped for the rows' paths and names ->
  one hit, `c002-bug-lockkey-seal-shred-loses-recovery-code` naming
  `go-coverage-floor.txt`, and that brief lists the file under "NOT yours". A grep
  finds only what it was told to look for.
- **Open rows of earlier rounds:** r53-05 (lane c-385; review branch on origin), r53-10.
  r53-09 landed. No row here names `notification.ts`, `react.go`, `ask.go`, `link.go`,
  `sign.go` or `config.go`.
- **Trunk moved while this was measured:** at `origin/master` `611008598`, 2 commits
  past `681cf8c63`, `git diff --stat 681cf8c63 origin/master -- <the 25 paths>` printed
  nothing, so the lines above stand there.

## 4. Per row: what the lane does

- **01:** Anchor the boot-time pattern, compile it once, table-test it.
- **02:** Move five GCP and key actions' headers above their `declare` lines.
- **03:** After 02: the same for three more, two gaining an `@example`.
- **04:** Delete the two stale `WIDE` lines.
- **05:** Raise five Go coverage floors to the lowest of n=3.
- **06:** Unit tests for `keyexec`'s desk and seat refusals.
- **07:** Unit tests for `keydesk`'s peer, seal and identity refusals.
- **08:** Pin three touch-lift rules, pass its inputs as one object.
- **09:** After 08: pin three swipe-flag rules, pass its inputs as one object.
- **10:** After 09: pin three swipe rules, pass its inputs as one object.

## 5. Panel and reviewers (R7)

- Editor: c-393 (claude). Panel reviewer and each row's R7 reviewer: as the dispatch
  lease holder rules on this plan's review sha; this draft names none. Both seats
  sign the plan sha (rulebook 3.2).
- **No land** of this plan before the panel's signature and the holder's GO.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).
- **P1, for the panel:** rows 08-10 leave their `WIDE` lines to round 29, as rows
  r53-03..05 did, because row 04 holds `cleancode.test.mjs` in batch 1.
- **P2, for the panel:** row 01 changes behaviour on an edge line, so its subject is
  `fix`, in a refactor round, as c-001 d35be041 decided.
- **P3, for the panel:** `return-not-exit-gcp.tst.sh` had no verdict at 280 s on the
  scratch copy (row 03). Whether that is its normal run time on this box or a hang on
  an archive copy was not determined.

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| every site of r53-05, r53-09, r53-10 | the brief; r53-05 and r53-10 still open | head of this plan |
| the 9 `(required)` header files | a behaviour change: bug-round input | section 2 |
| `useCardEdit`, `useCardMove`, `useCardMessageActions`, `useCardTopicActions` `WIDE` | round full; **input for round 29** | section 2 |
| `send`, `sendLive`, `liveReader`, `sessionMethods`, `perfFeedPair` | round full, exit 4; **input for round 29** | section 2 |
| this round's and r53-05's `WIDE` lines | row 04's file; **input for round 29** | section 3 |
| `hubclient` `< 75%` (7) | round full; **input for round 29** | section 2 |
| `keyd`, `lockkey` | queued bugs name them | section 2 |
| other floor raises | 5-site cap; **input for round 29** | section 2 |
| `spl_desk_pick` (80) | queued `c002-bug-desk-reply-stub-rc0` | section 2 |
| `do_provision_firebase_dns` (169) | byte-identical port pin: dropped | section 2 |
| `spl_fleet_role_tick`, `_spawn_worktree`, `do_spl_agent_identity_restore` | fleet-critical | section 2 |
| Go `longFuncs`, `wideFuncs`, `store`, `hub`, `auth`, `gcal`, `github`, `repodocs`, `blob`, `cmd/spool`, `vendorkey`, `marketing`, `payments` | as rounds 22-27 | section 2 |
| WUI raw text; shellcheck WARNING baseline, gosec, semgrep (not re-measured) | as rounds 22-27 | section 2 |

## 7. Counts

| metric | n |
|---|---|
| rows | 10 (fix 1, refactor 5, test 4; Go 1 fix + 3 tests and floors, iac 2, wui 4) |
| vendor | claude 10 |
| kind | simple_coding 6, tests 4 |
| batches | batch 1: 7 rows; batch 2: 2 rows; batch 3: 1 row |
| pins added | 9 (rows 08, 09, 10: 3 each) |
| header `[missing]` lines | 28 -> 20 after row 03 |
| WUI `WIDE` lines | 15 -> 13 (row 04); 3 more functions under the cap, their lines in round 29 |
| Go functions taken | 7 at 66.7-72.2 |
| floors raised | 5 |
| measured on | `681cf8c63`, n=1 per command unless stated |

## 8. Changes

- v0.1: first draft (c-393): 10 rows, slug `r54`, measured on `681cf8c63`.

## 9. Consensus

Both seats sign this plan (rulebook 3.2).

- Editor seat: c-393 (claude): drafted v0.1. **Not yet signed.**
- Panel reviewer seat: not yet placed.
