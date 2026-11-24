# Spec 186 build round - plan (9 rows, 4 batches)

Epic: SPL-2403  
Spec: csi-spl-doc/specs/186-multicast-prompt (v0.6)  
Class: feature  
Kind: specs_and_docs  
Issue: SPL-6371  
Topic: 032d8010-f150-4125-b1c2-70e503b1a450  
Discussion: 032d8010-f150-4125-b1c2-70e503b1a450 (t1 #spool-hub-ui; the dispatch holder owns it; the planner reports on task `dispatch-032d8010`)

Owner HUM-10, by pointer:

- t1 032d8010, poll e722e403 answer A (msg a158a4fd, 2026-11-24 07:05Z):
  "Plan it as a build round now: a planner orders M1-M9, a panel signs it,
  the rows are queued".
- Spec 186 v0.6 (msgs 5fdfff6c, 656b2576, 4b3833e7; addendum ae2caeb2),
  landed as `09a147c24` (SPL-6360).
- Poll d4dcbd90, msg fdc771fd: **A on all of H1-H5** (spec 186 section 11):
  H1 Monitoring -> Topics and each channel's topic list; H2 the selection
  survives channel changes within one workspace; H3 desktop boxes on
  hover/focus until the first tick; H4 phone "Select" in the card menu,
  then taps toggle; H5 the prompt is written in the Multicast dialog's own
  composer. Decided: not asked again here.
- Rules: [rounds-rulebook.md](rounds-rulebook.md) R1-R16, sections 3 and 5.
  The rulebook wins over this plan.

**What this round is.** Spec 186 v0.6 section 6 names nine build rows: M1,
M2, M3, M4, M7, M8, M9, M10, M11 (M5 and M6 were dropped with Q4 GTH and Q1
GRP; the numbers are not reused). "M1-M9" in the owner's poll is the v0.5
row list; on v0.6 the rows are these nine, M11 included and M10 the
multicast loop. This plan orders them into four batches of disjoint files
(R1), re-measures each row's sites on one sha, and proposes one brief per
row. It writes no code.

**Status: v1.0, signed.** Planner: c-053 (claude, the backup for
`specs_and_docs`: agy on its usage limit). Panel: m-069 (mistral) PASS on
v0.1 `bf6310284`, W none (section 4). The holder's GO on that sha; v0.1
landed as `5906e1fe2` (section 5). The owner answered Q1 and Q2 (2.4). The
holder queues the rows batch by batch (N1).

**One sha.** Every read is on **`dbd127c96`** (`origin/master` at
2026-11-24T10:00Z, after a fresh fetch), with `git show` / `git grep`, n=1
per command. `git merge-base --is-ancestor 09a147c24 dbd127c96` -> rc 0: the
v0.6 spec is in the tree planned on. Lane map, queue, vendor and box picks
are live state and carry their own time.

## 1. Baseline

### 1.1 Nothing of spec 186 is built

- `git grep -n -i -E 'multicast|mc_id|topic_select|topicSelect' dbd127c96 -- csi-spl-wui/src csi-spl-api/src csi-spl-cnf csi-spl-rdb | wc -l`
  -> **0**.
- The new files of rows M3, M11 and M7 do not exist:
  `git show dbd127c96:csi-spl-wui/src/<f>` fails for `stores/topicSelect.ts`,
  `composables/useTopicSelect.ts`, `components/TopicSelectBar.vue`,
  `components/MulticastDialog.vue`, `composables/useMulticastSend.ts`;
  `ls csi-spl-wui/tests/e2e/multicast*` -> no such file.
- `git show dbd127c96:csi-spl-doc/specs/003-spool-message-bus/contracts/wui-live-ws.md | grep -c -e mc_id -e multicast_no_topic -e topic_select_bad_pattern -e topic_select -e multicast_check -e multicast_none`
  -> **0** (M9's done test wants >= 6).

### 1.2 What the rows depend on outside this spec

- **rdb head.** `git ls-tree --name-only dbd127c96 csi-spl-rdb/src/sql/postgres/spool-hub/ | tail -1`
  -> `0319_workspace_cancellations.sql`; `git ls-remote origin 'refs/rdb-claims/*'`
  -> highest claim `0320` (not on master). M1 and M10 each take their number
  with `cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next` when they
  write the file (developer guide 2.8.3); today that is 0321 or later.
- **Spec 182 (loops), for M10.** L1 (`0301_topic_loops.sql`), L2 (the hub
  fire path, SPL-6032: `c075cdef6`, `9a1d7b3e2`) and L3 (the WUI dialog,
  SPL-6034: `7d554ce70`, `dccbb7391`) are on master:
  `git ls-tree -r --name-only dbd127c96 csi-spl-api/src/go/spool-hub-api/internal | grep topic_loop`
  -> `hub/topic_loop.go`, `hub/topic_loop_fire.go` (+ tests),
  `store/topic_loop.go`, `store/topic_loop_memory.go`,
  `store/topic_loop_postgres.go` (+ test); the WUI dialog is
  `csi-spl-wui/src/components/TopicLoopsDialog.vue` with
  `utils/topic-loops.mjs`. M10 waits only on this spec's M2, M3 and M4.
- **Spec 185 (forward).** `git grep -n fwd_of dbd127c96 -- csi-spl-api/src csi-spl-rdb`
  -> 0: not built. 186 8.1's shared "target topic must exist and be readable"
  helper is therefore M2's to write first (whichever lands first owns it).
- **Spec 153 (Set priority).** Its build planner is queued (ask 659a8e1e)
  and HELD after `c002-s186-v06-select-multicast` (queue read 10:06Z). Its
  Set priority row waits on M3 (186 8.3); this plan adds no 153 row.

### 1.3 Sites, re-measured on dbd127c96

`api:` = `csi-spl-api/src/go/spool-hub-api/internal/`, `wui:` =
`csi-spl-wui/src/`. Where the spec's line differs, both are given.

| site | spec says | on dbd127c96 |
|---|---|---|
| `api:hub/wui.go` `wuiSend` | `:571-643` | `:571` (same start) |
| `api:hub/wui.go` `wuiIDs` | `:831-852` | `:838` |
| `api:hub/wui.go` `wuiRoute` | `:741-800` | `:748` |
| `api:hub/wui.go` `wuiMayPost` | `:858-873` | `:865` |
| `api:hub/wui.go` `wuiRefuse` | `:659-672` | `:664` |
| `api:hub/wui.go` frame switch (`wuiFrame`) | `:359-381` | `:357` func, cases `:359` subscribe, `:368` send, `:381` token; called inline from the read loop at `:285` |
| `api:hub/wui.go` `SetReadLimit` | `:239` | `:239` |
| `api:hub/ws.go` `maxFrameBytes` | `:30` | `:30` (512 KiB) |
| `api:hub/ws.go` `messageQuota` | `:918-938` | `:926`; refusal `billing.TokenQuota` = `"quota"`, 429 (`api:billing/billing.go:28,34`) |
| `api:hub/ws.go` `commitRow` | `:1014` | `:1022` |
| `api:store/view.go` `TopicQuery` / `NoIssues` / `Parties` | `:35-66`, `:43-45`, `:78` | `:35`, `:45`, `:78` |
| `api:hub/view.go` `viewLimitMax`, `subjectMax`, `subject` | `:43,44,1094-1100` | `:43`, `:44`, `:1095` |
| `api:hub/box_lock_view.go` `keepTopics`, `hidesSeat` | `:313-333` | `:315`, `:81` |
| `api:hub/privacy.go` `canReadChannel`, `canReadTopic`, `topicDoor` | `:71`, `:129`, `:145` | same |
| `api:store/postgres.go` the messages INSERT | (not cited) | `:433`; memory `api:store/memory.go:391` `InsertMessage`; row type `api:store/store.go:120` `Message` |
| `wui:components/MessageCard.vue` long press, menu | `:778`, `:410-447` | `:778`, `:411`; swipe comment `:38` (1232 lines) |
| `wui:components/LiveFeed.vue` `<MessageCard` | `:83` | `:83` (520 lines) |
| `wui:components/FeedHeader.vue` list control | `:47` | `:47` (119 lines) |
| `wui:utils/issues-bulk.ts` helpers | `:20,34,47,56,68,80` | same; `BULK_PARALLEL` `:17` |
| `wui:pages/issues.vue` row box, bar | `:409-418`, `:12-31` | `:414`, `:16` |
| `wui:stores/channel.ts` `send`, `sendLive`, `waitForNetwork` | `:540`, `:640-696`, `:681,686` | `:551`, `:653`, `:696,701` (def `:717`) |
| `wui:utils/spool-client.mjs` `sendMessage`, `listTopics` | `:935-976` | `:941`, `:609` |
| `wui:pages/monitoring/topics/index.vue` | `:1-11` | 327 lines; `SheetHead` `:70`, `SheetPhoneBar` `:57` |
| `csi-spl-wui/i18n/locales/` | 19 files | `ls \| wc -l` -> 19 |
| spec 005 FRs | FR-020 last; FR-021 planned by 185 F7 | `grep -n '\*\*FR-02'` -> FR-020 only (`:302`): M9 writes **FR-022**, as the spec says |
| user help | (not cited) | written in `csi-spl-doc/doc/help/*.md`, copied to `wui:public/help-md/` by `node src/node/help/sync-help.mjs`; `tests/unit/help-sync.test.mjs` fails while they differ |

## 2. Rows

Kinds from spec 186 section 6's files; vendors from
`LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix` (csi-spl-orc, 10:05Z):

| kind | pick at 10:05Z | main / backup |
|---|---|---|
| `simple_coding` | agy | claude / agy |
| `complex_coding` | claude | claude / agy |
| `tests` | claude | claude / agy |
| `specs_and_docs` | agy | agy / claude |
| `i18n` | agy (the required check is Google Cloud Translation, `do_spl_lang_review_gct`; an agy review is optional) | agy |

agy is on its usage limit until 2026-11-30T21:31Z on one box (the brief's
addendum); the placer re-runs `do_spl_lane_mix` at placement and takes the
backup when the main cannot run. Every row that touches `csi-spl-wui/`
(M3, M7, M8, M9's help copy, M10, M11) never goes to mistral (developer
guide 5.1); no coding or test row goes to mistral (owner b61851fb msg
91bf8278).

**R7.** `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (10:05Z) -> a pick,
grok weekly 92% and 93% on the two boxes: the R7 reviewer of every
claude-authored row is a **grok** seat. If at placement the grok pick holds
on both boxes for the weekly limit, the claude waiver seat of c-001's
ruling 5fb1bdab applies, under its conditions; a load hold is not that
condition. An agy-authored row (M8, M9, M1 if placed on agy) takes a grok
or claude reviewer. No same-vendor line.

### 2.1 Action table

| row | what | kind | vendor (main) | R7 | depends on | batch |
|---|---|---|---|---|---|---|
| M1 | rdb: `messages.mc_id` + partial index | simple_coding | claude (pick agy; either) | grok (claude if agy) | none | 1 |
| M3 | WUI: the shared select phase | complex_coding | claude | grok | c-918 landed (2.3) | 1 |
| M4 | hub: `topic_select` + `multicast_check` frames | complex_coding | claude | grok | none | 1 |
| M9 | docs: 005 FR-022, wui-live-ws section 4, user help | specs_and_docs | agy, backup claude | grok or claude (cross to the author) | none (writes 7.1) | 1 |
| M2 | hub: send-time multicast checks + store `mc_id` | complex_coding | claude | grok | M1, M4 landed | 2 |
| M11 | WUI: the Multicast action and dialog | complex_coding | claude | grok | M3 landed | 2 |
| M7 | e2e on the mock | tests | claude | grok | M3, M4, M11 landed | 3 |
| M8 | i18n: the 18 non-en locales, language check | i18n | agy, backup claude | claude or grok | M3, M11 landed | 3 |
| M10 | rdb + hub + WUI: the multicast loop | complex_coding | claude | grok | M2, M3, M4, M8 landed (182 L1-L3 on master) | 4 |

### 2.2 Batches and disjoint files (R1, R16)

- **Batch 1: M1, M3, M4, M9.** Files: M1 one new rdb file; M3 `wui:`
  stores/composables/components of the select phase, `MessageCard.vue`,
  `LiveFeed.vue`, `MessageMenu.vue`, `FeedHeader.vue`,
  `pages/monitoring/topics/index.vue`, `utils/spool-client.mjs`,
  `utils/spool-client-mock.mjs`, `csi-spl-wui/i18n/locales/*.json`; M4
  `api:hub/wui.go`, new `api:hub/topic_select.go`, new
  `api:hub/wui_multicast.go`, their tests; M9 `csi-spl-doc/specs/005-spool-wui/spec.md`,
  `csi-spl-doc/specs/003-spool-message-bus/contracts/wui-live-ws.md`,
  `csi-spl-doc/doc/help/<page>.md` and its copy under
  `wui:public/help-md/`. No path in two rows.
- **Batch 2: M2, M11** (within 30 min of their prerequisites landing, R16).
  M2 shares `api:hub/wui.go` (the `wuiIn` struct and the send path) and
  `api:hub/wui_multicast.go` with M4, so it is serialised after M4; it needs
  M1's file for its postgres test. M11 shares `utils/spool-client.mjs`,
  `spool-client-mock.mjs`, the locales and the bar's action list with M3.
  M2 (api) and M11 (wui) share nothing.
- **Batch 3: M7, M8.** M7 one new e2e file; M8 the 18 non-en locale files.
  Disjoint.
- **Batch 4: M10.** It writes `TopicLoopsDialog.vue`, `utils/topic-loops.mjs`,
  `api:hub/topic_loop*.go`, `api:store/topic_loop*.go`, a new rdb file, and
  (2.4, N3) one en key plus its 18 drafts: after M8 has landed, so the
  locales are not in two live rows.

Why M4 before M2 and not the reverse: M2's postgres test needs M1's file
anyway, M4 needs nothing, and M4's `topic_select` is the hub half the WUI
rows' "verbatim" and quota tests mirror on the mock.

### 2.3 R3: live and queued lanes, read 10:05-10:10Z

`lane-map.sh --check <row paths> --agent c-053`, per row:

- **c-918** (`c-918-c002-s181-b11-signin-relay`, spec 181 B11): changed in
  its worktree all 19 `csi-spl-wui/i18n/locales/*.json`,
  `wui:utils/spool-client.mjs` (1 line) and files under
  `csi-spl-wui/tests/e2e/` (exit 3 on M3's paths). M3 is placed after
  c-918 lands, or its brief says to rebase onto it; M11, M7 and M8 come
  later anyway.
- **c-980** (`c-980-c002-spl5070-nuxt4-migration-r2`, SPL-5070, Nuxt 3 ->
  4): live across `csi-spl-wui/` incl. `tests/e2e/` (exit 3 on
  `tests/e2e/`); its branch renames no file
  (`git diff --name-status <merge-base> | grep -c ^R` -> 0). Every WUI row
  rebases onto it once it lands; a conflict with its landing stops the row
  and goes to the holder.
- **12 lanes with no files recorded** (exit 4 on every api, rdb and doc
  path): c-029, c-041, c-086, c-146, c-187, c-927, g-565 (rotation seats),
  c-678 (`s181-b9-keep-invoices-at-purge`), c-680
  (`bug-acfc125c-back-from-section-top-to-topic`: its brief names only the
  phone-Back files `useMobileStack.ts`, `mobile-stack.mjs`, `MobileBack.vue`,
  the section heads, and their tests), c-713, c-714, c-721 (three hand-placed release-tooling lanes).
  Not free by the rule: the placer re-runs `--check` per row at placement
  (R3), and asks any lane that still answers exit 4.
- **Queue** (`./run -a do_spl_spawn_queue`, 10:06Z, 10 rows): none names a
  file of this plan. The 153 build planner (ask 659a8e1e) is HELD after
  this spec's v0.6 lane and will plan Set priority on M3. The grok reviewer
  for SPL-6356 (c-680) and r96-02 (iac) are disjoint.

### 2.4 Rows needing a decision: decided

H1-H5 are decided (poll d4dcbd90). Q1 and Q2 are decided too: the owner
answered A on both (poll e486583e, t1 032d8010 msg 9b521d63), the first
reading below, which the briefs already take:

- **Q1: A** - "Keep it: it counts and ticks only my own workspace's
  topics".
- **Q2: A** - "Emptied, as on the issues list".

The two readings as the panel reviewed them:

- **Q1. "Select all N matching" on Monitoring -> Topics.** 7.1.6 defines
  "all N matching" for a channel page only (page through `listTopics`).
  Monitoring -> Topics lists rows of every workspace the reader may see,
  and only the own workspace's rows can be ticked (4.1). Reading: there,
  the page box and "all N matching" count and tick only the own
  workspace's rows the column filters keep. Alternative: no "all N
  matching" line on Monitoring -> Topics (the page box only). Spot: M3.
- **Q2. "Kept for the session": a reload.** 7.1.6 keeps the selection "for
  the browser session across channel pages". Reading: in memory only (a
  page reload empties it, as the issues list's selection is). Alternative:
  `sessionStorage`, so a reload in the same tab keeps it. Spot: M3
  (`stores/topicSelect.ts`).

Holder notes, not owner questions:

- **N1. Round size.** Rulebook 5.1's 2-3 rows is the bug / refactor
  cadence; this is a spec build of nine rows. The batches cap the live rows
  at four (batch 1). The holder may also queue batch by batch.
- **N2. The language step.** Spec 186 M8 says "agy's final review"; the
  repo rule since SPL-6174 (owner msg 36b3ff7f) is the Google Cloud
  Translation check `do_spl_lang_review_gct`, an agy review optional. M3,
  M11 and M10 add en keys with machine drafts; M8 runs the check over every
  new key and is placed on agy when agy can run, else claude.
- **N3. M10's switch label.** 7.1.4 lists no key for M10's "Send to several
  topics" switch in the loop dialog. M10 adds one (`topic_loops.multicast`,
  en + 18 drafts) and runs `do_spl_lang_review_gct` on it itself, since M8
  is already landed by then.
- **N4. One in flight per kind.** `wuiFrame` runs inline in the socket's
  read loop (`api:hub/wui.go:285`), so 7.1.2's "a newer frame of a kind
  cancels the running one" needs the two read-only handlers off that loop,
  with a per-connection cancel per kind. M4's brief says so; it is the
  spec's contract, not a new decision.

## 3. Proposed row briefs

Each brief carries: `Epic: SPL-2403`, `Spec: csi-spl-doc/specs/186-multicast-prompt`,
`Class: feature`, its `Kind:`, its row's line of spec 186 section 6
verbatim (R4), its R7 seat, "plan on origin/master at work time, re-measure
the cited lines", and the fleet's standing Never list (no prd writes, no
installs, no keys, no owner-topic post, PUBLIC repo hygiene, commit as the
repo's identity, explicit pathspecs, no force-push). Each row files its own
issue at placement and cites it in its subject, e.g.
`feat(api, SPL-<n>): ... (spec 186 M4)`.

### 3.1 M1 - rdb: `messages.mc_id`

- Kind `simple_coding`. Batch 1. R7 grok (claude if placed on agy).
- Files: one new `csi-spl-rdb/src/sql/postgres/spool-hub/<NNNN>_messages_mc_id.sql`,
  number from `DRY_RUN=0 ./run -a do_rdb_migration_next` (csi-spl-orc);
  the migration test that asserts the column.
- Content (7.1.3): `ALTER TABLE messages ADD COLUMN IF NOT EXISTS mc_id uuid NULL`;
  `CREATE INDEX IF NOT EXISTS messages_mc_id ON messages (tenant_id, mc_id) WHERE mc_id IS NOT NULL`;
  no FK, no default, RLS unchanged.
- Done: applies twice on a throwaway postgres; `\d messages` lists
  `mc_id uuid` nullable and the partial index; `PRE_PUSH_TIER=full`.
- Red control: a migration test asserting `mc_id` fails before the file
  exists.
- Not touched: any Go file (M2 writes the column).

### 3.2 M3 - WUI: the shared select phase

- Kind `complex_coding`. Batch 1, after c-918 lands (2.3). R7 grok. Never
  mistral (WUI).
- Files: spec 186 M3's list: new `wui:stores/topicSelect.ts`,
  `wui:composables/useTopicSelect.ts`, `wui:components/TopicSelectBar.vue`
  (lazy), `wui:components/TopicSelectPatterns.vue`; `MessageCard.vue`
  (1232 lines today: keep the 75-line function cap and the cleancode
  ratchets), `LiveFeed.vue`, `MessageMenu.vue`, `FeedHeader.vue`,
  `pages/monitoring/topics/index.vue`, `utils/spool-client.mjs` +
  `spool-client-mock.mjs` (`topicSelect`, the mock resolving `topic_select`
  in its own code for the tests), `csi-spl-wui/i18n/locales/*.json` (the
  `topic_select.*` keys of 7.1.4, en + machine drafts).
- Reuse, never a third copy: `utils/issues-bulk.ts` helpers (`toggleKey`,
  `rangeSelect`, `pageState`, `toggleAll`, `keepShown`, `runBulk`); the bar
  is drawn as `IssuesBulkBar.vue` is.
- Decided readings: H1 (channel topic list + Monitoring -> Topics), H2
  (survives channel changes), H3 (hover/focus boxes until the first tick),
  H4 ("Select" in the card menu), Q1 A (own workspace's rows only) and Q2 A
  (memory only, a reload empties it), section 2.4.
- Done and red control: spec 186 M3's cells verbatim (the "channel B" test,
  the filter-keeps test, the verbatim-patterns test, the 390 px menu /
  tap / swipe test, DM and `issues` cards without a box, another
  workspace's Monitoring row without a box, a registered test action
  shows); `pnpm run typecheck`; the i18n gates; `dock-buttons.test.mjs`
  and `touch-ui.test.mjs` green unchanged.
- Test column (R2), at least: `tests/unit/issues-bulk.test.mjs`,
  `msg-menu.test.mjs`, `topic-menu.test.mjs`, `feed-header.test.mjs`,
  `card-swipe-commit.test.mjs`, `card-swipe-flags.test.mjs`,
  `monitoring-topics.test.mjs`, `spool-client-mock-opener.test.mjs`,
  `unused-exports.test.mjs`, `cleancode.test.mjs`, and the e2e files
  `WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e` (csi-spl-iac)
  selects; the reviewer runs that selection (2.7.4).
- Not touched: `MessageComposer.vue`, `dock-buttons.test.mjs`,
  `touch-ui.test.mjs`, the three phone Attach e2e tests (S1).

### 3.3 M4 - hub: `topic_select` and `multicast_check`

- Kind `complex_coding`. Batch 1. R7 grok.
- Files: `api:hub/wui.go` (two cases in `wuiFrame`, `:357`; the new
  `wuiIn` fields `req_id`, `action`, `task_ids`, `patterns`), new
  `api:hub/topic_select.go` (`resolveTopicSelector`, shared by every bulk
  action) + `topic_select_test.go`, new `api:hub/wui_multicast.go`
  (`multicast_check` handler) + `wui_multicast_check_test.go`.
- Contract 7.1.2, with: paging `ViewTopics` (`Reader`, `NoIssues`, `DM`
  false) to the end at `viewLimitMax` 200; the box-lock filter on
  `store.TopicRow.Parties` with `lockViewFor(author).hidesSeat`, lobby
  exempt, before titles are read; `(?i)` + `MatchString` on `subject`;
  trimmed `*`; the action's permission (`multicast`: `notes.send`); the
  quota once for the whole count (`billing.TokenQuota` "quota", 429,
  detail = count and remaining). N4: run both handlers off the read loop
  with one cancel per kind per connection.
- Done and red control: spec 186 M4's cells verbatim (the 450-topic
  paging test, `(?i)`, `NoIssues`, box lock, permission, quota-once, trim;
  1200 targets with an unlimited quota all `ok`; neither frame stores).
  Go tests on postgres: `PRE_PUSH_TIER=full ./run -a do_check_pre_push`.
- Test column: `bash csi-spl-api/src/bash/tests/run-all-tests.sh`; every
  test naming `wuiFrame`, `wuiIn`, `keepTopics` or `ViewTopics`.
- Not touched: the send path (`wuiSend`, M2's), any store write.

### 3.4 M9 - docs

- Kind `specs_and_docs`. Batch 1. agy, backup claude; never mistral (its
  help copy is under `csi-spl-wui/`). R7 cross-vendor to the author.
- Files: `csi-spl-doc/specs/005-spool-wui/spec.md` (**FR-022**: the select
  phase and the multicast send; re-check FR-021 is still 185 F7's and
  unused), `csi-spl-doc/specs/003-spool-message-bus/contracts/wui-live-ws.md`
  section 4 (`mc_id` and its refusals; `topic_select` / `topic_selected`,
  `multicast_check` / `multicast_checked`), the user help for the topic
  lists in `csi-spl-doc/doc/help/` (the page that describes a channel's
  topic list; pick by `grep -l` and name it in the commit) and its copy by
  `node src/node/help/sync-help.mjs` (csi-spl-wui).
- Done: the spec's grep on `wui-live-ws.md` -> at least 6;
  `node src/node/help/sync-help.mjs --check` rc 0; `tests/unit/help-sync.test.mjs`.
- Red control: the reviewer re-runs the grep with one name removed and
  sees the count drop (none automatic, as the spec says).
- Language: the help pages are written in English in `doc/help`; if the
  row adds any WUI key, it runs `do_spl_lang_review_gct`.

### 3.5 M2 - hub: the send-time checks and the store

- Kind `complex_coding`. Batch 2: after M1 and M4 have landed. R7 grok.
- Files: `api:hub/wui.go` (`wuiIn.McID`, one `wuiMulticast` step after
  `wuiIDs`, `:838`), `api:hub/wui_multicast.go` (M4's file: the send-time
  checks beside `multicast_check`) + new `wui_multicast_test.go`,
  `api:store/store.go` (`Message.McID`, `:120`), `api:store/postgres.go`
  (the INSERT, `:433`), `api:store/memory.go` (`InsertMessage`, `:391`),
  and a `MulticastAuthor` read in both stores. No cnf key (R2 QTA).
- The existing-channel-topic check is the helper 8.1 names; spec 185 is
  not built (1.2), so M2 owns it.
- Done and red control: spec 186 M2's cells verbatim (N copies stored with
  one `mc_id`; Q5 routing; the 1200-copy no-cap test; the resend re-acks
  with the quota spent; quota + 2 stores 2 of 4; 402 on every copy; the
  members-only / DM middle target answers `multicast_no_topic` 404 with
  the unknown-task detail; a second author's `mc_id` is `bad_json`).
  `PRE_PUSH_TIER=full` (store change).
- Not touched: the two read-only frames' resolution (M4's).

### 3.6 M11 - WUI: the Multicast action

- Kind `complex_coding`. Batch 2: after M3 has landed. R7 grok. Never
  mistral.
- Files: new `wui:components/MulticastDialog.vue` (a full-screen sheet on
  a phone), new `wui:composables/useMulticastSend.ts`,
  `wui:stores/channel.ts` (`sendMulticast`: one `sendLive`, `:653`, per
  target), `utils/spool-client.mjs` + `spool-client-mock.mjs` (`mc_id` on
  `sendMessage`, `:941`; `multicastCheck`), the one line that registers
  `multicast` with M3's action list, the `multicast.*` keys of 7.1.4 (en +
  drafts).
- Decided: H5 (the dialog's own `MessageComposer` instance; the page
  composer and its draft untouched).
- Done and red control: spec 186 M11's cells verbatim (the check names
  exactly the selection; Send disabled while any target refuses; files
  uploaded once; N frames, one `mc_id`; the 2-of-5 socket-drop test with
  `waitForNetwork` and same-`msg_id` resend; Retry; dialog closes and the
  selection empties; page draft unchanged; older `req_id` dropped);
  `pnpm run typecheck`; i18n gates.
- Test column: every unit test importing `stores/channel` (e.g.
  `channel-feed`, `composer-files`, `await-reply`), and the e2e selection
  of `do_check_pre_push_e2e`.
- Not touched: `MessageComposer.vue` source, the dock row.

### 3.7 M7 - e2e

- Kind `tests`. Batch 3: after M3, M4 and M11. R7 grok. Never mistral.
- Files: new `csi-spl-wui/tests/e2e/multicast-prompt.test.mjs` only.
- Done: spec 186 M7's desktop and 390x844 flows on the generated bundle,
  mock-served (`BASE_URL=<bundle> pnpm run test:e2e`); the dock row still
  `dock-back,attach,send`.
- Red control: the test fails with the card box, the menu's "Select", the
  bar's Multicast button or Select by title removed (each shown RED, then
  GREEN, in the commit body).

### 3.8 M8 - i18n

- Kind `i18n`. Batch 3: after M3 and M11 have landed their en keys. agy,
  backup claude. R7 cross-vendor to the author.
- Files: the 18 non-en files under `csi-spl-wui/i18n/locales/`, the keys
  of 7.1.4 only.
- Done: `do_spl_lang_review_gct` over the new keys (N2) with its output in
  the commit body; `i18n-parity`, `i18n-untranslated`, `i18n-no-raw-text`
  green.
- Red control: `i18n-untranslated.test.mjs` (a value left equal to en
  raises the count and fails).

### 3.9 M10 - the multicast loop

- Kind `complex_coding`. Batch 4: after M2, M3, M4 (and M8, for the
  locales). R7 grok. Never mistral (it touches the WUI).
- Files: a new rdb file (`ALTER TABLE topic_loops ADD COLUMN IF NOT EXISTS targets jsonb NULL`,
  number from `do_rdb_migration_next`), `api:store/topic_loop.go`,
  `topic_loop_memory.go`, `topic_loop_postgres.go`, `api:hub/topic_loop.go`
  (`POST`/`PUT` accept `targets`; `topic_select_bad_pattern` at save),
  `api:hub/topic_loop_fire.go` (`resolveTopicSelector` per fire, the 7.1.2
  check for the whole set, UUIDv5 `mc_id` / `msg_id`), their tests;
  `wui:components/TopicLoopsDialog.vue` + `utils/topic-loops.mjs` (the
  switch, the current selection as ticks, M3's `TopicSelectPatterns.vue`
  reused), one en key + drafts (N3).
- Done and red control: spec 186 M10's cells verbatim (fire-time
  resolution, the archived target and the agentless target each make the
  whole fire send nothing, a refire is a no-op). `PRE_PUSH_TIER=full`.
- Test column: `topic_loop_test.go`, `topic_loop_fire_test.go`,
  `store/topic_loop_test.go`, `tests/unit/topic-loops.test.mjs`,
  `topic-menu.test.mjs`, `e2e/topic-menu-parity.test.mjs`.

## 4. Consensus

| seat | vendor | sha | verdict |
|---|---|---|---|
| m-069 | mistral | `bf6310284e2be07a4e803d41a5c368614a113f83` (v0.1) | PASS, W none (msgs e37fba9f, a35a56fd); `do_spl_review_line_check` rc 0 (holder; re-run by c-053 11:1xZ) |

Panel notes, folded:

- **N1 (drift, not a defect).** Since the plan's 10:05-10:10Z reads the
  exit-4 no-files lanes grew from 12 to 16, the spawn queue holds 7 rows
  (the spec 153 build planner first), and `BOX_PICK_KIND=grok` returns
  `hold` (grok weekly 95% / 94%). Each row re-reads lane map, queue and
  picks at its placement (2.3, R7).
- **N2 (deliberate).** Spec section 6 lets M1, M2, M3, M4, M9 start
  together; the plan puts M2 in batch 2 after M4 because both write
  `api:hub/wui.go` (R1). An added edge, none missing.

The holder c-002 sent GO on `bf6310284` (msg e391283f).

## 5. Versions

| version | what |
|---|---|
| v0.1 | first plan for the panel, on `dbd127c96`; reviewed as `bf6310284`, landed as `5906e1fe2` (origin/master had moved to `3314cc4e5`, so the GO'd commit was rebased onto it: same `git patch-id` 95d092ef, the plan file byte-identical) |
| v1.0 | records the m-069 PASS (N1, N2), the holder's GO, the owner's Q1 A and Q2 A as decisions, and the landed sha |
