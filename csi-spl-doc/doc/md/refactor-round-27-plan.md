# Refactoring round 27 - plan (10 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5001  
Topic: b4b264a7-95e9-40aa-a863-529c8637c181  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 7f664194 / 8cb6cc7d: the refactoring share of the fleet
  ([fleet-rules-index.md](fleet-rules-index.md)).
- msg b8e22a15: reach consensus in the panel and start, no owner input;
  msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 dc15ad65 msg 686bc1a3: **"keep 2 row lanes in parallel"**: the 9 rows of
  batch 1 share no file (section 3.1), so any two of them can run at once.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows: **vendor
  claude for every row**.
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, pushes
  aim 1 up to 3 never more than 5, R1-R16).

**Why now.** c-001's SPAWN SHARE 2edabb3c (task spawn-share, 2026-11-07 15:47Z,
quoted from this lane's brief, the message itself not read): refactor 10%, and no
refactor row queued. `./run -a do_spl_spawn_queue` (`cd orc:`, 2026-11-07, about
16:2xZ, this session) prints `86 queued, 0 placing (fleet main)` and
`share of 34 known live lanes (12 unknown, left out): refactor 6 17% (band 10-20%: ok), bug 9 26% (band 15-20%: OVER), feature 19 55% (band 60-%: UNDER)`.
No queue row is a refactor:
`grep -E '^[0-9]+/86' <queue output> | awk '{print $3}' | sort | uniq -c` -> 82 `bug`,
4 `bug+urgent`.

Round 26 ([plan](refactor-round-26-plan.md), v1.0, slug `r52`) has rows 01, 02,
03, 04, 07, 08, 09 on `0b2f05cb1`:
`git log 0b2f05cb1 --format=%s | grep -oE 'r52-[0-9]+' | sort -u` -> those 7. Rows
05, 06 and 10 have no commit there (`git log 0b2f05cb1 --oneline --grep='r52-<NN>' | wc -l`
-> 0 each). Row 05 has a review branch and lanes (`review/r52-05-wui-mock-part-object`,
c-230, c-252), row 06 a lane (c-244). **This round touches no site of r52-05, r52-06
or r52-10**, as the brief says. No round 22-26 retro is on `0b2f05cb1`
(`ls csi-spl-doc/doc/md/refactor-round-*-retro.md | sort -V | tail -1` ->
[refactor-round-21-retro.md](refactor-round-21-retro.md)); section 2 re-measures
round 26's section 6 inputs instead.

Round 27 focus: **9 of the 10 rows run at once in batch 1.** Two rows put ten
action headers where `./run` help reads them; three take WUI functions off the
wide list; five put 14 under-tested Go functions under unit test. Batch 2 is the
second header row, because both edit one baseline file.

**Status: v0.3 DRAFT**. The panel seat a-304 (agy) failed v0.2; this folds its findings and waits for its delta. Not signed.

Editor: **c-265** (claude). Panel reviewer: a-304 (agy), placed by the dispatch
lease holder (section 5).

**One sha:** every count is measured on **`0b2f05cb1`** (`origin/master`
0b2f05cb1b54b727f7bac841a7546e0de1375004, 2026-11-07T16:24:43+01:00 / 15:24:43Z),
n=1 per command unless stated. Go: go1.26.10. Bash and Go runs are in this lane's
worktree at `0b2f05cb1` (clean). WUI runs and the header probes are on a
`git archive 0b2f05cb1` copy, the WUI part borrowing another checkout's
`node_modules`, read only. Go coverage is one
`go test -count=1 -coverprofile=<f> ./...` without Postgres (the store and hub
Postgres tests skip; rc 0, 0 `^FAIL` lines), read with `go tool cover -func=<f>`.
Uncovered branches are read from the same profile (the blocks with count 0). Queue
and lane readings are live state, so they carry their own time, not this sha.

## 1. How to read this

- **Slug prefix `r53`.** `git log 0b2f05cb1 --oneline -E --grep='r53-' | wc -l`
  -> 0; `grep -rl 'r53-' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote /var/spool-hub/asks 2>/dev/null | wc -l`
  -> 0 on this box; `git branch -r | grep -c 'r53-'` -> 0. `r52` is taken. The next
  planner proves its prefix free the same way, and discounts briefs that only quote
  the search.
- One row = one practice = one lane, at the sites named and nowhere else,
  with a test that shows behaviour kept or, for a test row, a **red
  control**: the new case fails on a planted defect and passes after.
- **Paths:** `iac:` = `csi-spl-iac/`, `wui:` = `csi-spl-wui/`,
  `api:` = `csi-spl-api/`, `orc:` = `csi-spl-orc/`,
  `go:` = `csi-spl-api/src/go/spool-hub-api/`;
  `run/` = `src/bash/run/`, `t/` = `src/bash/tests/` of the sub-project named.
  Lines as of `0b2f05cb1`; a function's site is its first line.
- **Box:** `either` for every row (no pin).
- **Vendor:** claude for every row. **R7 reviewer:** a fresh claude session per row, under
  the holder's ruling in section 5; no seat is named before a row is queued.
- **Subject** (R6 reads it): `<type>(r53-NN-<slug>, SPL-<row issue>): ...`.
- **Topic:** every row brief carries the `Topic:` line above; rows report there,
  never on an archived topic.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
- **Re-measure first:** every row lane re-runs the command that measured
  its input in section 2 on the `origin/master` it starts from and says in its
  result if the number moved.
- **Tests per row (R2):** every test file that names a site's basename or a
  function it defines
  (`git grep -l -F -e <basename> 0b2f05cb1 -- '*tst.sh' '*/tests/*' '*test*.sh'`),
  listed per row; **bold** = it reads the site's source text. For Go, the
  package's tests plus `bash api:src/bash/tests/run-all-tests.sh`; for WUI, the
  unit tests and the e2e files the pre-push map selects
  (`cd iac: && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e`).
- **Two gate files stay out, so rows leave their lines stale for round 28:**
  `wui:tests/unit/cleancode.test.mjs` is r52-10's and
  `api:src/bash/tests/go-coverage-floor.txt` is r52-06's. Rows 03-05 leave their
  `WIDE` lines (the gate only NOTEs a stale line) and rows 06-10 their floor lines
  (the same deliberate deviation from the floor file's `:4-5` rule as rounds 24-26).
  r52-10 deletes "exactly the lines the gate NOTEs", so a row of this round landing
  first may hand it one more line; that is its call and no edit here.
- **What a probe did and did not show:** a row says "probed" only for what ran on
  the scratch copy, n=1. No break or red control named in a row has been planted, in
  any row. The cases of rows 06-10 are read from the source and the coverage profile:
  none has been written or run.

## 2. Where the rows come from (measured on `0b2f05cb1`)

**Taken:**

| source | input | command on `0b2f05cb1` | n | row |
|---|---|---|---|---|
| round 26 6 | the 20 declare-first files | `awk 'FNR==1{h=0;d=0} /^# *@(description\|param\|example)/{if(d){print FILENAME;nextfile};h=1} /^declare /{if(!h)d=1}' iac:run/*.func.sh orc:run/*.func.sh utl:run/*.func.sh \| wc -l`; `bash iac:t/action-header-tags.tst.sh` | **20** files; `measured 789 files: 38 missing, 4 long-example`. Of the 20: 2 carry `(required)` (`grep -ciE '^# *@param .*\(required\)'`), 2 have no `@example` at all (below), 16 are a plain move | **Rows 01, 02** take ten of the 16. r51-10 landed, so the baseline file is free |
| round 26 6 | the 15 other WUI `WIDE` functions | `node tests/unit/cleancode.test.mjs` (archive copy); `grep -n` on the list and on each function's callers | `cleancode: 13138 functions, 0 listed long, 17 listed wide, none deeper than 4 or wider than 5`. Three are file-local with one caller and no owner: `useCardGrip` (`useCardHeight.ts:122`, caller `:118`), `useEditKeys` (`useCardEdit.ts:120`, caller `:116`), `alertSteps` (`notification.ts:201`, caller `:534`) | **Rows 03, 04, 05** |
| round 26 2, 6 | the `< 75%` Go functions | `go tool cover -func=<f> \| awk '$NF+0 < 75.0 && $1!="total:"'`, minus `store`, `hub`, `auth`, `gcal`, `github`, `repodocs`, `blob`, `keyexec`, `keydesk`, `vendorkey`, `marketing`, `payments`, `cmd/spool` | **47** functions | **Rows 06-10** take 14: `cicdlogs` `deliverNote` 71.4; `files` `PutDir` 74.1; `hubclient` `hostOS` 70.6, `hostSystem` 60.0, `hostTimezone` 62.5, `sendPending` 66.7, `SendChannelClaims` 66.7, `SendMessageClaims` 73.5, `copyBlobs` 66.7; `action` `React` 64.7, `askBody` 74.1, `HubTail` 72.7; `sign` `LoadPin` 72.7; `config` `checkStorage` 70.6 |

**Deferred or dropped:**

| source | input | command on `0b2f05cb1` | n | disposition |
|---|---|---|---|---|
| round 26 6 | the 6 other plain-move header files (`gcp-sync-src-s3-to-tgt-s3-silent`, `spl-compute-sa-editor-drop`, `spl-gh-app-key-put`, `spl-secret-unused-list`, `spl-vendor-key-grant-check`, `spl-vendor-key-pepper-put`) | as rows 01, 02 | 6. `spl-secret-unused-list` has 7 lines above its header, not 2 or 3 (`grep -n '^#---'`) | **Round 28**: this round is full, and each more header row is one more batch |
| fresh | `gcp-002-delete-project-service-account`, `gcp-export-dns-settings` | a scratch copy with the header moved, `do_parse_metadata <f> \| grep -c '^example='` | 0 each. **A move does not clear their `[missing]` lines**: round 26's plan counts them among the 20 and does not say so. Their parsed header gets a description and still no example | **Round 28**: a row that also writes one `@example` per file |
| round 26 6 | the `(required)` header files | `awk '/^\[missing\]/{m=1;next} /^\[/{m=0} m && /^csi-spl-/' iac:t/action-header-tags-baseline.txt \| xargs grep -l '(required)' \| wc -l` | **9**: reproduces. `gcp-project-delete` and `gcp-tail-logs` are also declare-first; `validate-params` checks every parsed `(required)` (`lib/bash/funcs/validate-params.func.sh:33`), so a move adds that check to them | **Left out**: a behaviour change (bug-round input), as rounds 20-26 |
| round 26 6 | `useCardMove`, `useCardMessageActions`, `useCardTopicActions` `WIDE` lines | lane rows c-246 and c-259 (scopes: pins for `useCardTopicActions`); queued `c002-bug-wui-e2e-click-mock-poll-remount` forbids itself `useCardMove.ts` and `useCardTopicActions.ts` | `--check` on `useCardTopicActions.ts`: rc 4, no owner printed; c-246's change is in its test file. The lane's scope is the reading here | **Left out** while those lanes live |
| round 26 6 | `send`, `sendLive` (`channel.ts`); `liveReader`, `sessionMethods` (`spool-client.mjs`); `perfFeedPair` (its caller `perf-mark.mjs:75`) | `lane-map.sh --check` per path, 2026-11-07 about 16:2xZ; `lane-map.sh --json` | rc 3: `channel.ts`, `perf-mark-core.mjs` owned by c-023 (`perf-mark.mjs` in its recorded files); `spool-client.mjs` owned by c-023 and c-262. c-023's row was last updated 08:22:04Z, and its worktree on this box shows no change under `csi-spl-wui/` (`diff --name-only origin/master...HEAD`, `status --short`) | **Left out**: owned is owned; the dispatch holder may ask whether c-023 still holds them |
| round 26 6 | `useCardSwipe`, `useCardSwipeFlags`, `useCardTouchLift`, `useCardEdit` | `git grep -lE '\b<name>\b' 0b2f05cb1 -- csi-spl-wui/src` | each is named in `MessageCard.vue`, its caller | **Round 28**: round full; each edits `MessageCard.vue`, so they cannot share a batch |
| round 26 6 | `tenant-costs.mjs` `mockPart`; `calendar-events-api.mjs` `send` | the brief; the gate's `NOTE WIDE` | r52-05's site; the other is done and waits for r52-10 | **Left out** (r52-05, r52-10) |
| round 26 6 | `spl_desk_pick` (80) | `grep -c 881adc37 <queue output>` -> 0: that hold is gone. But queued `c002-bug-desk-reply-stub-rc0` names `spl-desk-reply` | 1 brief | **Left out** on the new hold |
| round 26 6 | `do_provision_firebase_dns` (169) | `sed -n 28,30p iac:t/wui-hosting-019-031.tst.sh` | the `sha256sum` port pin stands | **Dropped**, as round 26: a split would break the pin, an owner-level port decision |
| round 26 6 | `spl_fleet_role_tick` (78), `_spawn_worktree` (79), `do_spl_agent_identity_restore` (80) | `grep -nE` on `LONG` in `iac:t/bash-cleancode.tst.sh` | all three listed; `LONG` holds 5 lines | **Left out**: fleet-critical, as rounds 22-26 |
| round 26 6 | `keyexec` (5), `keydesk` (3) | `go tool cover -func`; `grep -c 81ac0fa0 <queue output>` -> 0; `grep -lE 'keyexec\|keydesk'` on the 86 queued briefs -> 0 | 8 functions at 66.7-72.2. Its hold is gone | **Round 28**: free now, round full |
| round 26 6 | `keyd` (`listenSock`, `Serve`, `Rotate`, ...), `lockkey` (`writeFile`, `writeSealed`, ...) | `grep -lE '\bkeyd\b'` and `grep -lF internal/lockkey` on the queued briefs | queued `c002-bug-keyd-openscrypt-limit-tests` and `c002-bug-lockkey-seal-shred-loses-recovery-code` name them | **Left out** until those bugs land: tests written now could pin the behaviour they fix |
| round 26 6 | `hubclient.go` sites (`WaitQueueEnd` 40.0, `sendFrame`, `writeAtomic`, ...) | the queued briefs | queued `c002-bug-lane-map-hub-read-errors` and `c002-bug-lane-read-state-live` name `internal/hubclient` | **Left out**, as round 26. Rows 07 and 08 touch no such file: no brief names `host.go`, `flush.go` or `reroute.go` |
| round 26 6 | the floor raises of `hubclient`, `keyd`, `lockkey` (r52-07..09) and `mcp`, `invitemail`, `notify` | package coverage against the floor file | read / floor: `hubclient` 87.8 / 85.9, `lockkey` 83.6 / 79.3, `mcp` 90.0 / 88.7, `invitemail` 87.8 / 85.3, `notify` 96.6 / 94.8; `keyd` 83.9 / 82.2. `--check` on the file: rc 3, c-244 | **Round 28**: r52-06 holds the file |
| round 26 6 | Go `longFuncs` (2), `wideFuncs` (14) | `go test -count=1 -v ./internal/cleancode/ \| grep -c 'no longer'` | 0 stale, rc 0 | **Left out**: `store`, `auth`, `hub`, as rounds 22-26 |
| round 26 6 | `store`, `hub`, `auth`, `gcal`, `github`, `repodocs`, `blob`, `cmd/spool`, `vendorkey`, `marketing`, `payments` | the same `go tool cover -func`, `< 75%` per package | 1531, 655, 82, 49, 34, 22, 21, 58, 1, 10, 15. **No Postgres in this run**, so `store`, `hub` and `auth` read low: these say how many, not how badly | **Left out**, as rounds 22-26 |
| round 26 6 | the other 33 `< 75%` functions (47 less 14) | as rows 06-10 | 33, among them the `keyd`, `lockkey` and `hubclient.go` sites above; `mcp` `Run`, `gcpalerts` `Run`, `cloud` `OSEnv` at 0.0 are one-line entry points | **Round 28**, or not worth a row |
| round 26 6 | WUI raw text | `node tests/unit/i18n-no-raw-text.test.mjs` (archive copy) | `# tests 5`, `# pass 5`, `# fail 0` | **Left out**, as rounds 22-26 |
| round 26 6 | shellcheck WARNING baseline | `./run -a do_sec_shellcheck` (`cd iac:`, this lane's tree) | rc 0 at 127 s, `shellcheck: no new findings (baseline holds)` | **Left out**, as rounds 22-26 |
| round 26 6 | gosec / semgrep | `timeout 280 ./run -a do_sec_gosec`, `timeout 280 ./run -a do_sec_semgrep` (`cd iac:`, a login shell of the box user) | semgrep: rc 0 at 267 s, `semgrep: no new findings (baseline holds)`, measured this time (round 26 got no verdict). gosec: **NOT measured**, rc 124 at the 280 s timeout, no verdict. Baselines: `.gosec-baseline.txt` 4 lines, `.semgrep-baseline.txt` 1, `.shellcheck-warning-baseline.txt` 95 (`grep -vcE '^(#\|$)'`) | **Left out**, as rounds 22-26 |

## 3. The 10 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r53-01-iac-header-declare-below-gcp-reads)` | an action opens with its header, its `declare` line below it (`r46-03`, `r51-04`) | the loader stops at the first command, so a `declare` line above the header leaves `./run` help blank for the action | `iac:run/gcp-audit-iam.func.sh:2`<br>`iac:run/gcp-audit-wsdoc-buckets.func.sh:2`<br>`iac:run/gcp-compute-lb-list.func.sh:2`<br>`iac:run/gcp-hub-instance-health.func.sh:2`<br>`iac:run/gcp-report-sa-usage.func.sh:2` (+ their 5 `[missing]` lines in `iac:t/action-header-tags-baseline.txt`) | 5 files | As `r51-04`: the lines above the first `#---` after the shebang move unchanged to just below the header's closing `#---`; nothing else moves; the 5 `[missing]` lines are deleted in the same commit (the tags test FAILS a stale one). **Probed**, with rows 01 and 02 applied together on a full archive: tags test 6 `PASS:`, `28 missing`, rc 0. Tests: **`action-header-tags.tst.sh`** (`38 missing` -> `33`), `adhoc-harvest-gcp-actions.tst.sh`, `gcp-audit-wsdoc-buckets.tst.sh`, **`gcp-compute-lb-list.tst.sh`**, `gcp-hub-instance-health.tst.sh`, `gcp-report-sa-usage.tst.sh`, **`orc:t/parse-metadata-nofork.tst.sh`**; `./run -a do_check_pre_push_lint`. R9 (a gate's list): `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. **Red control:** on the parent sha `do_parse_metadata <f> \| grep -c '^description='` -> 0 per file; after -> 13, 24, 4, 13, 18 (read on the scratch copies); `grep -c '^example='` -> 2, 1, 1, 2, 2; the longest example 103 characters (limit 200); `grep -ci '^param=.*(required)'` -> 0 per file (no new refusal). | either | claude | simple_coding | 1 |
| 02 `refactor(r53-02-iac-header-declare-below-gcp-writes)` | as row 01 | as row 01. These five change GCP when run: the row only moves lines and runs none of them outside their stubbed tests | `iac:run/gcp-alert-snooze.func.sh:2`<br>`iac:run/gcp-hub-restart.func.sh:2`<br>`iac:run/gcp-compute-lb-cleanup.func.sh:2`<br>`iac:run/gcp-delete-service-account.func.sh:2`<br>`iac:run/gcp-purge-wsdoc-prefix.func.sh:2` (+ their 5 `[missing]` lines) | 5 files | As row 01, on the start sha after row 01 lands (`33 missing` -> `28`). Tests: **`action-header-tags.tst.sh`**, `gcp-alert-snooze.tst.sh`, **`gcp-hub-restart.tst.sh`**, `orc:t/heal-hub-deploy.tst.sh`, `github-app-key-put-rotate.tst.sh`, `gcp-compute-lb-cleanup.tst.sh`, `gcp-delete-service-account.tst.sh`, `gcp-purge-wsdoc-prefix.tst.sh`, **`orc:t/parse-metadata-nofork.tst.sh`**; `./run -a do_check_pre_push_lint`. R9 (a gate's list): `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. **Red control:** as row 01; after -> 20, 19, 8, 5, 21 description lines (scratch copies), 2 examples each, longest 98. | either | claude | simple_coding | 2 (after 01) |
| 03 `refactor(r53-03-wui-pin-card-grip-object)` | pin a wide function's untested rules, then pass its inputs as one object | `useCardGrip` takes 6 parameters and is listed in `WIDE`; no unit test runs its keys or its click (`git grep -lE 'useCardHeight\|useCardGrip' 0b2f05cb1 -- csi-spl-wui/tests` -> `cleancode.test.mjs` and **`lib/message-card-src.mjs`**, both source readers) | `wui:src/composables/useCardHeight.ts:122` (`useCardGrip`, 6 params)<br>`wui:src/composables/useCardHeight.ts:118` (its one caller)<br>`wui:tests/unit/card-grip.test.mjs` (new) | 1 function, 1 caller, 3 pins | With `importTsStubbed`, stubbing `~/composables/useLinkPreviewRefs` and `~/utils/viewport-resize`. **Probed:** that loads, `useCardHeight` returns `startGrip`, `onGripClick`, `onGripKey`; another key calls no `preventDefault`, ArrowDown one, and a click sets `userPx` null. **Pin first:** **(K)** only the arrows act (break: `:163` deleted); **(C)** a click right after a drag does nothing (break: `:153` -> `if (false)`); **(D)** a pointer move under 3 px is no drag (break: `:137` without the `Math.abs(dy) < 3`). (C) and (D) drive `startGrip`, which needs a global `HTMLElement`: not probed by the editor; a-304 reports them driven under a stub `HTMLElement` (its verdict, not re-run here). Each red only under its own break (paste the `not ok`), restored. **Then** `useCardGrip({ clipEl, clipPx, clipped, userPx }, m, measure)`; same three returned functions. Leave the `WIDE` line. Tests: the new file; the 17 readers of **`lib/message-card-src.mjs`** (`git grep -l message-card-src 0b2f05cb1 -- csi-spl-wui/tests`); `pnpm run typecheck`; `pnpm run test:unit`; `node tests/unit/cleancode.test.mjs` (a `NOTE WIDE:` after); the e2e files the map selects. **Control:** the three pins red under their breaks, green before and after. | either | claude | simple_coding | 1 |
| 04 `refactor(r53-04-wui-pin-edit-keys-object)` | as row 03 | `useEditKeys` takes 6 parameters and is listed in `WIDE`; no test names it (`git grep -l useEditKeys 0b2f05cb1 -- csi-spl-wui/tests` -> `cleancode.test.mjs` only) | `wui:src/composables/useCardEdit.ts:120` (`useEditKeys`, 6 params)<br>`wui:src/composables/useCardEdit.ts:116` (its one caller)<br>`wui:tests/unit/card-edit-keys.test.mjs` (new) | 1 function, 1 caller, 3 pins | With `importTsStubbed`, stubbing `~/composables/useMentionPicker` and `~/composables/useMentionPoke`, and a global `useId`. **Probed:** that loads and `useCardEdit` returns `onEditKey` and `save`; `startEdit` then threw `editMp.decode is not a function` under the probe's stub, so **no key was run**: the stub needs `decode`; a-304 reports E, S and O driven with `editMp.decode` stubbed (its verdict, not re-run here). **Pin first:** **(E)** Esc closes the editor and clears `editError` (break: `:146` deleted); **(S)** Enter while saving calls `preventDefault` and no second `commit` (break: the `:134` guard removed); **(O)** another key commits nothing (break: `:150` deleted). Each red only under its own break, restored. **Then** `useEditKeys({ props, emit, editEl, editError, msgEdit }, box)`. **Trap:** do not fold the new fields into `box`: `:116` spreads `box` into what `useCardEdit` returns, so they would leak to `MessageCard.vue`. Returned keys unchanged (a pin asserts the list). Leave the `WIDE` line. Tests: the new file; **`msg-edit.test.mjs`**; **`names-not-ids.test.mjs`**; the readers of **`lib/message-card-src.mjs`**; `pnpm run typecheck`; `pnpm run test:unit`; `node tests/unit/cleancode.test.mjs`; the e2e files the map selects. **Control:** as row 03. | either | claude | simple_coding | 1 |
| 05 `refactor(r53-05-wui-pin-alert-steps-object)` | as row 03 | `alertSteps` takes 6 parameters and is listed in `WIDE`; one caller, and no test runs it (`git grep -n alertSteps 0b2f05cb1 -- csi-spl-wui/tests` -> the `WIDE` line only) | `wui:src/stores/notification.ts:201` (`alertSteps`, 6 params)<br>`wui:src/stores/notification.ts:534` (its one caller)<br>`wui:tests/unit/alert-steps.test.mjs` (new) | 1 function, 1 caller, 4 pins | With `importTsStubbed`, stubbing `pinia` (`defineStore: (_, fn) => fn`, `skipHydrate: (x) => x`) and `~/composables/useHumanNames` (`names: ref(...)`, the key `copyFor` reads), and globals `computed`, `ref`, `watch`, `useNuxtApp`, `Notification`. **Probed** with a 46-line test on a scratch archive of `0b2f05cb1`, alone (not under `pnpm run test:unit`), n=1: the store loads; `ingest` of a mention -> one notification with the name in title and body and url `/en/m/m1`; alerts off -> none; `testAlert` -> `shown`. **Pin first**, each break a changed argument at `:534`: **(A)** alerts off -> no notification (break: `alertsOn` -> `computed(() => true)`); **(N)** the url has its locale prefix (break: `nuxtApp` -> `{ $localePath: (p) => p }`); **(I)** the title is the translated key (break: `i18n` -> `{ t: () => '' }`); **(H)** the sender and the body read the member's name (break: `humanNames` -> `{ names: ref({}) }`). All four breaks probed red; the probe held N, I and H in one `it`, so the lane splits them and shows each red only under its own break (paste the `not ok`), restored. **Then** `alertSteps(prefs, steps, { alertsOn, nuxtApp, i18n, humanNames })`, the body unchanged (the probe used a destructured parameter: all green). The tuple return, `type Alerts` (`:267`) and `prefs` unchanged. Leave the `WIDE` line. Tests: the new file; **`notify.test.mjs`**, **`ai-message.test.mjs`**, **`swallow-reasons.test.mjs`**, **`verbosity-notify-wire.test.mjs`** (all read this file's text); `pnpm run typecheck`; `pnpm run test:unit`; `node tests/unit/cleancode.test.mjs`; the e2e files the map selects (a-304 read six, none running `alertSteps`; `notify-settings.test.mjs` is cut at rank 7, its run, not re-run here). **Control:** the four pins red under their breaks, green before and after. **Control 2:** the object without `humanNames` -> `pnpm run typecheck` fails naming it (paste it), restored. | either | claude | simple_coding | 1 |
| 06 `test(r53-06-api-cicdlogs-note-files-putdir)` | two delivery and storage helpers' refusals under test | `deliverNote` (71.4): no signer, an invalid message, a refused `Bus.Deliver`; `PutDir` (74.1): the store cannot be made, the tree cannot be read | `go:internal/cicdlogs/cicdlogs.go:444` (`deliverNote`, 71.4)<br>`go:internal/cicdlogs/deliver_note_test.go` (new)<br>`go:internal/files/files.go:57` (`PutDir`, 74.1)<br>`go:internal/files/put_dir_refusals_test.go` (new) | 2 functions | `t.TempDir()` only. `deliverNote` in `package cicdlogs`, with a stub `Bus` (`cicdlogs.go:77`) and the helpers of `cicdlogs_test.go`: a signer of the wrong size -> `ErrNoHubSigner`, `Deliver` never called; a request the message refuses -> that error; `Deliver` refusing -> that error, no `Result`. `PutDir` in `package files`: `filesDir` under a regular file -> the `MkdirAll` error; a subdirectory of mode 000 (skip at `os.Geteuid() == 0`) -> an error and no `.tar-*` left in `filesDir`. The `Close` and `writeBlob` failures stay out (I/O only). Non-test code unchanged; floor file not edited. Helpers prefixed `dn`, `pd`. Tests: `go test -count=1 -race -cover ./internal/cicdlogs/ ./internal/files/`; `run-all-tests.sh`. **Red control:** `deliverNote` without its signer check (`:445`) -> the wrong-size case fails. | either | claude | tests | 1 |
| 07 `test(r53-07-api-hubclient-host-probes)` | the host fact sheet's other platform and fallbacks under test | `hostOS` (70.6), `hostSystem` (60.0): the `darwin` branches never run, `fakeHostEnv` is a Linux box (`host_test.go:17`); `hostTimezone` (62.5): `/etc/timezone` and the clock fallback | `go:internal/hubclient/host.go:216` (`hostOS`, 70.6)<br>`go:internal/hubclient/host.go:247` (`hostSystem`, 60.0)<br>`go:internal/hubclient/host.go:300` (`hostTimezone`, 62.5)<br>`go:internal/hubclient/host_probes_test.go` (new) | 3 functions at 60.0-70.6 | In `package hubclient`, a `hostEnv` keyed on the whole argv (`fakeHostEnv` keys on `argv[0]`, so `sysctl -n <x>` needs its own). `goos: "darwin"`: `sw_vers` -> name and version; `sysctl` `machdep.cpu.brand_string`, `vm.loadavg` `{ 1.0 2.0 3.0 }`, `hw.memsize`, `kern.boottime` `{ sec = 1700000000, ... }` -> CPU, load, MB, boot time; a garbage `hw.memsize` and a `kern.boottime` with no `sec =` -> those fields left empty. Another goos with `uname -r` -> that kernel; a failing `uname` -> none. `hostTimezone`: `/etc/timezone` wins over the link; no file and a `nil` `readlink` -> the clock's zone name. No real command runs. Non-test code unchanged; floor file not edited. Helpers prefixed `hp`. Tests: `go test -count=1 -race -cover ./internal/hubclient/`; `run-all-tests.sh`. **Red control:** `s.MemTotalMB = n >> 20` (`:284`) -> `= n`: the darwin case fails. | either | claude | tests | 1 |
| 08 `test(r53-08-api-hubclient-send-refusals)` | the send path's refusals under test | `sendPending` (66.7): the blob loop and the cli `from_not_announced` case; `SendChannelClaims` (66.7), `SendMessageClaims` (73.5): their refusals; `copyBlobs` (66.7): skip and missing source | `go:internal/hubclient/flush.go:225` (`sendPending`, 66.7)<br>`go:internal/hubclient/flush.go:153` (`SendChannelClaims`, 66.7)<br>`go:internal/hubclient/flush.go:41` (`SendMessageClaims`, 73.5)<br>`go:internal/hubclient/reroute.go:165` (`copyBlobs`, 66.7)<br>`go:internal/hubclient/send_refusals_test.go` (new) | 4 functions at 66.7-73.5 | In `package hubclient`, `newFakeHub` (`submit_test.go:58`), `refuse` set to the token. A cli session answered `TokenFromNotAnnounced` -> `DeliveryPending`, pending file kept, `reject` not called; a box session the same, with a 4xx status -> the client-error path; an attachment `Mode` other than `blob` -> no upload; an `ErrUnreachable` upload -> `DeliveryPending` before any send. `SendChannelClaims`, `SendMessageClaims`: no box key -> error, nothing in the outbox. `copyBlobs`: non-blob skipped; destination already there skipped; source absent -> `is not in the local store`. `newFakeHub` has no `/v1/files` route (`submit_test.go:62`, `:123`), so an upload there is a `*HubError`, not `ErrUnreachable`; for the unreachable case set `sess.c.Cfg.HubURL = "http://127.0.0.1:0"` after `Dial`, with the blob in `Cfg.FilesDir()`. **Probed** on a scratch archive, n=1: the fake hub -> `unreachable=false`, a `*HubError`; port 0 -> `unreachable=true`. `hold` stays out (timers). Non-test code unchanged; floor file not edited. Helpers prefixed `sr`. Tests: `go test -count=1 -race -cover ./internal/hubclient/`; `run-all-tests.sh`. **Red control:** the `TokenFromNotAnnounced` case at `:242` deleted -> the cli case fails. | either | claude | tests | 1 |
| 09 `test(r53-09-api-action-react-ask-category)` | a verb's hub path and its refusals under test | `React` (64.7): its `TestReactRefusals` (`react_test.go:12`) stops before the hub, so add, remove and list do not run; `askBody` (74.1): the `category` op; `HubTail` (72.7): a refused dial | `go:internal/action/react.go:34` (`React`, 64.7)<br>`go:internal/action/ask.go:104` (`askBody`, 74.1)<br>`go:internal/action/link.go:128` (`HubTail`, 72.7)<br>`go:internal/action/hub_verbs_test.go:82` (a `wire.TReact` case; `verbHub.answer` has none)<br>`go:internal/action/react_hub_test.go` (new) | 3 functions at 64.7-74.1 | Round 26 deferred `React` as "the hub WebSocket call"; `verbHub` (`hub_verbs_test.go:43`) already answers frames for this package's hub tests. `React` on `hubCfg`: add, `Remove`, `List` -> the frame's emoji and op (`h.last`), and the hub's answer back; a hub refusal -> the error. `askBody` with `Op: "category"`: a bad `--by` -> `needs --by`; a bad `--id` -> `--id must be`; a path `CheckAskCategory` refuses -> that reason; a good one -> the body's `ask_id`, `by`, `work_kind`. `HubTail` on an unreachable hub -> an error, no rows. Its row-mapping callback stays out (a non-empty tail in `verbHub` is more scope). Non-test code unchanged; floor file not edited. Helpers prefixed `rh`. Tests: `go test -count=1 -race -cover ./internal/action/`; `run-all-tests.sh`. **Red control:** `hc.React(..., !in.Remove)` (`:58`) -> `in.Remove`: the add case fails. | either | claude | tests | 1 |
| 10 `test(r53-10-api-sign-pin-config-storage)` | a key pin's and the hub config's refusals under test | `LoadPin` (72.7): the corrupt and wrong-size branches never run (the profile's blocks at `:107-112`); `checkStorage` (70.6): its DSN, files and docs refusals | `go:internal/sign/sign.go:98` (`LoadPin`, 72.7)<br>`go:internal/sign/load_pin_test.go` (new)<br>`go:internal/config/config.go:709` (`checkStorage`, 70.6)<br>`go:internal/config/check_storage_test.go` (new) | 2 functions | `t.TempDir()` only, keys generated in the test and never printed. `LoadPin`: a pin file of bad base64 -> `decode pin`; valid base64 of the wrong length -> `wrong size`; the pin path a directory -> an error that is **not** `ErrUnpinned`; none is ever returned as a key. `checkStorage`, called on a `Hub` struct: no `DBDSN`; both `FilesBucket` and `FilesDir`, and neither; both `DocsBucket` and `DocsDir` -> each its own message; a valid `Hub` -> `nil`, one field off per case so a case fails on its own refusal. `validateWorkspaceDocs`, `validateMarketing` stay out (their own test files). Non-test code unchanged; floor file not edited. Helpers prefixed `lp`, `cs`. Tests: `go test -count=1 -race -cover ./internal/sign/ ./internal/config/`; `run-all-tests.sh`. **Red control:** `LoadPin` dropping its size check (`:110`) -> the wrong-length case fails. | either | claude | tests | 1 |

### 3.1 Lanes and batches

- **Batch 1: rows 01, 03, 04, 05, 06, 07, 08, 09, 10, no file in two rows.** Row 01
  owns its 5 actions and `action-header-tags-baseline.txt`; row 03
  `useCardHeight.ts` and `card-grip.test.mjs`; row 04 `useCardEdit.ts` and
  `card-edit-keys.test.mjs`; row 05 `notification.ts` and `alert-steps.test.mjs`; row 06 one new test file in
  `cicdlogs` and one in `files`; rows 07 and 08 one new test file each in `hubclient`,
  with no shared helper (prefixes `hp`, `sr`); row 09 `hub_verbs_test.go` and one new
  test file in `action`; row 10 one new test file each in `sign` and `config`. Rows
  06-10 change no non-test code. None edits `cleancode.test.mjs`,
  `go-coverage-floor.txt`, `MessageCard.vue`, a migration, `csi-spl-cnf/`, a workflow
  or terraform.
- **Batch 2: row 02** shares `action-header-tags-baseline.txt` with row 01 and is
  placed within 30 minutes of row 01 landing (R16).
- Under "keep 2 row lanes in parallel" (686bc1a3) the dispatch holder places
  any two batch 1 rows, then the next as each lands. Suggested order: row 01 with
  one Go test row, so the two lanes run different suites and row 02 opens early.

### 3.2 Off every live lane and every queued row (R3)

- **Live lanes:** `lane-map.sh --check <the 34 paths of the 10 rows, the new files included, comma separated> --agent c-265`
  -> **exit 4** (2026-11-07T16:32:32Z, exit code read directly, not piped). No path
  is printed as owned. Eight live lanes on the other box record no files: `c-216`,
  `c-289`, `c-292`, `c-302`, `c-303`, `c-307`, `c-308`, `c-311`. **Exit 4 is not
  free**, so this plan read them: `git diff --name-only origin/master...HEAD` plus
  `status --short` in each one's worktree over ssh, grepped for the 34 basenames -> 0
  hits in 24 output lines. That shows what they have edited so far, not what they
  will edit, and their briefs were not read.
- **The scope is sometimes the only reading:** c-246 and c-259 are on
  `useCardTopicActions` and `--check` names no owner for that source file (section
  2). `--check` is a recorded-files control and cannot prove a path free.
- **Spawn queue (2026-11-07, about 16:2xZ):** `./run -a do_spl_spawn_queue` -> 86
  queued, 0 placing. **All 86 briefs read by grep:** 85 fetched from the other box, 1
  on this one (round 26 left 2 unread). Grepped for the 34 basenames -> 0 briefs. The
  earlier grep for candidate sites gave the holds in section 2. A grep finds only what
  it was told to look for, so the dispatch holder re-runs the check before each row's
  spawn.
- **Open rows of earlier rounds:** r52-05, r52-06, r52-10, see the head of this plan.
  No row here names `tenant-costs.mjs`, `go-coverage-floor.txt` or
  `cleancode.test.mjs` as a file to edit.
- **Trunk moved while this was measured:** at `origin/master` `234478782`, 6 commits
  past `0b2f05cb1`, `git diff --stat 0b2f05cb1 origin/master -- <the 34 paths>` printed
  nothing, so the lines above stand there.

## 4. Per row: what the lane does

- **01:** Move five read-only GCP actions' headers above their `declare` lines.
- **02:** After 01: the same for five GCP actions that write.
- **03:** Pin three grip rules, pass `useCardGrip`'s inputs as one object.
- **04:** Pin three edit-key rules, pass `useEditKeys`'s inputs as one object.
- **05:** Pass `alertSteps`'s inputs as one object; the body does not change.
- **06:** Unit tests for `cicdlogs` `deliverNote` and `files` `PutDir` refusals.
- **07:** Unit tests for `hubclient` `hostOS`, `hostSystem` and `hostTimezone`.
- **08:** Unit tests for `hubclient` `sendPending`, both send claims and `copyBlobs`.
- **09:** Unit tests for `action` `React`, `askBody`'s category op and `HubTail`.
- **10:** Unit tests for `sign` `LoadPin` and `config` `checkStorage`.

## 5. Panel and reviewers (R7)

- Editor: c-265 (claude). Panel reviewer: a-304 (agy), cross-vendor as rulebook 3.2 asks:
  ask 785ea06b, placement `c002-refactor-round-27-agy-panel-reviewer`. Its verdict goes
  to the editor and the holder on task `dispatch-refactor-r27`. Both seats sign the
  plan sha. The panel seat reviews this plan only, never a row: agy gets no code R7.
- **Row reviewers (holder's ruling, note d15dfe65):** claude author, a fresh claude
  reviewer under waiver 1a7c70da, the holder's GO by hand. The note's reasons, quoted
  from it and not read at their source: grok is off by the owner's order (5902b924),
  mistral reviews are paused (cf7a7ee5), and agy gets no code R7. The ruling lapses on
  the owner's post that grok is back. As in round 26, the waiver does not make a row
  compliant: rulebook 2.7.5 fails an equal vendor pair, and the retro names each such row.
  A row's backup reviewer is a second fresh claude session on the same waiver terms.
- **No land** of this plan before the panel's signature and the holder's GO (same note).
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).
- **P1, answered in v0.3:** a-304 asked for a pin on row 05, and the store did load;
  row 05 now carries four pins. Rows 03 and 04 keep the editor's partial probes, with
  a-304's runs quoted in each row.
- **P2, for the panel:** rows 06-10 leave their floor lines and rows 03-05 their
  `WIDE` lines to round 28, because r52-06 and r52-10 hold those two files.
- **P3, for the panel:** row 02 reorders comments in five actions that can delete or
  restart things. No command runs, and their tests stub GCP. Probed with rows 01 and 02
  applied on a full archive of `0b2f05cb1`, n=1, each rc 0 and no `FAIL`, `PASS` lines:
  tags 6, nofork 15, `adhoc-harvest-gcp-actions` 28, `gcp-audit-wsdoc-buckets` 31,
  `gcp-compute-lb-list` 17, `gcp-hub-instance-health` 23, `gcp-report-sa-usage` 27,
  `gcp-alert-snooze` 18, `gcp-hub-restart` 22, `heal-hub-deploy` 14,
  `github-app-key-put-rotate` 21, `gcp-compute-lb-cleanup` 22,
  `gcp-delete-service-account` 26, `gcp-purge-wsdoc-prefix` 20. `shellcheck -S warning`
  on the 10 moved files: 0 lines. The lanes still run all of it.
- **P4, for the panel:** the plan read the other box's briefs and worktrees as its box
  user, read only. Say if that is more than a planner should do.
- **The panel's rulings on v0.2 (a-304, verdict 613938a9), as the holder's note e202f514
  lets them stand:** `lane-map.sh --check` exit 4 on the 30 row paths stays unproven
  until R3 runs before each row's spawn, and that check is the holder's at each row;
  the read-only reading in P4 is fine; holding `gcp-002` and `export-dns` for round 28
  is right.

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| every site of r52-05, r52-06, r52-10 | the brief; still in lanes or not started | head of this plan, section 2 |
| 6 plain-move header files; 2 that lack an `@example` | round full; **input for round 28** | section 2 |
| the 9 `(required)` header files | a behaviour change: bug-round input | section 2 |
| `useCardMove`, `useCardMessageActions`, `useCardTopicActions` `WIDE` | lanes c-246, c-259 | section 2 |
| `send`, `sendLive`, `liveReader`, `sessionMethods`, `perfFeedPair` | owned by c-023, c-262 | section 2 |
| `useCardSwipe`, `useCardSwipeFlags`, `useCardTouchLift`, `useCardEdit` `WIDE` | they edit `MessageCard.vue`; **input for round 28** | section 2 |
| `spl_desk_pick` (80) | queued `c002-bug-desk-reply-stub-rc0` | section 2 |
| `do_provision_firebase_dns` (169) | byte-identical port pin: dropped | section 2 |
| `spl_fleet_role_tick`, `_spawn_worktree`, `do_spl_agent_identity_restore` | fleet-critical | section 2 |
| `keyexec` (5), `keydesk` (3) | free now, round full; **input for round 28** | section 2 |
| `keyd`, `lockkey`, `hubclient.go` | queued bugs name them | section 2 |
| every floor raise, `go-coverage-floor.txt` | r52-06's file; **input for round 28**, with rows 06-10's own | section 2 |
| this round's `WIDE` lines | r52-10's file; **input for round 28** | section 1 |
| 33 other `< 75%` Go functions | round full, or one-line entry points | section 2 |
| Go `longFuncs`, `wideFuncs`, `store`, `hub`, `auth`, `gcal`, `github`, `repodocs`, `blob`, `cmd/spool`, `vendorkey`, `marketing`, `payments` | as rounds 22-26 | section 2 |
| WUI raw text, shellcheck WARNING baseline, gosec, semgrep | as rounds 22-26 | section 2 |

## 7. Counts

| metric | n |
|---|---|
| rows | 10 (refactor 5, test 5; iac 2, wui 3, Go 5) |
| vendor | claude 10 |
| kind | simple_coding 5, tests 5 |
| batches | batch 1: 9 rows at once; batch 2: row 02 |
| pins added | 10 (rows 03, 04: 3 each; row 05: 4) |
| header `[missing]` lines | 38 -> 28 after row 02 |
| WUI `WIDE` functions at 6 parameters | 3 fewer; their lines go in round 28 |
| Go functions taken | 14 at 60.0-74.1 |
| measured on | `0b2f05cb1`, n=1 per command unless stated |

## 8. Changes

- v0.1: first draft (c-265): 10 rows, slug `r53`, measured on `0b2f05cb1`.
- v0.2: the holder's panel seat and R7 ruling (note d15dfe65) in sections 1 and 5. No row changed.
- v0.3: a-304's FAIL on `547383cca` (verdict 613938a9) folded. **W1:** row 02 adds
  `heal-hub-deploy` and `github-app-key-put-rotate`; rows 01, 02 carry the R9 line and
  bold their source readers. The bold set is the editor's read and differs from the
  verdict's: bold `action-header-tags` and `parse-metadata-nofork` (both as it said),
  `gcp-hub-restart` (`:142-143`, as it said), and `gcp-compute-lb-list` (`:140-141`,
  added). Not bold: `adhoc-harvest-gcp-actions` (`:71` sources the site, its `:138` reads
  `gcp-backup-env`), `gcp-alert-snooze` (`:83` sources only). Dropped: `gcp-misc-actions`,
  `gcp-temp-sdk-config`, `gcp-exit-status-checks`, `return-not-exit-gcp`: R2's grep does
  not list them for any of the 10 sites, and no test holds the moved comment line.
  **W2:** row 05 gets four pins, slug `r53-05-wui-pin-alert-steps-object`. **N1:** section
  5. **N2:** row 08. P1 and P3 rewritten, the rulings added, section 7 updated.

## 9. Consensus

Both seats sign this sha (rulebook 3.2). Neither has yet.

- Editor seat: c-265 (claude): drafted v0.1, v0.2, v0.3. **Not signed.**
- Panel reviewer seat: a-304 (agy): FAIL on `547383cca`; v0.3 waits for its delta. **Not signed.**
