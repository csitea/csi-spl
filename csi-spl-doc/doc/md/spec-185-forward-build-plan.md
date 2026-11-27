# Spec 185 build round: Forward a Message Card, rows F1–F7 (plan)

Epic: SPL-2403  
Spec: csi-spl-doc/specs/185-message-forward (v0.3, `36d707972`, SPL-6035 done)  
Class: feature  
Kind: specs_and_docs  
Issue: SPL-6653 (this plan). Each row gets its own issue at placement (or via `do_spl_spec_import_issues` at signing).  
Topic: 82dc7a90-c7a1-41f0-bc16-80674c3fab40  
Discussion: `82dc7a90-c7a1-41f0-bc16-80674c3fab40` (`t1` #spool-hub-ui "forward a message card"; the dispatch holder owns it; the planner reports on task `dispatch-82dc7a90`).

Owner HUM-10 directives, by pointer:

- `t1` `82dc7a90`, form `1d2011df` answered 2026-11-20 12:06Z (`msg 61389b91`): Q1 **PLN** (plain copy, no header, no link), Q2 **LNK** (files shared with original; author's X removes from forwards too), Q3 **TOP** (existing topics only), Q4 **RDR** (any member who can read and may post), Q5 **ALL** (DM and members-only sources/targets allowed with a widening confirm), Q6 **AGT** (reaches agents like any post, @mention in forwarded text dispatches no work), Q7 **NO** (desktop menu only). Folded into spec 185 v0.3 (`36d707972`).
- `t1` `82dc7a90`, 2026-11-26 12:26Z: owner asked for status; the dispatch holder answered spec done, build not started, planner queued.
- Rules: [rounds-rulebook.md](rounds-rulebook.md) sections 1–3 (R1–R16) and 5, [developer-guide.md](developer-guide.md) sections 2 and 5.1, [lane-issue-and-docs.md](lane-issue-and-docs.md), and [fleet-rules-index.md](fleet-rules-index.md). The rulebook wins over this plan.

**What this round is.** Spec 185 v0.3 section 6 defines seven build rows (**F1–F7**) implementing message forwarding across RDB, Go hub/store, WUI, i18n, e2e, and docs/help. Seven rows sit within rulebook 1.1's hard cap of 10 rows. This plan re-measures every target site on one `origin/master` sha, orders F1–F7 into **3 batches of strictly disjoint files (R1)** (max 3 rows live per batch), enforces the CI migration roll gate (`20_hub-build-deploy.yml`) between F1 and F2, folds the fleet Google Cloud Translation language rule (owner msg `36b3ff7f`, SPL-6174 — marked as the fleet rule, not a spec change), maps live and queued R3 overlaps, states every row's R2 test column and C2 red control, and proposes one brief per row. This planner writes no code and edits no spec 185 file.

**Status: v1.0, revised after cross-vendor panel review (`c-715`, `claude`, FAIL W1–W5, N1–N6 on v0.1 `c2633a2c8`, seat file `review/c002-s185-fwd-build-claude-seat` `281a1bf4a`) and dispatch holder rulings (`c-002`, msg `cc456e7e`: H1 Option A accepted; N4 plan additions kept).** Editor: **a-548** (`agy`, main for `specs_and_docs`). Cross-vendor panel seat: **c-715** (`claude`; `mistral` sits on no review seat and `grok` is off fleet-wide). Nothing lands on `master` until `c-715`'s PASS line passes `do_spl_review_line_check` (rc 0) and the dispatch holder gives GO.

**One sha.** Every code/doc count and `file:line` below was measured on **`84f86ab8c`** (`84f86ab8c2f6daf774bef27ea34bbfb1aa1172fc`, `origin/master` fetched 2026-11-27T06:19Z, n = 1 per command; verified unchanged across all cited files on `31a526346` at 06:46Z). Spec 185 v0.3's own line numbers were measured on `62daca7aa` (2026-11-20); where a site moved or changed, section 1.2 gives both. Live state (`lane-map.sh`, `do_spl_spawn_queue`, `do_spl_lane_mix`, `do_spl_hub_agent_kinds`) carries its own UTC timestamp.

Paths are repo-relative: `api:` = `csi-spl-api/src/go/spool-hub-api/internal/`, `rdb:` = `csi-spl-rdb/src/sql/postgres/spool-hub/`, `wui:` = `csi-spl-wui/src/`, `doc:` = `csi-spl-doc/`. No personal name, OS user name, box shorthand, host, home path, or credential appears in this plan or any proposed brief.

---

## 1. Baseline (re-measured on `84f86ab8c`)

### 1.1 Nothing of spec 185 is built on `84f86ab8c`

- **Code, locales, and tests grep:**
  `git grep -n -E 'fwd_of|forward_of|ForwardOf|wuiForward|ForwardPicker|feed\.forward\.|forward_not_found|forward_no_topic' 84f86ab8c -- csi-spl-api/ csi-spl-rdb/ csi-spl-wui/src/ csi-spl-wui/i18n/ csi-spl-wui/tests/`
  -> **0 lines**.
- **New files check (`git cat-file -e 84f86ab8c:<path>`):**
  `api:hub/wui_forward.go`, `api:hub/wui_forward_test.go`, `wui:components/ForwardPickerDialog.vue`, `csi-spl-wui/tests/e2e/msg-forward.test.mjs` -> **all 4 MISSING**.
- **Prior round commits or review branches:**
  `git log origin/master --grep='s185-' --oneline` -> **0 lines**; `git ls-remote origin 'refs/heads/review/*s185*' 'refs/heads/review/*fwd*'` -> **0 lines** (at baseline fetch).
- **RDB head and claims:**
  `git ls-tree --name-only 84f86ab8c csi-spl-rdb/src/sql/postgres/spool-hub/ | tail -1` -> `0331_scheduled_tasks.sql`;
  `git ls-remote origin 'refs/rdb-claims/*' | awk '{print $2}' | sort | tail -1` -> `refs/rdb-claims/0331` (spec 185 wrote `0299 at v0.2`). F1 claims its exact number at build time with `cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next` (developer guide 2.8.3).
- **WUI locales and first-paint bundle budget:**
  `git ls-tree --name-only 84f86ab8c csi-spl-wui/i18n/locales/ | wc -l` -> **19** locale JSON files.
  `csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json`: `metrics.ci_initial_gzip_kb` = **151.9 KB** against ceiling **155.0 KB** (~3.1 KB box headroom). `ForwardPickerDialog.vue` MUST mount lazily (`<LazyForwardPickerDialog v-if="forwardOpen" />`), keeping it out of the initial JS chunks.

### 1.2 Sites re-measured on `84f86ab8c` (with drift from spec 185's `62daca7aa`)

| site | what lives there on `84f86ab8c` (vs spec 185 `62daca7aa`) | used by |
|---|---|---|
| `.github/workflows/20_hub-build-deploy.yml` | triggers on `csi-spl-rdb/src/sql/postgres/spool-hub/**` (`:59`), `wanted=(dev prd)` (`:245`), runs `ENV="$ENV" GCP_ACCOUNT="$DEPLOY_SA" DRY_RUN=0 ./csi-spl-orc/run -a do_spl_db_bootstrap` before rolling each env (`:722,:738`) | F1 -> F2 roll gate |
| `rdb:0321_messages_mc_id.sql` | exact template for `fwd_of`: `SET LOCAL lock_timeout = '5s';`, `ALTER TABLE messages ADD COLUMN IF NOT EXISTS ... uuid NULL;`, partial index `CREATE INDEX IF NOT EXISTS ... ON messages (tenant_id, ...) WHERE ... IS NOT NULL;` (also `0112_dm_ref_task.sql`, `0250_messages_copied_from.sql`) | F1 (reference) |
| `api:msg/msg.go` & `api:blob/blob.go` | `type Attachment struct` (`msg.go:90`), `type Message struct` (`msg.go:101`, moved from `:86,:97`); `blob.Key` (`blob.go:29`, unchanged) | F2, F4 (reference) |
| `api:hub/wui.go` | `type wuiIn struct` (`:120-148`, now carries `McID` `:147` from spec 186 M2 `13293131f`); `wuiSend` (`:584-658`, moved from `:571-643`): `:585` `wuiSendIDs` (`wuiIDs` + `wuiMulticast`), `:591` `wuiRecipient` (`:905-936`, moved from `:887-918`; `dispatchAgent` `:908` / `dispatch.go:51`), `:596` `wuiMessage` (`:716-732`, moved from `:700-716`; `wuiAttachments` `:950-967`), `:602` `wuiRoute` (`:759-818`, moved from `:741-800`; `wuiArchivedRefusal` `:764` / `topic_archived_input.go:48`; `isNoteToSelf` `:777`; `wuiMayPost` `:780` / `:876-891`; `topicReplyAgent` `:802` / `topic_reply.go:26`; `topicReplyPerson` `:808` / `topic_reply.go:93`), `:613` `admit` (`:1015-1038`, moved from `:997-1020`), `:628` `createPrioCut`, `:629` `wuiEnvelope` (`:980-1010`), `:634` `topicLoopBeforeAgent`, `:637` `withMcID(withNoteToSelf(ref, rt.noteToSelf), f.McID)`, `:638` `commitRow`, `:648` `wuiAck` (`:822-844`), `:656` `wuiAfterStore` (`:662-670`, moved from `:647-654`: `:664` `fallback`, `:666` `noteMentionNonMembers`, `:667` `noteMentionAgentsHumansOnly`, `:668` `createPrioSet`, `:669` `topicLoopHuman`). **DRIFT:** `ownerPrioWord` was retired by SPL-6622 (`3aa767190`); `createPrioCut`/`createPrioSet` (`topic_create_prio.go:69,:100`, SPL-6145) and `topicLoopHuman` (`topic_loop_fire.go:217`) / `topicLoopBeforeAgent` (`topic_loop_fire.go:227`, spec 182) landed. `fanoutWUI` at `:1042` (moved from `:1024`) | F2 |
| `api:hub/wui_multicast.go` | `wuiSendIDs` (`:319-325`), `wuiMulticast` (`:328-348`), `multicastTopic` (`:354-378`, refuses DM topics per spec 186 Q8 CHN), context helper `withMcID` / `mcIDOf` (`:381-395`) — landed by `13293131f`; exact pattern for `withFwdOf` / `fwdOfOf` | F2 (pattern + guard; see N3) |
| `api:hub/ws.go` | `missingFile` (`:969`, moved from `:945`), `unreadableFile` (`:1003`, moved from `:979`), `commitRow` (`:1038`), `commitRowTyped` (`:1061-1109`), `messageRow` (`:1113-1142`, sets `McID: mcIDOf(ctx)` at `:1140`) | F2 |
| `api:hub/privacy.go` & `demo_moderation.go` | `canReadChannel` (`:71-85`), `canReadMessage` (`:94-102`), `messageDoor` (`:107-124`), `canReadTopic` (`:129-139`), `topicDoor` (`:145-150`); `demo_moderation.go:156-168` `messageHidden` writes HTTP 404 (on WS, `wui_forward.go` reads `s.moderation(ctx, c.tenant, c.member)` + `v.drops(source.MsgID)` directly) | F2, F4 |
| `api:hub/openapi.json` | checked via `git grep -n -E 'wui-live-ws\|mc_id\|is_parent'`: `:26394` has only a prose WS summary and no `send` frame schema (`mc_id` is absent). **No `openapi.json` edit is needed in F2** | F2 (verified not needed) |
| `api:store/store.go`, `postgres.go`, `memory.go` | `Message` struct (`store.go:120-200`, `McID` at `:199`); `insertMessageSQL` (`postgres.go:439-448`, **25 columns** `$1..$25` with `mc_id` at `$25::uuid`), `insertMessageOnly` (`:459`, `flowInsertCTE(26)`), `insertMessageSent` (`:463`, `flowInsertCTE(27)`), `insertMessageSentDel` (`:467-470`, `$26::timestamptz`), `insertMessageArgs` (`:522-553`); `Memory.insertMessageLocked` (`memory.go:401-418`, copies `m` wholesale) | F2 |
| `api:store/message_edit.go` & `message_edit_postgres.go` | `EditableMessage` (`message_edit.go:37-73`, `CopiedFrom` at `:54`), `Memory.GetEditable` (`:120-144`), `Postgres.GetEditable` (`message_edit_postgres.go:15-72`, SELECT `:30-36`, Scan `:40-43`). Must expose `FwdOf` so F2 computes the root (`source.FwdOf` else `source.MsgID`) per spec §7.1.2 | F2 (and R3 vs `s196-t2`) |
| `api:hub/attachment_remove.go` & `api:store/file_detach.go` | `handleRemoveAttachment` (`attachment_remove.go:44-105`, log `:99-100`, 200 JSON `:101-104`), `detachEverywhere` (`:122-171`), `withoutFile` (`:175-200`), `fanoutEdited` (`edit.go:303`); `FileDetacher` (`file_detach.go:33-40`, implemented only by `*Memory` and `*Postgres`, `:43-44`), `FileCarriers` (`:49,:82`), `DetachFile` (`:66,:98`); `rest.go:314` `fileReadableBy`; `file_retention.go:15-21` | F4 |
| `wui:utils/msg-menu.mjs` | JSDoc (`:96-97`), `msgMenuItems` (`:102-162`, moved from `:85-138`): Copy link at `:122`, Hide from flow `:123`, Add to note `:124-125`, Export to PDF `:127-131` (note: SPL-6110 `7f4ab4743` put Export to PDF on phones too, while spec 185 Q7 keeps Forward desktop-only!). `locks` pattern (`:109-114`) | F3 |
| `wui:utils/uiIcons.ts` | **MISSING `'forward'` icon** (`git grep -n forward 84f86ab8c -- wui:utils/uiIcons.ts` -> 0 lines; `reply` is at `:248`). F3 must add `forward` to `UI_ICON_PATHS` so `UiIcon.vue` renders it and `UiIconName` typechecks | F3 (**plan addition**) |
| `wui:components/MessageMenu.vue` | props (`:36-86`), emits (`:88-115`, moved from `:80-104`, `'export-pdf'` `:111`), `topicItems` (`:155-179`, moved from `:131-153`), `choose` (`:184-213`, moved from `:158-184`, `export-pdf` `:205`) | F3 |
| `wui:components/MessageCard.vue` & `composables/useCardMove.ts` | `<LazyMessageMenu>` (`MessageCard.vue:437-491`, moved from `:426,:430-452`; `pdf` `:458`, `@export-pdf` `:487`), `<LazyMovePickerDialog>` (`:499-506`, moved from `:455-462`); `menuLocks` (`useCardMove.ts:55-57`, topic cards only today); `topicMenuLocks` (`utils/topic-menu.mjs:38-61`) | F3 |
| `wui:components/MovePickerDialog.vue` & `utils/move-apply.mjs` | `MovePickerDialog.vue` (`:1-201`, `load` `:111-123`, `pick` `:129-141`, `onListKey` `:150-165`); `moveChannelTargets` (`move-apply.mjs:16-25`), `moveTopicChoices` (`:328-345`) | F3 (pattern / reuse) |
| `wui:utils/spool-client.mjs`, `spool-client-mock.mjs`, `types/spool.ts`, `types/mjs-shims.d.ts` | `PUBLIC_CHANNELS` (`spool-client.mjs:296`, `lobby`, `alerts`, `feedback`, `public`, `issues`), `isPublicChannel` (`:303`), `listTopics` (`:615`, moved from `:603`, supports `{ dm: true }`), `sendMessage` (`:947-990`, moved from `:935-976`, already has `mc_id` `:963`); `mockSendMessage` (`spool-client-mock.mjs:122-171`, `mc_id` `:129,:168`); `SendFrame` (`types/spool.ts:166-180`); `mjs-shims.d.ts` (`sendMessage` `:165-177`, `msgMenuItems` `:883`, `TopicMenuLocks` `:950`) | F3 |
| `csi-spl-wui/tests/unit/msg-menu.test.mjs` & `tests/e2e/topic-menu-parity.test.mjs` | **Source/shape assertions that F3 must update:** `msg-menu.test.mjs:213` asserts the exact sorted key list of `en.feed.msg_menu`; `msg-menu.test.mjs:216-240` asserts non-en locales translate each menu key; `topic-menu-parity.test.mjs:105` asserts the exact desktop `SHAPE` array | F3 (R2) |
| `csi-spl-iac/src/bash/run/check-pre-push-lang-review.func.sh` & `csi-spl-orc/src/bash/run/spl-lang-review-gct.func.sh` | `wui-lang-review` enforces `Lang-review: gct <run id>` + committed `csi-spl-wui/i18n/lang-review/<run id>.json` on EVERY commit that adds/changes keys in `csi-spl-wui/i18n/locales/*.json` (SPL-6174, owner msg `36b3ff7f`) | F3, F5 |
| `doc:specs/005-spool-wui/spec.md` | FR-020 (`:302-362`), FR-022 (`:363-364` explicitly states `FR-021 is reserved for spec 185 F7`) | F7 |
| `doc:specs/003-spool-message-bus/contracts/wui-live-ws.md` | Section 4 `Send` (`:119-178`, `mc_id` at `:153-177`), section 8 `Errors` (`:291+`) | F7 |
| `doc:doc/help/message-actions-and-formatting.md` & `wui:public/help-md/message-actions-and-formatting.md` | Qto-backed (`bf244c37-39b0-40c1-9567-b8ec5fd94913`, `qto-docs.tsv:57`): section 2 "The Message Context Menu" (`:48-73`, table `:52-69`). `tests/unit/help-sync.test.mjs:20-22` (82 lines; control at `:36-48`) fails CI if `wui:public/help-md/message-actions-and-formatting.md` drifts from `doc/help/` (synced by `node src/node/help/sync-help.mjs`) | F7 |

---

## 2. Rows, kinds, vendors and R7

Live `LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix` and `ENV=prd ./run -a do_spl_hub_agent_kinds` (`csi-spl-orc`, read 2026-11-27T06:21Z–06:27Z):
`off [grok,qwen]`, `paused [agy until 2026-11-27T08:05:25Z (usage limit)]`.

| kind | live pick (06:21Z–06:27Z) | main / backup | notes |
|---|---|---|---|
| `simple_coding` | `claude` | `claude` / `agy` | never `mistral` (owner msg `91bf8278`) |
| `complex_coding` | `claude` | `claude` / `agy` | never `mistral` |
| `tests` | `claude` | `claude` / `agy` | never `mistral` |
| `i18n` | `claude` (while `agy` paused; `flag=needs_gct_lang_review`) | `agy` / `claude` | required check is Google Cloud Translation (`do_spl_lang_review_gct`); `agy` review optional (owner msg `36b3ff7f`). Never `mistral` (touches `csi-spl-wui/`, developer guide 5.1) |
| `specs_and_docs` | `claude` (while `agy` paused) | `agy` / `claude` | F7 updates `wui:public/help-md/message-actions-and-formatting.md` via `sync-help.mjs`, so never `mistral` (developer guide 5.1) |

The placer re-runs `do_spl_lane_mix` at placement time. **No row in this round may go to `mistral`** (coding, tests, reviews, WUI, and `public/help-md` are all disallowed for `mistral`).

**R7 review (rulebook 2.7.2 & claude waiver `1a7c70da`).** Every row carries a cross-vendor R7 reviewer before pushing to `master`: `agy` reviews `claude`-authored rows; `claude` reviews `agy`-authored rows. `mistral` sits on no review seat (`mistral_review_allowed: false`, owner msgs `65a45673` and `591ca574`); `grok` is off fleet-wide (`dc84300a`). Per claude waiver `1a7c70da`, a same-vendor `claude` backup waiver seat applies ONLY while `agy` is out of quota (and must cite `1a7c70da` in the row brief if used); once `agy` has quota, `agy` reviews every `claude`-authored row.

### 2.1 Action table

| row | what | kind | vendor | R7 reviewer | depends on | batch |
|---|---|---|---|---|---|---|
| F1 | rdb: `messages.fwd_of` nullable uuid column + partial index `messages_fwd_of` (`do_rdb_migration_next`), plus migration test; wf 20 runs `do_spl_db_bootstrap` on `dev` and `prd` | `simple_coding` | `claude` (backup `agy`; never `mistral`) | `agy` (`claude` if `agy` authored; waiver `1a7c70da` ONLY while `agy` out of quota) | none | 1 |
| F3 | WUI: desktop-only `Forward…` menu entry, `forward` icon, lazy `ForwardPickerDialog.vue` (channel + DM topics, widening confirm), `spool-client` + mock `forward_of`, 19 locales + `do_spl_lang_review_gct` | `complex_coding` | `claude` (never `mistral`) | `agy` (waiver `1a7c70da` ONLY while `agy` out of quota) | none (R3: wait until `lane-map.sh --check` is free on all F3 paths) | 1 |
| F7 | docs: `005-spool-wui/spec.md` (FR-021), `wui-live-ws.md` (§4 `forward_of` & refusals), Qto user help `bf244c37-39b0-40c1-9567-b8ec5fd94913` -> `do_spl_doctree_export_md` -> `sync-help.mjs` | `specs_and_docs` | `agy`, backup `claude` (never `mistral`) | `claude` if `agy` authored; `agy` (or `1a7c70da` waiver) if `claude` authored | none (codes against spec 185 §7.1) | 1 |
| F2 | hub + store: `wuiIn.ForwardOf`, `wuiForward` (source read/topic/hidden door, existing-topic target check, mention & body-note & `noteToSelf` skips, root `fwd_of` resolution, `mc_id` mutual exclusion), Postgres + Memory `fwd_of` insert & `GetEditable.FwdOf` | `complex_coding` | `claude` (never `mistral`) | `agy` (waiver `1a7c70da` ONLY while `agy` out of quota) | F1 wf 20 green on `dev` + `prd` (R3: check vs `s196-t2` on `message_edit*.go`; optional early coding in Batch 1 per §4.1) | 2 |
| F5 | i18n (fleet rule `36b3ff7f`, not a spec change): GCT report audit & optional `agy` natural-phrasing polish on the 18 non-en locale files for §7.1.4 keys (holder may close as satisfied by F3's clean GCT pass; see N1) | `i18n` | `agy`, backup `claude` (never `mistral`) | `claude` if `agy` authored; `agy` (or `1a7c70da` waiver) if `claude` authored | F3 landed | 2 |
| F6 | e2e: new `csi-spl-wui/tests/e2e/msg-forward.test.mjs` on generated mock bundle (plain forward across channels, DM/members-only widening confirm, phone sheet absence) + shard weight line if needed | `tests` | `claude` (never `mistral`) | `agy` (waiver `1a7c70da` ONLY while `agy` out of quota) | F3 landed | 2 |
| F4 | hub + store: `DELETE /v1/attachments/{file_id}` follows `fwd_of` in one hop (Q2, §7.1.6: chains M1 -> M2 -> M3, `fanoutEdited` to each forward's viewers, HTTP 200 hides unreadable forwards and excludes them from `kept`, blob drops when free) | `complex_coding` | `claude` (never `mistral`) | `agy` (waiver `1a7c70da` ONLY while `agy` out of quota) | F1, F2 landed | 3 |

Row count: **7** (within rulebook 1.1's hard cap of 10). Max rows live in any batch: **3** (Batches 1 and 2; or 4 if F2 starts coding early in Batch 1 per §4.1).

---

## 3. Files per row (re-measured on `84f86ab8c`), R2 test column, done test and red control

**Bold** file paths mark additions beyond spec 185 §6, each with its reason. In each row's R2 test column, **bold** marks a test that inspects source text or exact key/menu lists directly.

### F1 — rdb: `messages.fwd_of` and partial index

- **Files:**
  - `rdb:<NNNN>_messages_fwd_of.sql` (new; claim `<NNNN>` via `cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next` — never hardcode a number; head on `84f86ab8c` is `0331`). Model on `rdb:0321_messages_mc_id.sql`: `SET LOCAL lock_timeout = '5s';`, `ALTER TABLE messages ADD COLUMN IF NOT EXISTS fwd_of uuid NULL;`, `CREATE INDEX IF NOT EXISTS messages_fwd_of ON messages (tenant_id, fwd_of) WHERE fwd_of IS NOT NULL;`. No FK, no default, RLS unchanged.
  - **`api:store/messages_fwd_of_migrate_test.go`** (new; Go migration test asserting the column & partial index exist and idempotent re-apply succeeds, matching `*_migrate_test.go` in `api:store/`).
- **R2 test column:** `messages_fwd_of_migrate_test.go`, `api:store/rls_test.go`, `api:store/rls_failclosed_test.go`, `api:store/schema_head_test.go`, `lint-migration`, `PRE_PUSH_TIER=full ./run -a do_check_pre_push`.
- **Done test:** applies twice on a throwaway Postgres; `\d messages` lists `fwd_of uuid` nullable and partial index `messages_fwd_of (tenant_id, fwd_of) WHERE fwd_of IS NOT NULL`; wf 20 (`20_hub-build-deploy.yml`) runs `do_spl_db_bootstrap` and is green on both `dev` and `prd` (`do_check_deploy_lag`).
- **Red control (C2):** `messages_fwd_of_migrate_test.go` asserting `fwd_of` and `messages_fwd_of` fails RED before the SQL file exists, then passes GREEN with it; both outputs recorded in the commit body.

### F2 — hub + store: forward send and `fwd_of` persistence

- **Files:**
  - `api:hub/wui.go` (`wuiIn` `:120-148` add `ForwardOf`; `wuiSend` `:584-658` wire `wuiForward` before `wuiRecipient` `:591`, skip `createPrioCut` `:628` and `isNoteToSelf` `:777` for forwards, pass `withFwdOf` beside `withMcID` `:637`, skip `noteMentionNonMembers` `:666` / `noteMentionAgentsHumansOnly` `:667` / `createPrioSet` `:668` in `wuiAfterStore` `:662-670`).
  - `api:hub/wui_forward.go` (new) + `api:hub/wui_forward_test.go` (new).
  - **`api:hub/ws.go`** (`messageRow` `:1113-1142`: populate `FwdOf: fwdOfOf(ctx)` beside `McID: mcIDOf(ctx)` at `:1140` — needed so `commitRow` persists `fwd_of` in the same insert).
  - `api:store/store.go` (`Message` struct `:120-200`, add `FwdOf string` beside `McID` `:199`).
  - `api:store/postgres.go` (`insertMessageSQL` `:439-448` add `fwd_of` as `$26::uuid`, bump `insertMessageOnly` `:459` `flowInsertCTE(27)`, `insertMessageSent` `:463` `flowInsertCTE(28)`, `insertMessageSentDel` `:467-470` `$27::timestamptz`, `insertMessageArgs` `:522-553`).
  - `api:store/memory.go` (`insertMessageLocked` `:401-418` already copies `m`; verify resend conflict/idempotency).
  - **`api:store/message_edit.go`** (`EditableMessage` `:37-73` add `FwdOf string`; `Memory.GetEditable` `:120-144` populate `FwdOf: m.FwdOf`) and **`api:store/message_edit_postgres.go`** (`Postgres.GetEditable` `:15-72` SELECT `COALESCE(m.fwd_of::text, '')` and Scan `&m.FwdOf`) — required for §7.1.2 root resolution (`source.FwdOf` else `source.MsgID`).
  - Not touched: `api:hub/openapi.json` (verified on `84f86ab8c` to have no WS `send` frame schema), `api:hub/wui_multicast.go` (see N3).
- **R2 test column:** full package runs `go test ./internal/store/... ./internal/hub/...` (Memory and Postgres), explicitly covering `wui_forward_test.go`, `wui_test.go`, `wui_multicast_test.go`, `topic_reply_test.go`, `topic_archived_input_test.go`, `topic_create_prio_test.go`, `dm_reply_test.go`, `api:store/insert_sent_test.go`, `api:store/multicast_test.go`, and all 30 `GetEditable` test files — the 8 `api:store/` files (`channel_copy_apply_postgres_test.go`, `hours_post_test.go`, `message_kind_test.go`, `message_move_test.go`, `read_batch_test.go`, `returning_write_test.go`, `topic_merge_test.go`, `topic_promote_test.go`) and all 22 `api:hub/` files (`attach_rename_test.go`, `attachment_names_repair_test.go`, `attachment_remove_test.go`, `blocker_issue_test.go`, `box_edit_test.go`, `box_message_move_test.go`, `box_move_test.go`, `box_signed_row_test.go`, `channel_box_pins_route_test.go`, `channels_test.go`, `dm_ref_test.go`, `edit_test.go`, `message_kind_test.go`, `message_move_notice_test.go`, `message_move_test.go`, `notes_agent_test.go`, `thread_channel_test.go`, `thread_fanout_test.go`, `topic_archived_input_test.go`, `topic_create_prio_test.go`, `topic_loop_store_test.go`, `view_delta_test.go`) — plus **`api:cleancode/cleancode_test.go`** (75-line cap, 7-param cap, no `SELECT *`) and `PRE_PUSH_TIER=full ./run -a do_check_pre_push`.
- **Done test:** Go tests on Memory and Postgres prove:
  1. Forward of a readable card (opening card or reply, channel or DM, own or another author's/agent's) into an existing readable topic stores source's exact `body` + `files`, `from` = forwarder, `kind` = `note`, `fwd_of` = root `msg_id`; view row & `message` frame expose no `fwd_of` (Q1).
  2. Chained forward (M1 -> M2 -> M3) stores `fwd_of = M1` on both M2 and M3 (§7.1.2).
  3. Every refusal of §7.1.1: non-UUID `forward_of`, non-empty `body`, non-empty `files`, `is_parent: 1`, non-empty `to` or `to_box`, or `mc_id` set alongside `forward_of` (holder decision §5.1) -> `400 bad_json`; missing, unreadable, hidden (demo moderation), or box-locked source -> `404 forward_not_found` (identical token/detail); unknown or unreadable target `task_id` -> `404 forward_no_topic`; archived target / forbidden / unpaid / quota -> existing refusals unchanged; duplicate `msg_id` re-acks cleanly.
  4. An `@agent` mention in the forwarded body dispatches to no agent and writes no non-member / humans-only note; an `@forwarder` mention in the forwarded body does NOT trigger `noteToSelf` (holder decision §5.1); a trailing `prio:N` in the forwarded body is not stripped; a reply in a topic with an agent reaches that topic's agent as any reply (Q6).
- **Red control (C2):** (1) Forward by a member outside the source's private channel returns `forward_not_found` (fails RED when source door check is removed); (2) forward to an unknown `task_id` returns `forward_no_topic` (fails RED when target `canReadTopic` check is removed); (3) forward whose source body contains `@c-001` dispatches nothing (fails RED when `dispatchAgent` is not skipped).

### F3 — WUI: menu entry, picker, widening confirm, send, and GCT-checked locales

- **Files:**
  - `wui:utils/msg-menu.mjs` (`:96-97`, `:102-162`: desktop-only `{ id: 'forward', icon: 'forward', labelKey: 'feed.msg_menu.forward' }` right after Copy link `:122`, before `hide-flow`/`add-to-note`/`export-pdf`, gated with `locks.forward`).
  - **`wui:utils/uiIcons.ts`** (add `'forward'` glyph to `UI_ICON_PATHS` — missing on `84f86ab8c`).
  - `wui:components/MessageMenu.vue` (`:36-86` prop `forward?: boolean`, `:88-115` emit `'forward'`, `:155-179` pass `forward`, `:184-213` handle `id === 'forward'`).
  - `wui:components/MessageCard.vue` (`:437-491` pass `:forward` / merged `locks` and `@forward`; mount `<LazyForwardPickerDialog v-if="forwardOpen" />` beside `<LazyMovePickerDialog>` `:499-506`).
  - **`wui:utils/forward-picker.mjs`** (new pure helper: build/filter combined channel + DM topic rows excluding source topic, and `forwardWidensAudience(source, target)` using `isPublicChannel` from `spool-client.mjs:303` — enables fast Node unit tests and keeps Vue functions <= 75 lines).
  - `wui:components/ForwardPickerDialog.vue` (new, lazy: filtered list of existing channel topics via `moveChannelTargets` + `listTopics({ channel })` with `#channel` hint and DM topics via `listTopics({ dm: true })` with `<peer name>` hint, newest first, keyboard arrows/Enter/Esc, widening confirm with `feed.forward.widen`, sends frame of §7.1.1, stays open with error on refusal, toast `feed.forward.done` on success).
  - `wui:utils/spool-client.mjs` (`sendMessage` `:947-990`: when `forward_of` is set, send `{ task_id, forward_of, is_parent: 0, msg_id?, channel? }` with no `body`, `files`, `to`, `to_box`, `mc_id`).
  - `wui:utils/spool-client-mock.mjs` (`mockSendMessage` `:122-171`: implement `forward_of` contract, copying source `body`/`files`, enforcing `forward_not_found`/`forward_no_topic`/`bad_json`, storing root `fwd_of` off-row in `state.forwards`).
  - **`wui:types/spool.ts`** (`SendFrame` `:166-180`: add `forward_of?: string`) and **`wui:types/mjs-shims.d.ts`** (`sendMessage` `:165-177`, `msgMenuItems` `:883`, `TopicMenuLocks` `:950`).
  - `csi-spl-wui/i18n/locales/*.json` (all 19 files: §7.1.4 keys `feed.msg_menu.forward`, `feed.forward.title`, `feed.forward.widen`, `feed.forward.done`, `feed.forward.none`, plus any confirm/error keys needed so zero raw text ships) + **`csi-spl-wui/i18n/lang-review/<run id>.json`** (from `cd csi-spl-orc && ENV=dev ./run -a do_spl_lang_review_gct`, with `Lang-review: gct <run id>` in commit body — enforced by `wui-lang-review`).
  - **`csi-spl-wui/tests/unit/msg-menu.test.mjs`** (`:213` exact key list, `:216-240` locale loop, Forward desktop/touch cases) + new `csi-spl-wui/tests/unit/forward-picker.test.mjs` + **`csi-spl-wui/tests/e2e/topic-menu-parity.test.mjs`** (`:105` `SHAPE` array).
- **R2 test column:** **`msg-menu.test.mjs`**, `forward-picker.test.mjs`, **`i18n-parity.test.mjs`**, **`i18n-untranslated.test.mjs`**, **`i18n-no-raw-text.test.mjs`**, **`cleancode.test.mjs`**, **`pickers-mount-when-open.test.mjs`**, **`topic-menu.test.mjs`**, `msg-print.test.mjs`, `msg-shortcuts.test.mjs`, `font-size.test.mjs`, `focus-tokens.test.mjs`, `pnpm run typecheck`, `bundle-size.mjs` (<= 155.0 KB, `ForwardPickerDialog` absent from entry chunks), **`topic-menu-parity.test.mjs`**, `phone-card-menu.test.mjs`, `mobile-messages.test.mjs`, and every e2e selected by `cd csi-spl-iac && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e`.
- **Done test:** `msg-menu.test.mjs` proves Forward sits right after Copy link on every desktop card, obeys `locks.forward`, and is absent on `touch: true`; `forward-picker.test.mjs` proves channel + DM rows, source topic exclusion, filtering, and every widening-confirm case (DM -> channel/other DM widens; DM -> same peer DM does not; members-only -> other channel/public/DM widens; members-only -> same channel does not; public -> anything never widens); `pnpm run typecheck`, i18n gates, GCT `wui-lang-review`, `bundle-size.mjs`, and mapped e2e green.
- **Red control (C2):** drop `forward` from `msgMenuItems` -> `msg-menu.test.mjs` fails RED; list `forward` when `touch: true` -> touch assertion fails RED; bypass widening check for DM -> public -> `forward-picker.test.mjs` fails RED.

### F4 — hub + store: attachment X follows forwards (Q2)

- **Files:**
  - `api:hub/attachment_remove.go` (`handleRemoveAttachment` `:44-105`, `detachEverywhere` `:122-171`).
  - `api:store/file_detach.go` (or new `api:store/forward_detach.go`): add one-hop lookup `FileForwards(ctx, tenantID, rootMsgID string, now time.Time) ([]string, error)` (`SELECT msg_id::text FROM messages WHERE tenant_id = $1 AND fwd_of = $2::uuid AND expires_at > $3 ORDER BY received_at, msg_id` on Postgres, walking `messages_fwd_of`; matching loop on Memory) on `FileDetacher` (only `*Memory` and `*Postgres` implement `FileDetacher`).
  - `api:hub/attachment_remove_test.go` (new cases on Memory and Postgres) + new **`api:store/file_detach_test.go`** (store unit test for `FileForwards` on Memory and Postgres; no store `file_detach` test exists today).
- **R2 test column:** `api:hub/attachment_remove_test.go`, `api:hub/author_only_test.go`, `api:hub/demo_test.go`, new `api:store/file_detach_test.go`, **`api:cleancode/cleancode_test.go`**, `PRE_PUSH_TIER=full ./run -a do_check_pre_push`.
- **Done test:** source author's `DELETE /v1/attachments/{file_id}` removes the file from the source and from every forward of it, chains included (M1 -> M2 -> M3: both M2 and M3 store `fwd_of = M1`, both lose the file, both re-sign if signed, both emit `fanoutEdited` to their viewers); HTTP 200 `removed` and `messages` list only rows the caller passes `canReadMessage` on, and `kept` counts only readable carriers that still hold the file (neither double-counting readable forwards nor counting unreadable forwards); the blob is deleted once no carrier remains.
- **Red control (C2):** (1) a forward of a DIFFERENT card carrying the same `file_id` keeps the file (fails RED if `fwd_of` filter is dropped); (2) a forward in a DM the source author is not an end of IS detached and fanned out to DM viewers, but absent from HTTP 200 `removed`/`messages` and `kept` (fails RED if `canReadMessage` filter on 200 is removed or unreadable forwards are skipped).

### F5 — i18n: GCT audit & optional `agy` polish (18 non-en locales)

- **Fleet rule note (owner msg `36b3ff7f`, SPL-6174 — rule, not a spec 185 change):** Google Cloud Translation (`cd csi-spl-orc && ENV=dev ./run -a do_spl_lang_review_gct`) replaced `agy` as the required language check; `agy` review is optional. Because pre-push part `wui-lang-review` enforces GCT on F3's commit itself, F3 already runs `do_spl_lang_review_gct` before landing. F5 stays in the plan as the optional `agy` natural-phrasing pass & GCT audit over the 18 non-en locale files for §7.1.4's keys (`feed.msg_menu.forward`, `feed.forward.*`). See Note N1.
- **Files:** the 18 non-en files under `csi-spl-wui/i18n/locales/*.json` (keys of §7.1.4 only) + fresh GCT report `csi-spl-wui/i18n/lang-review/<run id>.json`.
- **R2 test column:** **`i18n-parity.test.mjs`**, **`i18n-untranslated.test.mjs`**, **`msg-menu.test.mjs`**, `do_check_pre_push_lang_review` (`wui-lang-review`).
- **Done test:** `do_spl_lang_review_gct` passes with zero `placeholder` failures and all `differs` reviewed/folded; `Lang-review: gct <run id>` in commit body; i18n gates green.
- **Red control (C2):** `i18n-untranslated.test.mjs` fails RED if a non-en key is left identical to English; `do_check_pre_push_lang_review` fails RED if a placeholder differs or the GCT report does not match committed text.

### F6 — e2e: `msg-forward.test.mjs`

- **Files:**
  - `csi-spl-wui/tests/e2e/msg-forward.test.mjs` (new).
  - **`csi-spl-wui/src/node/test/e2e-shard-weights.txt`** (add one measured weight line for `tests/e2e/msg-forward.test.mjs` if `tests/unit/e2e-shard-pack.test.mjs` requires it to stay within shard balance).
- **R2 test column:** `msg-forward.test.mjs` (against `pnpm generate` mock bundle), `phone-card-menu.test.mjs`, `topic-menu-parity.test.mjs`, `tests/unit/e2e-shard-pack.test.mjs`, `tests/unit/e2e-runner-coverage.test.mjs`.
- **Done test:** on the generated bundle, mock-served: (1) desktop: forward a reply (including another author's card) into a topic of another channel -> toast shows target topic -> card appears in target topic as a plain copy (no "Forwarded from" header, forwarder as author, kind `note`, body + files intact); (2) DM / members-only source -> different channel/DM asks to confirm (`feed.forward.widen`), Cancel sends nothing, Confirm sends; public channel source asks no confirm; (3) phone `390x844` long-press sheet does NOT list Forward (Q7).
- **Red control (C2):** removing the `forward` entry from `msgMenuItems` fails case (1) RED; bypassing the widening confirm fails case (2) RED.

### F7 — docs: FR-021, `wui-live-ws.md`, and user help

- **Files:**
  - `doc:specs/005-spool-wui/spec.md` (insert **FR-021** between FR-020 `:302-362` and FR-022 `:363-364`).
  - `doc:specs/003-spool-message-bus/contracts/wui-live-ws.md` (§4 `:119-178` right after `mc_id` `:153-177`: document `forward_of` and every refusal of spec 185 §7.1.1; §8 `:291+` if error tokens are tabulated there).
  - `doc:doc/help/message-actions-and-formatting.md` (edit Qto doc `bf244c37-39b0-40c1-9567-b8ec5fd94913` section 2 menu table `:52-69`, then export with `cd csi-spl-orc && ./run -a do_spl_doctree_export_md`) and **`wui:public/help-md/message-actions-and-formatting.md`** (regenerated via `cd csi-spl-wui && node src/node/help/sync-help.mjs`). Because it touches `csi-spl-wui/`, F7 **never goes to `mistral`** (developer guide 5.1).
- **R2 test column:** **`csi-spl-wui/tests/unit/help-sync.test.mjs`** (`:20-22` drift check, `:36-48` automated drift control), `node src/node/help/sync-help.mjs --check`, `QTO_DRIFT_LIVE=1 ... do_check_qto_doc_drift` (if live Qto reachable), `cd csi-spl-iac && ./run -a do_check_dist_hygiene`.
- **Done test:** `grep -oE 'forward_of|forward_not_found|forward_no_topic|bad_json|is_parent' csi-spl-doc/specs/003-spool-message-bus/contracts/wui-live-ws.md | sort -u | wc -l` -> **5** (every required token of §7.1.1 present; plus `grep -c 'FR-021' csi-spl-doc/specs/005-spool-wui/spec.md` -> **>= 1**); `node src/node/help/sync-help.mjs --check` rc 0; `node tests/unit/help-sync.test.mjs` rc 0.
- **Red control (C2):** (1) `tests/unit/help-sync.test.mjs:36-48` runs its own built-in control proving a drifted `public/help-md/` copy fails RED; (2) no automated test parses `wui-live-ws.md` (same as spec 186 M9), so the R7 reviewer re-runs the `grep -oE ... | sort -u | wc -l` command with one required §7.1.1 token removed and confirms the count drops from 5 to 4.

---

## 4. Batches (R1 disjoint, R16) and R3 overlap check

### 4.1 Batch ordering and disjoint file sets

| batch | rows | shared files / dependencies that order them | starts when |
|---|---|---|---|
| 1 | **F1, F3, F7** | **Disjoint:** F1 (`rdb:` + `api:store/messages_fwd_of_migrate_test.go`), F3 (`wui:` app + locales + menu/picker tests), F7 (`doc:specs/*`, `doc:doc/help/message-actions-and-formatting.md`, `wui:public/help-md/message-actions-and-formatting.md`). Zero shared files. | At GO. F3 also waits until `lane-map.sh --check` is free on all F3 paths (§4.2). |
| — | *Migration roll gate* | `.github/workflows/20_hub-build-deploy.yml:59,:245,:738` applies F1's migration via `do_spl_db_bootstrap` on `dev` and `prd` before rolling. | Before Batch 2's F2 lands (`do_check_deploy_lag` green on `dev` and `prd`). |
| 2 | **F2, F5, F6** | **Disjoint:** F2 (`api:hub/` + `api:store/`), F5 (18 non-en `csi-spl-wui/i18n/locales/*.json` + `i18n/lang-review/`, optional per N1), F6 (`csi-spl-wui/tests/e2e/msg-forward.test.mjs` + `e2e-shard-weights.txt`). Zero shared files. F2 lands only after F1 rolled on `dev` + `prd`; F5 and F6 start after F3 landed. *(Early-start option, N5: F2 is file-disjoint from Batch 1, so the holder may place F2 alongside Batch 1 to write code and Memory tests early, holding its final rebase, Postgres `PRE_PUSH_TIER=full`, and master push until F1 is served on `dev` and `prd`.)* | Within 30 min of prerequisites landing (R16). F2 checks R3 vs `s196-t2` (§4.2). |
| 3 | **F4** | After F1 and F2 (reads `fwd_of` written by F2, walks `messages_fwd_of` index from F1). | Within 30 min of F2 landing (R16). |

### 4.2 R3: live lanes and spawn queue (measured 2026-11-27T06:21Z–06:47Z)

**1. `lane-map.sh --check` on all existing target files** (hub+local, no `LOCAL-ONLY`; live worktrees shift every few minutes):
- At `06:22:15Z`: **exit 3** — `csi-spl-wui/src/utils/spool-client-mock.mjs` owned by `a-542` (SPL-6588 N1/N2 follow-up R7 reviewer); during panel review (`~06:45Z`) ownership shifted to `c-068` on `spool-client-mock.mjs`.
- At `06:47:02Z` (re-check for v1.0): **exit 3** — `spool-client-mock.mjs` is now free, and **`csi-spl-wui/i18n/locales/en.json`** is owned by **`c-314`** (`c-314-c002-4a2d2cc8-t083-hours-week-strip`, changed in its worktree).
- **Order:** **F3** waits until `lane-map.sh --check` is free across all F3 paths at placement time (R3). All F1, F2, F4, and F7 existing files reported free at `06:47Z`.

**2. Status of the specific overlaps named in the brief (re-measured on `84f86ab8c` / `31a526346`):**
- **Spec 186 (multicast):** M1 (`0321_messages_mc_id.sql`), **M2** (`13293131f`, `wui.go`, `wui_multicast.go`, `store/postgres.go`), M3 (`407c133d9`), M4 (`5fb0e1881`), M7 (`48a28abfc`), M11 (`320b0250e`, `54a39b0ce`), and M12 (`23ba79ba1`) have **all already landed** on `origin/master`. `api:hub/wui.go` and `api:store/postgres.go` are free of spec 186. Only **`s186-m8`** (`c002-s186-m8-i18n-locales`, ask `76fcd71c`, pos 37/77, age 10h, held) remains in the queue on the 18 non-en `csi-spl-wui/i18n/locales/*.json` files -> shares locales with **F3** and **F5**.
- **Spec 196 (topic tags):** **T1** (`9373f1d59`, `01f0d350c`, SPL-6562, `0328_topic_tags.sql`) has **already landed** on `origin/master`. However, queued **`c002-s196-t2-store-reads-multitag`** (ask `c7800fa0`, pos 22/77, age 12h) explicitly edits **`api:store/message_edit.go`** and **`api:store/message_edit_postgres.go`** (adding `TypedBy` to `GetEditable`) -> directly overlaps **F2** (which adds `FwdOf` to `GetEditable`). **Order:** F2 must not run concurrently with `s196-t2`; re-check `lane-map.sh --check` before placing F2.
- **Live WUI lanes (`msg-shortcuts`, `loops dialog`):** SPL-6590 (`9bcb5b352`, `Shift + L` / `Shift + C`) and SPL-6588 (`512971f47`, `31b85e2c0`, loops dialog) have **already landed** on `origin/master`.

**3. Other overlapping queued lanes (`do_spl_spawn_queue`, 2026-11-27T06:22:00Z, 77 queued, 0 placing):**
- **`c001-s179-b6-wui-pause-badge-i18n`** (ask `c264c908`, pos 42/77, age 2m, held after `s179-b2`): edits `MessageCard.vue`, `msg-menu.mjs`, `spool-client.mjs`, `spool-client-mock.mjs`, and all 19 `locales/*.json` -> overlaps **F3** and **F5**.
- **`c002-537d51e9-s169-t18-wui-move-menu-item`** (ask `56c441bd`, pos 6/77, age 14h) & **`c002-537d51e9-s169-t19-wui-move-dialog`** (ask `6a9a331c`, pos 8/77, age 14h, held after `s169-t17`): edit `locales/*.json` (sidebar menu, NOT `MessageCard.vue`/`msg-menu.mjs`), and `t19` edits `e2e-shard-weights.txt` -> overlaps **F3/F5** on locales and **F6** on shard weights.
- **`c002-s190-x2-i18n-media-locales-gct`** (ask `92bd46db`, pos 76/77, age 11h, held after `s190-w3`): edits `locales/*.json` -> overlaps **F3/F5**.
- *(Our own cross-vendor panel seat `c-715` was placed from ask `646c3169` and is live, doc-only.)*
- **Standing R3 guard:** because the queue moves continuously, the placer MUST re-run `lane-map.sh --check <row paths>` immediately before placing each batch and never place F3/F5 concurrently with `c-314`, `s179-b6`, `s186-m8`, `s169-t18/t19`, or `s190-x2`, nor F2 concurrently with `s196-t2`.

---

## 5. Holder decisions and technical notes

### 5.1 Decisions ruled by the dispatch holder (`c-002`, msg `cc456e7e`)

- **H1 (F3 — menu disabled state before opening the picker) -> Option A accepted** (unless panel objects on v1.0): Spec 185 §4 step 1 states *"A viewer with no topic to post in sees it disabled with the reason (the `locks` pattern, `msg-menu.mjs:49-53`)"*, and §7.1.4 defines `feed.forward.none` ("No topic you can post in"). `MessageCard.vue` knows `access.can('notes.send')` and `channel.channels`, not whether channels/DMs hold another existing topic until the picker runs `listTopics`. Under **Option A**, Forward is disabled on the menu with `locks.forward = 'feed.forward.none'` when `notes.send` is absent OR the viewer has neither a postable channel (`moveChannelTargets(channel.channels, '')` empty) nor any known DM peer; otherwise Forward is enabled and the picker shows `feed.forward.none` in its empty state if `listTopics` returns zero other topics.
- **H2 (F2 — plan addition beyond spec §7.1: `mc_id` + `forward_of` -> `400 bad_json`) -> Kept by holder (`c-002`, msg `cc456e7e`):** Spec 186 M2 (`13293131f`) landed `wuiIn.McID` (`wui.go:147`) after spec 185 v0.3. A frame carrying both `forward_of` and `mc_id` is refused `400 bad_json`.
- **H3 (F2 — plan addition beyond spec §7.1: skip `isNoteToSelf` on forwards) -> Kept by holder (`c-002`, msg `cc456e7e`):** `wuiRoute` (`wui.go:777`) runs `isNoteToSelf` over `m.Body`; skipping it for a forward ensures a forwarded card whose text mentions the forwarder never silences target routing/fan-out (honouring Q6).

### 5.2 Technical and operational notes (no owner form needed)

- **N1 (F3 & F5 — fleet language rule `36b3ff7f`, NOT a spec change).** Spec 185 §6 F5 says "agy's final review". Under owner msg `36b3ff7f` (SPL-6174), Google Cloud Translation (`cd csi-spl-orc && ENV=dev ./run -a do_spl_lang_review_gct`) is the required language check and `agy` review is optional; `wui-lang-review` (`check-pre-push-lang-review.func.sh`) enforces `Lang-review: gct <run id>` + committed report on F3's commit itself. Therefore F3 runs `do_spl_lang_review_gct` before landing, and F5 is retained as an optional `agy` natural-phrasing / GCT audit pass (which the holder may close as satisfied if F3's GCT pass leaves zero unaddressed `differs` rows).
- **N2 (F1 -> F2 — CI migration roll gate).** `.github/workflows/20_hub-build-deploy.yml:59,:245,:738` automatically applies `csi-spl-rdb/src/sql/postgres/spool-hub/**` via `do_spl_db_bootstrap` on `dev` and `prd`. F2 lands only after F1's wf 20 run is green on both `dev` and `prd` (`do_check_deploy_lag`), honouring spec 185 §7.1.2's deploy order without a manual DB mutation.
- **N3 (F2 — trunk changes in `wui.go` since `62daca7aa` & spec 186 §8.1 helper).**
  - `ownerPrioWord` (cited in spec 185 §7.1.3) was retired by SPL-6622 (`3aa767190`). `wuiSend` now runs `createPrioCut` (`:628`) / `createPrioSet` (`:668`, SPL-6145); both are skipped for a forward (and `opensTopic` is already false for an existing topic).
  - `topicLoopBeforeAgent` (`topic_loop_fire.go:227`, called at `wui.go:634`) and `topicLoopHuman` (`topic_loop_fire.go:217`, called at `wui.go:669`, spec 182) run as for any human reply in the target topic (Q6: "reaches them like any post").
  - **Spec 186 §8.1 target-topic helper:** `multicastTopic` (`api:hub/wui_multicast.go:354-378`) already landed, and refuses DM topics (spec 186 Q8 CHN — checks only non-empty `a.Channels`). Spec 185 Q5 ALLOWS DM topics as forward targets, so F2 does NOT reuse `multicastTopic` (leaving `wui_multicast.go` untouched); instead `wui_forward.go` calls `s.canReadTopic(ctx, c.tenant, task, c.member)` (`privacy.go:129-139`), which already applies `TopicAccess` + `topicLockHidden` + both DM ends and channels via `topicDoor` (`:145-150`), and returns `404 forward_no_topic` when `!found || !ok`.
  - Hidden-message check on WS: `demo_moderation.go:156` `messageHidden` writes HTTP 404; `wui_forward.go` calls `s.moderation(ctx, c.tenant, c.member)` + `v.drops(source.MsgID)` and returns `404 forward_not_found`.
- **N4 (F3 — icon, widening predicate, and extra helper i18n keys).**
  - `wui:utils/uiIcons.ts` has no `'forward'` glyph; F3 adds it.
  - Widening predicate (§4 step 3): public channels (`PUBLIC_CHANNELS` at `spool-client.mjs:296`, checked by `isPublicChannel` at `:303`: `#lobby`, `#alerts`, `#feedback`, `#public`, and `issues`) NEVER trigger the confirm. A members-only channel triggers the confirm when the target is a different channel (public or members-only) or any DM (NOT another topic in the same members-only channel). A DM triggers the confirm when the target is any channel or a DM with a different peer (NOT another topic with the same DM peer).
  - In addition to §7.1.4's 5 keys, F3 adds translated keys for the widening confirm button and refusal messages (`feed.forward.confirm`, `feed.forward.error_not_found`, `feed.forward.error_no_topic`, `feed.forward.error`) so `i18n-no-raw-text.test.mjs` stays green (developer guide 2.7.1), all covered by the same GCT run.
  - Because `msg-menu.test.mjs` asserts `msgMenuItems()` with no `forward` opt returns `['open', 'copy']`, `forward` is an opt-in boolean flag on `msgMenuItems` (like `pdf`), passed by `MessageCard.vue` on every card.
- **N5 (F4 — deduplicating readable forwards in `kept`).** In `attachment_remove.go:122-171`, pass 1 over `FileCarriers` may see a readable forward (e.g. in a public channel) and count it in `res.readable` while skipping it because `!isAuthor`. When pass 2 follows `fwd_of` and detaches that forward, it must NOT be double-counted in `res.readable` and must NOT remain in `kept`. Unreadable forwards detached in pass 2 emit `fanoutEdited` to their viewers, are logged in the server log (`:99-100`), and are excluded from `res.readable`, `removed`, `messages`, and `kept` (§7.1.6).
- **N6 (F7 — Qto source + `sync-help.mjs`).** `doc/help/message-actions-and-formatting.md` is Qto-backed (`bf244c37-39b0-40c1-9567-b8ec5fd94913`) and mirrored to `wui:public/help-md/message-actions-and-formatting.md`. Editing Qto -> `do_spl_doctree_export_md` -> `sync-help.mjs` keeps both `do_check_qto_doc_drift` and `help-sync.test.mjs` green, and disqualifies `mistral` (developer guide 5.1).

---

## 6. Proposed row briefs

Every row brief carries the common header and standing rules:
- `Epic: SPL-2403`
- `Spec: csi-spl-doc/specs/185-message-forward`
- `Class: feature`
- `Topic: 82dc7a90-c7a1-41f0-bc16-80674c3fab40` (context only: never post in the owner topic)
- Its `Kind:` and `R7` reviewer from section 2.1, its own `Issue:` filed at placement, and its plan table row verbatim (R4).
- "Plan on `origin/master` at work time; re-measure every cited `file:line` first."
- Standing Never list: no prd mutations, no package installs, no keys/secrets, PUBLIC repo hygiene (`do_check_dist_hygiene`), commit as the repo `CLAUDE.md` identity, no AI trailers, explicit pathspecs, release note trailers on every commit, `do_spl_push_master` after cross-vendor R7 PASS, no force-push.
- Commit subject form: `<type>(s185-f<N>-<slug>, SPL-<key>): ... (spec 185 F<N>)`, review branch `review/s185-f<N>-<slug>`.

### 6.1 F1 — rdb: `messages.fwd_of` column and partial index

- **Kind:** `simple_coding`. **Batch:** 1. **Vendor:** `claude` (backup `agy`; never `mistral`). **R7:** `agy` (or `claude` if `agy` authored; waiver `1a7c70da` ONLY while `agy` out of quota).
- **Spec refs:** spec 185 v0.3 §6 F1, §7.1.2.
- **Files (only these):** new `csi-spl-rdb/src/sql/postgres/spool-hub/<NNNN>_messages_fwd_of.sql` (number claimed via `cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next`), new `csi-spl-api/src/go/spool-hub-api/internal/store/messages_fwd_of_migrate_test.go`.
- **Must not touch:** any WUI file, any doc file, any non-test Go file (F2 writes the column).
- **Done & red control:** model on `0321_messages_mc_id.sql` (`SET LOCAL lock_timeout = '5s';`, nullable `fwd_of uuid`, partial index `messages_fwd_of (tenant_id, fwd_of) WHERE fwd_of IS NOT NULL`, no FK, no default, RLS unchanged). Migration test seen RED without the SQL file, GREEN with it (both outputs in commit body); applies twice on throwaway Postgres; `PRE_PUSH_TIER=full ./run -a do_check_pre_push`; verify wf 20 green on `dev` and `prd` (`do_check_deploy_lag`).

### 6.2 F2 — hub + store: forward send and `fwd_of` persistence

- **Kind:** `complex_coding`. **Batch:** 2 (lands ONLY after F1's wf 20 run is green on `dev` + `prd`; optional early start alongside Batch 1 per §4.1; R3 check vs `c002-s196-t2-store-reads-multitag` on `message_edit*.go`). **Vendor:** `claude` (never `mistral`). **R7:** `agy` (waiver `1a7c70da` ONLY while `agy` out of quota).
- **Spec refs:** spec 185 v0.3 §4 steps 4–9, §6 F2, §7.1.1–7.1.3; plan §5.1 H2/H3 & Note N3.
- **Files (only these):** `api:hub/wui.go`, new `api:hub/wui_forward.go`, new `api:hub/wui_forward_test.go`, `api:hub/ws.go` (`messageRow`), `api:store/store.go`, `api:store/postgres.go`, `api:store/memory.go`, `api:store/message_edit.go`, `api:store/message_edit_postgres.go`, store tests.
- **Must not touch:** `attachment_remove.go`, `file_detach.go` (F4), `wui_multicast.go` (N3), `openapi.json`, any WUI or doc file.
- **Done & red control:** implement `wuiIn.ForwardOf`, `wuiForward`, root `fwd_of` (`source.FwdOf` else `source.MsgID`), `withFwdOf`/`fwdOfOf`, source door (`canReadMessage` + `canReadTopic` + demo moderation hidden -> `404 forward_not_found`), target existing-topic door (`canReadTopic` -> `404 forward_no_topic`, see N3), `bad_json` on non-UUID / `body` / `files` / `to` / `to_box` / `is_parent: 1` / `mc_id` (H2), skip `dispatchAgent` / `isNoteToSelf` (H3) / `createPrioCut` / `noteMentionNonMembers` / `noteMentionAgentsHumansOnly` / `createPrioSet`, keep `fallback` & `topicLoop*` as normal reply. Full `go test ./internal/store/... ./internal/hub/...` (Memory + Postgres, covering all 30 `GetEditable` test files) and `PRE_PUSH_TIER=full`; all 3 red controls of §3 F2 recorded RED -> GREEN in commit body; `cleancode_test.go` green.

### 6.3 F3 — WUI: menu entry, picker, widening confirm, send, and GCT-checked locales

- **Kind:** `complex_coding`. **Batch:** 1 (R3: wait until `lane-map.sh --check` is free on all F3 paths, and check vs live `c-314` and queued `s179-b6`/`s186-m8`/`s169-t18..19`/`s190-x2`). **Vendor:** `claude` (never `mistral`). **R7:** `agy` (waiver `1a7c70da` ONLY while `agy` out of quota).
- **Spec refs:** spec 185 v0.3 §4 steps 1–4 & 9, §6 F3, §7.1.1, §7.1.4, §7.1.5; plan §5.1 H1 (Option A) + Notes N1, N4.
- **Files (only these):** `wui:utils/msg-menu.mjs`, `wui:utils/uiIcons.ts`, `wui:components/MessageMenu.vue`, `wui:components/MessageCard.vue`, new `wui:utils/forward-picker.mjs`, new `wui:components/ForwardPickerDialog.vue`, `wui:utils/spool-client.mjs`, `wui:utils/spool-client-mock.mjs`, `wui:types/spool.ts`, `wui:types/mjs-shims.d.ts`, all 19 `csi-spl-wui/i18n/locales/*.json`, new `csi-spl-wui/i18n/lang-review/<run>.json`, `csi-spl-wui/tests/unit/msg-menu.test.mjs`, new `csi-spl-wui/tests/unit/forward-picker.test.mjs`, `csi-spl-wui/tests/e2e/topic-menu-parity.test.mjs`.
- **Must not touch:** any Go, RDB, or `csi-spl-doc/` file; `wui:public/help-md/` (F7); `tests/e2e/msg-forward.test.mjs` (F6).
- **Done & red control:** desktop-only Forward entry right after Copy link (never on `touch`), H1 Option A `locks.forward`, lazy `<LazyForwardPickerDialog>` (bundle <= 155.0 KB, absent from entry chunks), combined channel + DM topic list excluding source topic, widening confirm per N4 (`PUBLIC_CHANNELS` includes `public`), sends §7.1.1 frame, stays open on error, toast on success. Run `cd csi-spl-orc && ENV=dev ./run -a do_spl_lang_review_gct`, fold references, re-run on final text, commit report + `Lang-review: gct <run id>`. Run all R2 tests of §3 F3, `pnpm run typecheck`, `bundle-size.mjs`, and mapped e2e (`do_check_pre_push_e2e`); record red controls in commit body; verify served on `dev` + `prd`.

### 6.4 F4 — hub + store: attachment X follows forwards (Q2)

- **Kind:** `complex_coding`. **Batch:** 3 (after F1 and F2 landed). **Vendor:** `claude` (never `mistral`). **R7:** `agy` (waiver `1a7c70da` ONLY while `agy` out of quota).
- **Spec refs:** spec 185 v0.3 §3.6, §6 F4, §7.1.6; plan Note N5.
- **Files (only these):** `api:hub/attachment_remove.go`, `api:hub/attachment_remove_test.go`, `api:store/file_detach.go` (or new `api:store/forward_detach.go`), new `api:store/file_detach_test.go`.
- **Must not touch:** `wui.go`, `wui_forward.go`, `postgres.go`, any WUI or doc file.
- **Done & red control:** one-hop `FileForwards` lookup walking `messages_fwd_of`; detach file from source + all forwards (chains M1 -> M2 -> M3), emit `fanoutEdited` to every detached forward's viewers, filter HTTP 200 `removed`/`messages` and `kept` strictly by `canReadMessage` with no double-counting (N5), drop blob when free. Memory + Postgres tests (`attachment_remove_test.go`, `author_only_test.go`, `demo_test.go`, `file_detach_test.go`), `PRE_PUSH_TIER=full`, both red controls of §3 F4 recorded RED -> GREEN in commit body; verify served on `dev` + `prd`.

### 6.5 F5 — i18n: GCT audit & optional `agy` polish (18 non-en locales)

- **Kind:** `i18n`. **Batch:** 2 (after F3 landed; optional per fleet rule `36b3ff7f` / Note N1 — holder may close as satisfied if F3's GCT pass left zero unaddressed `differs`). **Vendor:** `agy`, backup `claude` (never `mistral`). **R7:** `claude` if `agy` authored; `agy` (or `1a7c70da` waiver) if `claude` authored.
- **Spec refs:** spec 185 v0.3 §6 F5, §7.1.4; plan Note N1.
- **Files (only these):** the 18 non-en `csi-spl-wui/i18n/locales/*.json` files (spec 185 keys only) + fresh `csi-spl-wui/i18n/lang-review/<run>.json`.
- **Must not touch:** `en.json`, any `.vue`/`.mjs`/`.ts` file, `tests/e2e/msg-forward.test.mjs` (F6), any Go/doc file.
- **Done & red control:** review phrasing of all spec 185 keys across the 18 non-en locales, re-run `cd csi-spl-orc && ENV=dev ./run -a do_spl_lang_review_gct`, commit report + `Lang-review: gct <run id>`, verify `i18n-parity.test.mjs`, `i18n-untranslated.test.mjs`, `msg-menu.test.mjs`, and `do_check_pre_push_lang_review` green.

### 6.6 F6 — e2e: `msg-forward.test.mjs`

- **Kind:** `tests`. **Batch:** 2 (after F3 landed). **Vendor:** `claude` (never `mistral`). **R7:** `agy` (waiver `1a7c70da` ONLY while `agy` out of quota).
- **Spec refs:** spec 185 v0.3 §6 F6, §4, §7.1.4, §7.1.5.
- **Files (only these):** new `csi-spl-wui/tests/e2e/msg-forward.test.mjs`, and `csi-spl-wui/src/node/test/e2e-shard-weights.txt` (one measured weight line if `e2e-shard-pack.test.mjs` needs it).
- **Must not touch:** any `wui:src/` app file, any locale file (F5), any Go/doc file.
- **Done & red control:** on the generated mock bundle (`pnpm generate`), prove desktop cross-channel forward (plain copy, toast), DM/members-only widening confirm (Cancel vs Confirm; public source no confirm), and phone `390x844` sheet absence (Q7). Red controls: fails RED when Forward entry is absent or widening confirm is bypassed; `e2e-shard-pack.test.mjs` + `e2e-runner-coverage.test.mjs` green.

### 6.7 F7 — docs: FR-021, `wui-live-ws.md`, and user help

- **Kind:** `specs_and_docs`. **Batch:** 1. **Vendor:** `agy`, backup `claude` (never `mistral` — touches `wui:public/help-md/`). **R7:** `claude` if `agy` authored; `agy` (or `1a7c70da` waiver) if `claude` authored.
- **Spec refs:** spec 185 v0.3 §6 F7, §7.1; plan Note N6.
- **Files (only these):** `doc:specs/005-spool-wui/spec.md` (FR-021), `doc:specs/003-spool-message-bus/contracts/wui-live-ws.md` (§4 and §8), `doc:doc/help/message-actions-and-formatting.md` (edited in Qto `bf244c37-39b0-40c1-9567-b8ec5fd94913` -> `do_spl_doctree_export_md`), `wui:public/help-md/message-actions-and-formatting.md` (via `node src/node/help/sync-help.mjs`).
- **Must not touch:** any Go, RDB, locale, or WUI app file.
- **Done & red control:** FR-021 added cleanly (`grep -c 'FR-021' csi-spl-doc/specs/005-spool-wui/spec.md` >= 1); `grep -oE 'forward_of|forward_not_found|forward_no_topic|bad_json|is_parent' csi-spl-doc/specs/003-spool-message-bus/contracts/wui-live-ws.md | sort -u | wc -l` -> 5; `node src/node/help/sync-help.mjs --check`, `node tests/unit/help-sync.test.mjs` (`:20-22`, control `:36-48`), and `do_check_dist_hygiene` green. Red controls: `help-sync.test.mjs:36-48` proves stale `public/help-md/` fails RED; reviewer re-runs the `grep -oE` count with one §7.1.1 token removed and confirms 5 -> 4.

---

## 7. Panel record and signatures

| when (UTC) | who | what |
|---|---|---|
| 2026-11-27 06:34Z | a-548 (agy) | v0.1 on `review/c002-s185-fwd-build-planner`, `c2633a2c8`, measured on `84f86ab8c` |
| 2026-11-27 06:46Z | c-715 (claude) | **FAIL** on v0.1 `c2633a2c8` (msg `538ecc0b`, seat file `review/c002-s185-fwd-build-claude-seat` `281a1bf4a`): W1–W5, N1–N6 |
| 2026-11-27 06:46Z | c-002 (holder) | Rulings (msg `cc456e7e`): H1 Option A accepted; N4 plan additions (H2 `mc_id`+`forward_of`, H3 `isNoteToSelf` skip) kept; fold W1–W5 into v1.0 |
| 2026-11-27 | a-548 (agy) | v1.0 folds W1–W5, N1–N6, and holder rulings H1–H3; ready for `c-715` PASS and holder GO |

| seat | on | verdict |
|---|---|---|
| editor a-548 (agy) | v0.1, v1.0 | plan commits |
| cross-vendor panel seat c-715 (claude) | v0.1 `c2633a2c8` | **FAIL** W1–W5, N1–N6 (msg `538ecc0b`); awaiting v1.0 re-review |
| dispatch holder c-002 | H1–H3 (`cc456e7e`) | H1 A + H2/H3 kept; awaiting v1.0 PASS + GO |
