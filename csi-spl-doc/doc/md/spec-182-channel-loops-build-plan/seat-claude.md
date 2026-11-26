# Spec 182 channel loops build plan - panel seat claude (c-938)

Seat: `c-938` (`claude`, placement `c002-s182-cl-build-claude-panel-seat`,
ask `3343e159`), cross-vendor to the `agy` planner `a-934` (rulebook 2.7.2,
3.2). A doc review of the PLAN only; no row code read for correctness.

## Verdict on v0.1

**FAIL** on `6ae5fe136a961e3e8eb54a0b1460a9a4f2a86972`
(`review/c002-s182-cl-build-planner`, plan
`csi-spl-doc/doc/md/spec-182-channel-loops-build-plan.md`, 655 lines, one
commit on base `6b216a31990109235fbb11f3537c64e423b13b5c`).

The plan is sound in structure: all six rows, R1 batches, R3 ordering, vendors
and the C1 gate files of the plan's N1 check out. It fails on three fixable
defects (W1-W3): a done test names a Go test that does not exist, a
same-vendor R7 path is written without the authority the rulebook requires,
and several line cites do not point at the symbol named. Fold them into v1.0
and this seat signs.

Read: the plan at the sha above; spec 182 v0.10 section 9 at `a1b1984fd`;
`csi-spl-doc/doc/md/rounds-rulebook.md` sections 2, 3, 5 (origin/master);
`csi-spl-doc/doc/md/spec-187-build-plan.md` (origin/master, form and waiver
text); the briefs `c002-s187-s1.md`, `c002-s187-s2.md`, `c002-s187-s12a.md`,
`c002-s196-t1-topic-tags-store.md` in the dispatch briefs dir.

## Checks

### 1. Every 9.9 row is in the plan, with done test and red control

`git show a1b1984fd:csi-spl-doc/specs/182-topic-loop-prompt/spec.md | sed -n '1885,1930p'`
-> rows C1, C2a, C2b, C3, C4, C5. The plan has each in its action table
(plan `:170-175`) and a brief section 3.1-3.6, each with a "Done test (spec
182 9.9 ... verbatim)" and the spec's red controls (a)/(b) (C4, C5: one each,
as in the spec). Batch order `C1 -> C2a -> C2b || C3 -> C4 -> C5` equals 9.9.1.
**Pass**, with N1 (the "verbatim" label) and W1.

### 2. Site file:line on the plan's base and on origin/master

`git rev-parse origin/master` (fresh fetch, 05:35Z) ->
`6b216a31990109235fbb11f3537c64e423b13b5c` = the plan's base, so base and
master are the same tree: no drift to name. 142 cites from plan table 1.2 and
sections 3.1-3.6 were checked with `git show 6b216a319:<file> | sed -n <N>p`
(a loop over a site list, one line each, matching the named symbol where the
cite names one). All match except those in W3. The plan's own drift notes
hold: `config.go:402` is `TopicLoopCap`, `all.env.yaml:1548` / `:1564` /
`:1601` are `mistral_ui_allowed` / `mistral_review_allowed` /
`agent_split_by_kind`.

Baseline re-run on `6b216a319`:
- `git grep -n -iE "channel_loop|channel-loops|ChannelLoop" 6b216a319 -- csi-spl-api csi-spl-rdb csi-spl-wui | wc -l` -> `0`
- `git grep -n -i "loop" 6b216a319 -- csi-spl-wui/src/utils/sidebar-row-menu.mjs csi-spl-wui/src/components/SidebarRowMenu.vue | wc -l` -> `0`
- `git ls-tree --name-only 6b216a319 csi-spl-rdb/src/sql/postgres/spool-hub/ | tail -1` -> `0326_tax_documents.sql`
- `git ls-remote origin 'refs/rdb-claims/*' | tail -3` -> `0326`, `0327`, `0328`
- `git ls-tree --name-only 6b216a319 csi-spl-wui/i18n/locales/ | wc -l` -> `19`
- `git log --oneline a1b1984fd..6b216a319 -- csi-spl-doc/specs/182-topic-loop-prompt | wc -l` -> `0`

Test-column files: every one named in 3.1-3.5 exists on `6b216a319`
(`git cat-file -e`: 15 api and 16 wui test files OK, plus
`src/node/help/sync-help.mjs`), except `tests/e2e/channel-loops.test.mjs`,
which C4 creates. `TestRoundTripsPerRequest` (`roundtrips_perf_test.go:30`)
and `TestOpenAPIRoutes` (`openapi_routes_test.go:314`) exist;
`TestOpenAPIServe` does not (W1). `sync-help.mjs --check` exists
(`sync-help.mjs:105`); `SHIMS_CAP = 102` (`mjs-shims-exist.test.mjs:23`).

The plan's N1 (three extra C1 gate files) is right:
`change_stamp_test.go:45-65` compares the DB's `change_stamp` triggers with
`stampTables` one to one; `channel_copy_apply_postgres_test.go:465`
(`TestChannelCopyRulesMatchCatalogue`) errors on a Moved table with no
`cpCarried` entry; spec 9.7 puts a `change_stamp` trigger on both new tables.

### 3. R1 / R16: no shared file inside a batch; 9.9.1 order

Plan 2.2: batch 3 is the only two-row batch, `C2b` (Go `internal/hub/` only)
and `C3` (`csi-spl-wui/` only); no path in both. No file appears in two rows at
all (C1 store/rdb/channelmove, C2a `view.go` `server.go` `openapi.json`
`config.go` `hub.go` + new files, C2b `topic_loop*.go` `message_move.go`
`topic_merge.go` + new files, C3 wui src/i18n/unit, C4 one e2e file, C5 doc +
`public/help-md/`). Dependencies: C2a after C1, C2b after C1+C2a, C3 after C2a,
C4 after C3, C5 after C2b+C4 = 9.9.1. R16 30-minute placement stated per batch.
**Pass.**

### 4. R3: lane map

`bash .../lane-map.sh --check <row paths> --agent c-938`, run per row at
05:35:39Z-05:35:53Z: **rc 4 for every row** (C1, C2a, C2b, C3, C4, C5), no
exit 3; "no live lane lists <paths>, but 18 live lane(s) record no files". The
18 include `c-904` (`c-904-c002-s187-s1`) and `c-907`
(`c-907-c002-s196-t1-topic-tags-store`). The plan ran it at 05:24Z with 16.

Shared `api:internal/store/` files, from the briefs and
`spec-187-build-plan.md` 2.2 (origin/master):
- s187 **S1**: `store/channels.go`, `store/rls_test.go`,
  `channelmove/catalogue.go`, new `scheduled_task*.go`, `hub_settings.go`.
  Shares `rls_test.go` and `catalogue.go` with C1.
- s187 **S2**: `store/search_postgres.go`, `search/*`, `hub/search*.go`.
  No C1 file.
- s187 **S12a**: new `taskcron/cron.go`, `cron_test.go`. No C1 file.
- s196 **T1** (brief lines 16, 22): `store/topic_tags.go`,
  `channelmove/catalogue.go`, `rls_test.go` "in both T1 and S1", and per the
  plan `change_stamp_test.go`, `crosstenant_test.go`,
  `channel_copy_apply_postgres.go`.

The plan orders C1 after both `c-904` (S1) and `c-907` (T1) land and never
beside s196 T2 (`channels_postgres.go`), and names the later s187 S3/S6/S7/S11
and s196 T3 overlaps for C2a, s186 M10 for C2b, and s186 M8/M10/M11, s187 S8,
s196 T4-T6 for C3. Every shared file is ordered around. **Pass.**

### 5. Vendors

`git show 6b216a319:csi-spl-cnf/csi-spl/all.env.yaml | sed -n '1601,1606p'`
-> `specs_and_docs: { agy: 80, mistral: 15, claude: 5, backup: claude }`,
`tests: { claude: 70, ... backup: agy }`, `simple_coding: { claude: 44, agy: 41, ... }`,
`complex_coding: { claude: 90, agy: 10, backup: agy }`, `i18n: { agy: 100, backup: claude }`;
`:1548` `mistral_ui_allowed: false`, `:1564` `mistral_review_allowed: false`.
The plan puts no mistral on any coding, test or review row and excludes it from
C5 (`wui:public/help-md/`, plan `:175`, `:617-618`). R7 is cross-vendor on
every row (agy for claude rows, claude for agy rows). C3 names
`do_spl_lang_review_gct` (plan `:149`, `:562-565`, `:571`), and
`spl-lang-review-gct.func.sh:37` is its `ENV` param (default dev).
**Pass, except W2.**

### 6. Open decisions

Spec 9.1: "No question remains open". The plan asks the owner nothing (2.4)
and guesses no product choice. Its N3 (help file
`channels-and-direct-messages.md` over a new `loops.md`) picks between the two
options spec 9.9 C5 itself offers, so it is no owner question. The round size
claim holds: rulebook 5.1 binds "a bug-fix round and a refactoring round"
(rulebook `:291-293`), and 1.1's 10 stays the cap. **Pass.**

### 7. Distribution hygiene

`HYGIENE_TREE=<a throwaway shared clone checked out at 6ae5fe136> ./run -a do_check_dist_hygiene`
(csi-spl-iac) -> `INFO distribution-hygiene: clean over the tracked tree`,
rc 0. **Pass.**

## Defects

- **W1. C2a's done test names a test that does not exist** (plan `:446`,
  "`TestOpenAPIRoutes` and `TestOpenAPIServe` green").
  `git grep -n 'TestOpenAPIServe' 6b216a319` -> only
  `openapi_serve_test.go:32 TestOpenAPIServedToMember` and
  `:77 TestOpenAPIServeRouteNeedsItsOperation`; no func `TestOpenAPIServe`.
  A row lane cannot run it as named, and `go test -run TestOpenAPIServe`
  would match both by prefix without saying so. Name the two real tests (or
  the file `openapi_serve_test.go`, which the test column at `:452` already
  lists).
- **W2. A same-vendor R7 path with no authority cited** (plan `:161-164`: "the
  holder may place a `claude` same-vendor waiver seat only under the standing
  quota-outage waiver"). Rulebook 2.7.3 says a row never pushes without a
  cross-vendor PASS, and the plan says the rulebook wins (`:27`).
  `git grep -n -iE 'quota-outage waiver|same-vendor waiver|waiver seat' origin/master -- csi-spl-doc/doc/md/rounds-rulebook.md csi-spl-doc/doc/md/fleet-rules-index.md`
  -> nothing. The only written source found is `spec-187-build-plan.md:163-172`,
  the spec 187 round's own signed text, scoped to that round. Either cite the
  owner or holder decision that makes it standing, or drop the sentence and
  say that an agy outage holds the row (2.7.3: a replacement seat of an
  eligible vendor).
- **W3. Cites that do not point at the symbol they name** (the symbol is
  close by in each case; checked with `git show 6b216a319:<file> | sed -n <N>p`):
  - `:98` `channels_postgres.go` `ChannelKnown` `:78` -> `:78` is inside it;
    the func is `:77` (`grep -n ChannelKnown` -> `77:func (s *Postgres) ChannelKnown`).
    The spec has the same `:78`.
  - `:103` and `:289` `channel_copy_apply_postgres.go` `cpCheckRequest`
    `:87-91` -> the func is `:79`; `:87-91` is its loop over `req.Tables`.
    (`"topic_loops": false` `:75` on the same row is right; aligned
    whitespace.)
  - `:126` `TopicLoopsDialog.vue`: seven names against seven cites, out of
    step. `:102-105` is the `topic-loops-locked` line, not `defineProps`
    (`:123`); `load`, `save`, `toggle`, `remove` are funcs at `:158`,
    `:203`, `:216`, `:220`, not `:163` / `:212` / `:217` / `:221` (lines
    inside them); `onFrame` is `:224` and has no cite. `:546` repeats
    `:102-105`, `:123`.
  - `:143` the kind table "cnf `all.env.yaml:1601-1605`" also backs the
    `i18n` row (`:149`), which is `:1606`
    (`sed -n 1606p` -> `i18n: { agy: 100, backup: claude }`). Write
    `:1601-1606`.

## Notes

- **N1.** The "Done test (spec 182 9.9 Cx verbatim)" headings at `:369`,
  `:433`, `:566` and `:632` add items the spec does not have: C1
  `change_stamp_test.go`, `crosstenant_test.go`,
  `channel_copy_apply_postgres_test.go`; C2a the openapi tests (W1); C3
  `mjs-shims-exist`, `unused-exports`, `font-size`, `focus-tokens` and the
  e2e selection; C5 `sync-help.mjs --check`. The additions are right (C1's
  follow from the plan's N1); say "spec 182 9.9 Cx, plus ..." so a row lane
  can tell spec text from plan text.
- **N2.** `C3` names `wui:i18n/lang-review/<run-id>.json`, which the spec's
  9.9 C3 file list does not carry. It is right:
  `spl-lang-review-gct.func.sh:42` defaults the report dir to
  `csi-spl-wui/i18n/lang-review`, and the dir holds earlier reports.
- **N3.** The lane map is live state: 18 lanes recorded no files at 05:35Z
  (16 at the plan's 05:24Z). The plan already makes the placer re-run
  `--check` per row (`:240`). Nothing to change.
- **N4.** C4's red control mutates `SidebarRowMenu.vue`, a C3 file, as a
  "temporary local mutation, reverted before commit" (`:606-608`). That fits
  R1 since nothing is committed; a brief line asking the row to show
  `git diff --stat` empty for `src/` before its commit would make it
  auditable.

## Re-review of v0.2

**PASS** on `be601fc3d7572bbc8cd228b80b74376dfebce443` (one commit on
v0.1, `git diff --stat 6ae5fe136 be601fc3d` -> the plan only, +48/-34).

- W1 fixed: plan `:454-455` names `TestOpenAPIServedToMember`
  (`openapi_serve_test.go:32`) and `TestOpenAPIServeRouteNeedsItsOperation`
  (`:77`); both funcs are there on `6b216a319` (`sed -n '32p;77p'`).
- W2 fixed: the same-vendor waiver sentence is gone; plan `:165-168` states
  rulebook 2.7.3 (cross-vendor PASS only, a replacement seat on a 15-minute
  absence) and "this plan claims no same-vendor waiver".
- W3 fixed: `ChannelKnown` `:77`, `cpCheckRequest` `:79` (loop `:87-91`),
  `TopicLoopsDialog.vue` `:123` / `:158` / `:203` / `:216` / `:220` / `:224`
  / `:233` and `all.env.yaml:1601-1606`, each matching the line read for W3;
  `:163` is now cited as `listTopicLoops`, which it is.
- N1, N2, N4 folded; the one "verbatim" done-test heading left is C2b
  (`:500`), whose text is the spec's own.
- `git grep` for the v0.1 bad cites in v0.2 (`verbatim|TestOpenAPIServe|waiver|1601-1605|:212|:217|:221`)
  -> only the lines above, the v0.2 version row and "no cap waiver".
- origin/master is `f9521a941`; `git diff --name-only 6b216a319 origin/master`
  -> `refactor-round-05-plan.md`, `specs/150-topic-list-priority/spec.md`:
  no cited path changed, so check 2 stands.
- `HYGIENE_TREE=<clone at be601fc3d> ./run -a do_check_dist_hygiene` -> clean, rc 0.

No new defect. Checks 1 and 3-6 are unchanged from v0.1 (the diff touches no
row, batch, file list, vendor or question).

## Signature

**v1.0 signed: PASS** on `c05833b1c3a6f80a15078c930575f411a102abb3`
(`origin/master`, `git merge-base --is-ancestor c05833b1c origin/master` -> rc 0).

- v0.2 landed as `e6d3defb41c03eb5602d81be34823508dd875fd5`:
  `git diff be601fc3d e6d3defb4 -- <plan> | wc -l` -> `0` (the body this
  seat passed).
- v1.0 on top of it: `git diff e6d3defb4 c05833b1c -- <plan>` -> +10/-7,
  only the title, the status paragraph, the consensus table (this seat's
  PASS, holder c-003's GO LAND `7d3347f9`) and the v1.0 version row; no row,
  batch, file list, vendor, test or cite changed.

<!-- last-edit: 2026-11-26T06:10:00Z -->
