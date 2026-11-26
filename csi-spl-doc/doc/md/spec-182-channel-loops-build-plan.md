# Spec 182 channel loops build round - plan v0.2 (6 rows, 5 batches)

Epic: SPL-2398  
Spec: csi-spl-doc/specs/182-topic-loop-prompt (v0.10)  
Class: feature  
Kind: specs_and_docs  
Issue: SPL-6563  
Topic: cbb1897b-4d35-44df-93c3-a2bbd2b6defa  
Discussion: cbb1897b-4d35-44df-93c3-a2bbd2b6defa (t1 "channel loops"; the dispatch holder owns it; the planner reports on task `dispatch-cbb1897b`)

Owner HUM-10, by pointer:

- t1 `cbb1897b`, 2026-11-24 15:49Z (msgs `1d74013c`, `3e75de18`, `3fb74ba3`):
  "add the loops feature on the channel level as well ... so that one could
  specifiy the similar kind of loops actions as they were defined on the topics
  level ... for each topic in the channel".
- t1 `cbb1897b`, poll `13fb1941`, msg `facaaf33` (2026-11-25 07:37Z): **CL1 A**
  (both topic and channel loops fire), **CL2 B** (no per-topic opt-out at
  first), **CL3 B** (follows the workspace's archive-topics permission),
  **CL4 B** (every open topic, newest first, at most 60 runs/h per loop).
- Spec 182 v0.10, landed as `a1b1984fd` (SPL-6474, R7 `c-388` PASS): section 9
  closes CL1-CL4 and freezes the binding contracts (9.8) and six build rows
  (9.9).
- Dispatch holder post `289f2584` (2026-11-26): "A planner orders C1 to C5 into
  batches and a reviewer signs the plan, then the rows are queued".
- Rules: [rounds-rulebook.md](rounds-rulebook.md) R1-R16, sections 3 and 5.
  The rulebook wins over this plan.

**What this round is.** Spec 182 section 9.9 names six build rows: `C1`, `C2a`,
`C2b`, `C3`, `C4`, `C5`. This plan re-measures every row's sites on one
`origin/master` sha, adds three store/test gate files proved required for `C1`
by the live test suite (2.4 N1), orders the six rows into five batches of
strictly disjoint files (R1), checks live and queued R3 overlaps across specs
186, 187 and 196, names each row's kind, vendor and cross-vendor R7 reviewer,
and proposes one brief per row. It writes no code.

**Status: v0.2, revised for panel re-review (answers `c-938` FAIL W1-W3 and N1-N4 on v0.1 `6ae5fe136`).** Planner: `a-934` (`agy`, main for
`specs_and_docs`). Panel: one cross-vendor seat, **`c-938`** (`claude`,
placement `c002-s182-cl-build-claude-panel-seat`, ask `3343e159`). Not yet
signed; no row queued before panel PASS (`do_spl_review_line_check` rc 0) and
the dispatch holder's GO.

**One sha.** Every code and spec read is on
**`6b216a31990109235fbb11f3537c64e423b13b5c`** (`6b216a319`, `origin/master` at
2026-11-26T05:22Z after a fresh fetch; at v0.2 `origin/master` is `f9521a941`,
with `git diff --name-only 6b216a319..f9521a941` touching only
`refactor-round-05-plan.md` and `specs/150-topic-list-priority/spec.md`, zero
cited paths changed), with `git show` / `git grep`, n=1 per
command. `git merge-base --is-ancestor a1b1984fd 6b216a319` -> rc 0: spec 182
v0.10 is in the tree planned on, and no commit after it touches the spec folder
(`git log --oneline a1b1984fd..6b216a319 -- csi-spl-doc/specs/182-topic-loop-prompt`
-> empty). Lane map, queue and vendor picks are live state and carry their own
UTC timestamp.

## 1. Baseline

### 1.1 Nothing of channel loops is built (topic loops L1-L3 are live)

- `git grep -n -iE "channel_loop|channel-loops|ChannelLoop" 6b216a319 -- csi-spl-api csi-spl-rdb csi-spl-wui | wc -l`
  -> **0**.
- `git grep -n -i "loop" 6b216a319 -- csi-spl-wui/src/utils/sidebar-row-menu.mjs csi-spl-wui/src/components/SidebarRowMenu.vue | wc -l`
  -> **0**.
- **Topic loops prerequisite (already on master):** `0301_topic_loops.sql`,
  `api:internal/store/topic_loop*.go`, `api:internal/hub/topic_loop*.go`,
  `wui:src/components/TopicLoopsDialog.vue`, `wui:src/utils/topic-loops.mjs`,
  and the SPL-6309 DM-mirror skip (`topicLoopPromptMark` = `"Loop prompt (background; "`
  at `api:internal/hub/topic_loop_fire.go:70`). All five hub event hooks
  (`wui.go:632`, `wui.go:669`, `ws.go:740`, `message_kind.go:132`,
  `issues.go:449,471`), the ticker start (`server.go:764`), and topic archive /
  delete cleanup (`topic_archive.go:217,268`) already delegate through
  `topic_loop.go` and `topic_loop_fire.go`, so `C2b` does not need to touch
  `wui.go`, `ws.go`, `message_kind.go`, `issues.go`, `topic_archive.go`, or
  `server.go`.
- **rdb head and claims.**
  `git ls-tree --name-only 6b216a319 csi-spl-rdb/src/sql/postgres/spool-hub/ | tail -1`
  -> `0326_tax_documents.sql` (was `0323_fleet_ask_queue_order.sql` when spec
  182 v0.10 was measured on `c9dd02117`).
  `git ls-remote origin 'refs/rdb-claims/*' | tail -2` -> `refs/rdb-claims/0327`
  and `refs/rdb-claims/0328`. `C1` claims its own migration number via
  `cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next` at build time
  (0329 or later; developer guide 2.8.3).
- **WUI locales and help.**
  `git ls-tree --name-only 6b216a319 csi-spl-wui/i18n/locales/ | wc -l` -> **19**
  files. User help lives under `csi-spl-doc/doc/help/` (synced to
  `csi-spl-wui/public/help-md/` by `node src/node/help/sync-help.mjs`;
  `tests/unit/help-sync.test.mjs` enforces parity). `channels-and-direct-messages.md`
  is listed in `csi-spl-doc/doc/help/index.md:67`.

### 1.2 Sites, re-measured on `6b216a319`

`api:` = `csi-spl-api/src/go/spool-hub-api/`, `rdb:` =
`csi-spl-rdb/src/sql/postgres/spool-hub/`, `wui:` = `csi-spl-wui/`. Where a
line moved since spec 182 v0.10 (`c9dd02117`), both are shown.

| site | spec 182 v0.10 (`c9dd02117`) | on `6b216a319` | row |
|---|---|---|---|
| `rdb:0093_tenant_topic_archive_policy.sql` `topic_archive_policy` CHECK | `:20-24` | `:21-23` (`ADD COLUMN` `:21`, `CHECK` `:23`) | ref |
| `rdb:0144_topic_heads.sql` `topic_head_parts_channel` index | `:100` | `:100` | C1 ref |
| `rdb:0301_topic_loops.sql` `topic_loops`, RLS, `change_stamp` | `:53-86`, `:95-108` | `:53`, `:95-107` | C1 ref |
| `api:internal/store/channels.go` `ChannelIssues`, `ChannelTasks`, `ChannelHidden` | `:56` | `:34`, `:40`, `:56` | C1/C2a ref |
| `api:internal/store/channels_postgres.go` `ChannelKnown`, `DeleteChannel`, `ArchiveChannel`, `UnarchiveChannel` | `:78` (`ChannelIssues` check), `:93`, `:136`, `:177` | `:77` (`ChannelKnown`; `:78` `ChannelIssues` line), `:93`, `:136`, `:177` | C1 |
| `api:internal/store/channels_memory.go` `DeleteChannel`, `ArchiveChannel`, `UnarchiveChannel` | (by name) | `:144`, `:215`, `:260` | C1 |
| `api:internal/store/rls_test.go` `rlsTables`, `"topic_loops"`, `TestRLSCoversEveryTenantTable` | `:92` | `:68`, `:92` (`rlsTables` ends `:100`), `:105` | C1 |
| `api:internal/store/change_stamp_test.go` `stampTables`, `"topic_loops"`, `TestChangeStampTriggerCatalogue` | (not in 9.9 table; 2.4 N1) | `:22`, `:27`, `:45` | C1 |
| `api:internal/store/crosstenant_test.go` `seedTenantAll` `topic_loops` block | (not in 9.9 table; 2.4 N1) | `:426-430` | C1 |
| `api:internal/store/channel_copy_apply_postgres.go` `cpCarried`, `"topic_loops": false`, `cpCheckRequest` | (not in 9.9 table; 2.4 N1) | `:59`, `:75`, `:79` (`cpCheckRequest`; loop `:87-91`) | C1 |
| `api:internal/channelmove/catalogue.go` `Catalogue`, `"topic_loops"` | `:61`, `:93` | `:61`, `:64`, `:93` | C1 |
| `api:internal/store/tenant_settings.go` `ArchivePolicy*`, `EffectiveArchivePolicy` | `:46-73` | `:47-70` | C2a ref |
| `api:internal/hub/demo.go` `archivePolicy` | `:76-81` | `:76-81` | C2a ref |
| `api:internal/hub/topic_archive.go` `mayArchiveByPolicy`, `handleArchiveTopic`, `handleDeleteTopic` | `:172-182`, `:197`, `:248` | `:172`, `:197`, `:248` (`dropTopicLoops` `:217`, `:268`) | C2a/C2b ref |
| `api:internal/hub/channel_members.go` `channelOwner`, `channelDoor`, `handleDeleteChannel`, `handleArchiveChannel`, `handleUnarchiveChannel`, `retireChannel` | `:103`, `:123`, `:562`, `:572`, `:583`, `:663` | `:103`, `:123` (`rbac.ChannelsEdit` `:132`), `:562`, `:572`, `:583`, `:663` | C2a ref |
| `api:internal/hub/privacy.go` `channelMemberSet` | (by name) | `:181` | C2a ref |
| `api:internal/hub/wui.go` `fanoutChannelFrame`, `topicLoopBeforeAgent`, `topicLoopHuman` | `:1352`, `:632` | `:1352`, `:632`, `:669` | C2a/C2b ref |
| `api:internal/hub/view.go` `routeTopicLoops` call | (by name) | `:67` | C2a |
| `api:internal/hub/server.go` `QueueMaxPerBox`, `TopicLoopCap`, `runTopicLoopTimer` | `:88`, `:121` | `:88`, `:121`, `:764` | C2a |
| `api:internal/hub/openapi.json` `"TopicLoop"`, `/v1/topics/{task_id}/loops` | `:1113` | `:1113`, `:21274`, `:21448` | C2a |
| `api:internal/config/config.go` `QueueMaxPerBox`, `TopicLoopCap` | `:396` (**drifted**) | `:366`, **`:402`** | C2a |
| `api:cmd/spool/hub.go` `TopicLoopCap` wiring | `:427` | `:427` | C2a |
| `api:internal/hub/topic_loop.go` `routeTopicLoops`, `topicLoopsPreflight`, `topicLoopBits`, `dropTopicLoops` | `:45`, `:63-93`, `:129` | `:36`, `:45`, `:63`, `:129` | C2b |
| `api:internal/hub/topic_loop_fire.go` `topicLoopPromptMark`, `topicLoopHuman`, `topicLoopBeforeAgent`, `topicLoopAgent`, `topicLoopKindBlocker`, `topicLoopIssue`, `topicLoopFireIf`, `loopTopicHeld`, `loopSkip`, `loopTarget`, `TopicLoopTickOnce` | `:70`, `:219`, `:270`, `:300`, `:390`, `:438` | `:70`, `:209`, `:219`, `:233`, `:244`, `:270`, `:300`, `:375`, `:390`, `:438`, `:603` | C2b |
| `api:internal/hub/channels.go` `channelOf` | `:76` | `:76` | C2b ref |
| `api:internal/hub/message_move.go` `handleMove`, `MoveMessage` | `:197` | `:197`, `:326` | C2b |
| `api:internal/hub/topic_merge.go` `handleMergeTopic`, `mergeTopic`, `unmergeTopic` | `:77`, `:128` | `:56`, `:77` (`MergeTopic` `:108`), `:128` (`UnmergeTopic` `:137`) | C2b |
| `wui:src/utils/sidebar-row-menu.mjs` `rowMenuItems`, `properties`, `archive-channel`, `delete` | `:14`, `:16`, `:17-58`, `:24-37`, `:32`, `:34`, `:36` | `:14`, `:16`, `:17-58`, `:24-37`, `:32`, `:34`, `:36` | C3 |
| `wui:src/utils/uiIcons.ts` `refresh` icon | `:421` | `:421` | C3 ref |
| `wui:src/components/SidebarRowMenu.vue` `rowMenuItems` call, `choose` | `:130-142`, `:245-277` | `:93` (`properties`), `:112`, `:130-137`, `:245-264` | C3 |
| `wui:src/components/ChannelSidebar.vue` `@contextmenu`, `<SidebarRowMenu>`, `ChannelPropertiesDialog`, `openChannelMenu`, `useSidebarChannelAdmin` | `:325`, `:352-375`, `:358`, `:641`, `:765` | `:325`, `:352-360`, `:641`, `:672`, `:765`, `:1041` | C3 |
| `wui:src/composables/useSidebarChannelAdmin.ts` `showProperties`, `deletableChannel`, `onChannel` | `:48-50` | `:48`, `:66`, `:100`, `:105` | C3 |
| `wui:src/components/TopicLoopsDialog.vue` locked/add block, `defineProps`, `load`, `save`, `toggle`, `remove`, `onFrame`, `onMockTopicLoops` | `:102-105` | `:102-105`, `:123`, `:158` (`listTopicLoops` `:163`), `:203`, `:216`, `:220`, `:224`, `:233` | C3 |
| `wui:src/utils/topic-loops.mjs` `LOOP_TRIGGERS`..`loopsFromFrame` | (by name) | `:16`, `:48`, `:53`, `:104`, `:115`, `:136`, `:148`, `:160`, `:179`, `:188` | C3 |
| `wui:src/utils/live-ws.mjs` `channelDeleted`, `topicLoops`, `onChannel` switch | `:35`, `:529-532` | `:35`, `:66`, `:530-531`, `:564` | C3 |
| `wui:src/utils/spool-client.mjs` `*TopicLoop*` proxy list | (by name) | `:108-112` | C3 |
| `wui:src/utils/spool-client-lazy.mjs` `*TopicLoop*` impl + exports | (by name) | `:1156-1184`, `:2648-2652` | C3 |
| `wui:src/utils/spool-client-mock.mjs` mock topic loops | (by name) | mock topic loop handlers | C3 |
| `wui:src/types/mjs-shims.d.ts` `*TopicLoop*` declarations | (by name) | `:209-217` | C3 |
| `wui:i18n/locales/*.json` | 19 files | 19 files | C3 |
| `csi-spl-doc/doc/help/channels-and-direct-messages.md`, `index.md` | (by name) | `index.md:67` | C5 |
| `csi-spl-cnf/csi-spl/all.env.yaml` `mistral_ui_allowed`, `mistral_review_allowed`, `agent_split_by_kind` | `:1514-1530`, `:1567-1574` (**drifted**) | **`:1548`**, **`:1564`**, **`:1601-1606`** (incl. `i18n`; full block `:1601-1608`) | ref |

## 2. Rows

Kinds from spec 182 section 9.9; vendors measured with
`LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix` (csi-spl-orc, 2026-11-26
`05:23Z`; `instance: kinds off grok,qwen, paused none (hub)`):

| kind | pick at 05:23Z | main / backup (cnf `all.env.yaml:1601-1606`) | notes |
|---|---|---|---|
| `complex_coding` | `claude` | `claude` (90%) / `agy` (10%) | `mistral` banned from coding (owner `b61851fb` msg `91bf8278`); `grok`, `qwen` off |
| `simple_coding` | `claude` | `claude` (44%) / `agy` (41%, backup) | `codex` (15%) skipped (no cli -> share to `agy`); `agy` currently 64% over, `claude` 27% under; `mistral` banned |
| `tests` | `claude` | `claude` (70%) / `agy` (15%, backup) | `codex` (15%) skipped (no cli -> share to `agy`); `mistral` banned |
| `specs_and_docs` (with `LANE_MIX_PATHS=csi-spl-wui/public/help-md/...`) | `agy` | `agy` (80%) / `claude` (5% -> 20% effective, backup) | `mistral` (15% -> 0%) skipped by `mistral_ui_allowed: false` (`all.env.yaml:1548`, developer guide 5.1) because `C5` writes under `csi-spl-wui/public/help-md/` |
| `i18n` | `agy` | `agy` (100%) | Required language check is Google Cloud Translation (`cd csi-spl-orc && ENV=dev ./run -a do_spl_lang_review_gct`); an `agy` review is optional |

The placer re-runs `do_spl_lane_mix` at placement time and takes the backup if
the main is unavailable. No coding, test, or `csi-spl-wui/` row ever goes to
`mistral`.

**R7 reviewers** (rulebook 2.7.2, 2.7.3): strictly cross-vendor — **`agy`**
reviews every `claude`-authored row (`C1`, `C2a`, `C2b`, `C3`, `C4`; and `C5`
if placed on backup `claude`), and **`claude`** reviews every `agy`-authored
row (`C5`, and any coding/test row placed on backup `agy`). **`mistral`** sits
on no review seat (`mistral_review_allowed: false`, `all.env.yaml:1564`, owner
HUM-10 t1 `91992830` msgs `65a45673` and `591ca574`), and **`grok`** is off in
instance settings. Both `claude` and `agy` are live and unpaused at `05:23Z`.
Per rulebook 2.7.3, no row pushes to `master` without a cross-vendor R7 PASS
(if an assigned seat is absent or unresponsive for 15 minutes, the lane reports
a blocker to the orchestrator to place an eligible cross-vendor replacement;
this plan claims no same-vendor waiver).

### 2.1 Action table

| row | what | kind | vendor (main / backup) | R7 | depends on | batch |
|---|---|---|---|---|---|---|
| C1 | rdb + store: `channel_loops`, `channel_loop_state`, `ChannelLoopStore` (Postgres + Memory), `UnarchiveChannel` reset, RLS / change_stamp / channelmove / cpCarried | `complex_coding` | `claude` / `agy` | `agy` (`claude` if `agy`) | R3 wait: live `c-904` (s187 S1) + `c-907` (s196 T1) landed (2.3) | 1 |
| C2a | hub routes + config + WS + OpenAPI (`/v1/channels/{channel}/loops`, CL3 B policy, 60/120 caps, `channel_loops` frame) | `complex_coding` | `claude` / `agy` | `agy` (`claude` if `agy`) | C1 landed | 2 |
| C2b | hub fire + tick + topic lifecycle (all 11 triggers, CL1 A, unified Q10 A + N4 B, CL4 B open-topic scan, move/merge/archive state cleanup) | `complex_coding` | `claude` / `agy` | `agy` (`claude` if `agy`) | C1, C2a landed | 3 |
| C3 | WUI + i18n + unit tests (`Channel loops…` menu entry, shared `TopicLoopsDialog.vue`, `live-ws`, client + mock, 19 locales + `do_spl_lang_review_gct`) | `simple_coding` (+ GCT) | `claude` / `agy` (never `mistral`) | `agy` (`claude` if `agy`) | C2a landed (and R3 wait: s186 M11 if live) | 3 |
| C4 | WUI e2e (`wui:tests/e2e/channel-loops.test.mjs`) | `tests` | `claude` / `agy` (never `mistral`) | `agy` (`claude` if `agy`) | C3 landed | 4 |
| C5 | spec status + synced user help (`spec.md`, `doc/help/`, `wui:public/help-md/`) | `specs_and_docs` | `agy` / `claude` (never `mistral`) | `claude` (`agy` if `claude`) | C2b, C4 landed | 5 |

Six rows total: within rulebook 1.1's hard cap of 10 rows (no cap waiver
needed). Maximum 2 rows live in parallel (Batch 3: `C2b` ∥ `C3`).

### 2.2 Batches and disjoint files (R1, R16)

Every file across all six rows belongs to **exactly one row** (zero shared
files inside any batch or across batches):

- **Batch 1: `C1`.**
  - New: `rdb:<NNNN>_channel_loops.sql` (number from `do_rdb_migration_next`),
    `api:internal/store/channel_loop.go`, `channel_loop_postgres.go`,
    `channel_loop_memory.go`, `channel_loop_test.go`.
  - Modified: `api:internal/store/channels_postgres.go`, `channels_memory.go`,
    `rls_test.go`, `change_stamp_test.go` (2.4 N1), `crosstenant_test.go`
    (2.4 N1), `channel_copy_apply_postgres.go` (2.4 N1),
    `api:internal/channelmove/catalogue.go`.
- **Batch 2: `C2a`** (within 30 min of `C1` landing, R16).
  - New: `api:internal/hub/channel_loop.go`, `channel_loop_test.go`.
  - Modified: `api:internal/hub/view.go`, `server.go`, `openapi.json`,
    `api:internal/config/config.go`, `api:cmd/spool/hub.go`.
- **Batch 3: `C2b` ∥ `C3`** (within 30 min of `C2a` landing, R16; zero file
  overlap — `C2b` is Go hub only, `C3` is WUI only).
  - **`C2b`** new: `api:internal/hub/channel_loop_fire.go`,
    `channel_loop_fire_test.go`. Modified: `api:internal/hub/topic_loop_fire.go`,
    `topic_loop.go`, `message_move.go`, `topic_merge.go`.
  - **`C3`** modified: `wui:src/utils/{sidebar-row-menu.mjs,topic-loops.mjs,live-ws.mjs,spool-client.mjs,spool-client-lazy.mjs,spool-client-mock.mjs}`,
    `wui:src/components/{SidebarRowMenu.vue,ChannelSidebar.vue,TopicLoopsDialog.vue}`,
    `wui:src/composables/useSidebarChannelAdmin.ts`,
    `wui:src/types/mjs-shims.d.ts`, `wui:i18n/locales/*.json` (19 files),
    `wui:i18n/lang-review/<run-id>.json` (new report committed by
    `do_spl_lang_review_gct`),
    `wui:tests/unit/{sidebar-row-menu.test.mjs,topic-loops.test.mjs}`.
- **Batch 4: `C4`** (within 30 min of `C3` landing, R16).
  - New: `wui:tests/e2e/channel-loops.test.mjs` only.
- **Batch 5: `C5`** (within 30 min of both `C2b` and `C4` landing, R16).
  - Modified: `csi-spl-doc/specs/182-topic-loop-prompt/spec.md` (row status),
    `csi-spl-doc/doc/help/{channels-and-direct-messages.md,index.md}`,
    `wui:public/help-md/{channels-and-direct-messages.md,index.md}` (synced by
    `node csi-spl-wui/src/node/help/sync-help.mjs`; see 2.4 N3).

### 2.3 R3: live and queued lanes, read `2026-11-26 05:23-05:24Z`

Commands run:
- `lane-map.sh` (05:24Z): 28 live lanes across both fleet boxes (plus 6 role
  seats).
- `lane-map.sh --check <row paths> --agent a-934` for each of `C1`, `C2a`,
  `C2b`, `C3`, `C4`, `C5` and this plan file (05:24Z): every check returned
  **exit 4** (`no live lane lists <paths>, but 16 live lane(s) record no files:
  their scope is unknown, not free`).
- `cd csi-spl-orc && ./run -a do_spl_spawn_queue` (05:23Z): **7 queued**, 0
  placing.

**Concrete file overlaps identified by reading live and queued briefs (05:24Z):**

| active / queued lane | state & age (05:23-05:24Z) | shared files with this plan | plan row affected & ordering rule |
|---|---|---|---|
| `c-904` (`c-904-c002-s187-s1`, spec 187 S1) | **live**, 12m (in the 16 `unknown:` no-files-recorded list) | `api:internal/store/rls_test.go`, `api:internal/channelmove/catalogue.go` (and `channel_copy_apply_postgres.go` if S1 adds a `Moved` table) | **`C1`**: **must wait until `c-904` (S1) lands on `origin/master`** |
| `c-907` (`c-907-c002-s196-t1-topic-tags-store`, spec 196 T1) | **live**, 3m | `api:internal/store/rls_test.go`, `api:internal/store/change_stamp_test.go`, `api:internal/store/crosstenant_test.go`, `api:internal/store/channel_copy_apply_postgres.go`, `api:internal/channelmove/catalogue.go` | **`C1`**: **must wait until `c-907` (T1) lands on `origin/master`** |
| `d908fbc6` (`claude:c002-s186-m11-wui-multicast-action`, spec 186 M11) | **queued** pos 4/7, prio 3, age 8m | `wui:src/utils/spool-client.mjs`, `wui:src/utils/spool-client-mock.mjs`, `wui:i18n/locales/*.json` | **`C3`** (Batch 3): **do not spawn `C3` while M11 is live**; Batch 3 naturally runs after C1 + C2a land, and the placer re-checks `lane-map.sh --check` |
| `cd76e33f` (`claude:c002-s187-s2`, spec 187 S2) | **queued** pos 5/7, prio 4, age 14m | none (`api:internal/search/*`, `store/search_postgres.go`, `hub/search.go`, `search-v1.md`) | disjoint from all rows `C1`-`C5` |
| `a8001b67` (`claude:c002-s187-s12a`, spec 187 S12a) | **queued** pos 6/7, prio 4, age 13m | none (`api:internal/taskcron/*`) | disjoint from all rows `C1`-`C5` |
| `15629f29` (`claude:c002-s186-m2-hub-send-checks`, spec 186 M2) | **queued** pos 2/7, prio 3, age 8m | none (`hub/wui.go`, `hub/wui_multicast.go`, `store/{store,postgres,memory}.go`) | disjoint from all rows `C1`-`C5` |
| `5b1b7d82` (`c001-s186-m9-n2-qto-sync`, pos 1/7, 40h WAIT), `3343e159` (`c002-s182-cl-build-claude-panel-seat`, pos 3/7, 8m), `5a432cc3` (`c002-60bf4e56-qto-doc-export-pdf`, pos 7/7, 7m) | **queued** | none (Qto sync / our own panel seat / Qto PDF export) | disjoint |
| Other live lanes on `csi-spl` (`a-826` R7 review SPL-6517, `c-913` r05-01 orc cron, `a-932` spec 150 v2.0, `c-893`/`a-891`/`a-922` r05, `c-902`/`a-927` b50, `c-957`/`c-965` spec 125) and 13 non-csi-spl workspace rotation seats (`c-029`, `c-041`, `c-086`, `c-146`, `c-187`, `c-398`, `c-407`, `c-416`, `c-474`, `c-535`, `c-728`, `c-927`, `c-936`) | **live** (16 with no files recorded -> exit 4) | none by their briefs (except `c-904` listed above) | per R3, the placer re-runs `lane-map.sh --check` per row at placement and asks any lane still answering exit 4 |

**Upcoming (not yet queued) cross-spec overlaps to watch at placement (R3):**

- **`C1`** vs future **spec 196 T2** (`api:internal/store/channels_postgres.go`):
  place `C1` after `c-904` (S1) and `c-907` (T1) land, and never concurrently
  with spec 196 T2.
- **`C2a`** vs future **spec 187 S3 / S6 / S7 / S11** (`hub/server.go`,
  `hub/openapi.json`, `config/config.go`) and **spec 196 T3** (`hub/view.go`,
  `hub/openapi.json`): serialize around whichever of those is live at Batch 2
  placement.
- **`C2b`** vs future **spec 186 M10** (`hub/topic_loop.go`,
  `hub/topic_loop_fire.go`): serialize around M10 if live at Batch 3 placement.
- **`C3`** vs future **spec 186 M8 / M10** (`TopicLoopsDialog.vue`,
  `topic-loops.mjs`, `locales/*.json`), **spec 187 S8** (`SidebarRowMenu.vue`,
  `ChannelSidebar.vue`, `sidebar-row-menu.mjs`, `spool-client*.mjs`,
  `locales/*.json`), and **spec 196 T4 / T5a / T5b / T6** (`live-ws.mjs`,
  `spool-client*.mjs`, `ChannelSidebar.vue`, `locales/*.json`): serialize
  around any live WUI lane touching those files at Batch 3 placement.
- **`C5`** vs future **spec 196 T7** (`message-levels-and-topics.md`,
  `user-settings.md`, `keyboard-shortcuts.md`): disjoint if `C5` edits
  `channels-and-direct-messages.md` and `index.md` (2.4 N3).

### 2.4 Open decisions and holder notes

**Open questions for the owner: none.** All four product choices (CL1 A, CL2 B,
CL3 B, CL4 B) were decided in poll `13fb1941` (msg `facaaf33`) and folded into
spec 182 v0.10 (`a1b1984fd`). Channel archive retention (W1) is decided in 9.5.
Round size is 6 rows (within rulebook 1.1's hard cap of 10; rulebook 5.1's 2-3
cap binds bug-fix and refactor rounds only).

**Holder notes (no owner question):**

- **N1. Three `C1` gate files missing from spec 182 9.9's table.** Measured on
  `6b216a319`, `PRE_PUSH_TIER=full` fails on `C1` unless `C1` also edits:
  1. `api:internal/store/change_stamp_test.go` (`stampTables` `:22-28`, beside
     `"topic_loops"` `:27`): spec 9.7 puts the deferred `change_stamp` trigger
     on `channel_loops` and `channel_loop_state`, and
     `TestChangeStampTriggerCatalogue` (`:45-65`) asserts an exact 1-to-1 match
     between DB `change_stamp` triggers and `stampTables`.
  2. `api:internal/store/crosstenant_test.go` (`seedTenantAll`, beside
     `topic_loops` `:426-430`): `TestChangeStampEveryTable`
     (`change_stamp_test.go:100-102`) fails if `seedTenantAll` inserts 0 rows
     for any table in `stampTables`.
  3. `api:internal/store/channel_copy_apply_postgres.go` (`cpCarried` `:59-77`,
     beside `"topic_loops": false` `:75`): spec 9.5 classifies `channel_loops`
     and `channel_loop_state` as `Class: Moved` in `channelmove.Catalogue`, and
     `TestChannelCopyRulesMatchCatalogue`
     (`channel_copy_apply_postgres_test.go:465-477`) plus `cpCheckRequest`
     (`:79`, check loop `:87-91`) fail if any `Moved` table lacks a `cpCarried`
     entry.
  None of `C2a`-`C5` touches these three files, so R1 disjointness holds.
- **N2. `cpCarried` rule for channel loops.** Set `"channel_loops": false` and
  `"channel_loop_state": false` in `channel_copy_apply_postgres.go`, matching
  `"topic_loops": false` (`:75`: a copied channel snapshot must not start
  firing loops or carry stale runtime state).
- **N3. `C5` help target.** Spec 182 9.9 offers
  `csi-spl-doc/doc/help/{channels-and-direct-messages.md,index.md}` (or new
  `loops.md`). This plan pins `channels-and-direct-messages.md` and `index.md`
  (plus their `sync-help.mjs` copies under `wui:public/help-md/`): it fits
  directly beside channel properties (`index.md:67`) and stays disjoint from
  spec 196 T7 (`message-levels-and-topics.md`).
- **N4. `C3` language check (`do_spl_lang_review_gct`).** `C3` adds keys to
  `wui:i18n/locales/en.json` and machine translations to all 18 other locale
  files, runs `cd csi-spl-orc && ENV=dev ./run -a do_spl_lang_review_gct`
  (`spl-lang-review-gct.func.sh:37`, `ENV` defaults to `dev`), commits the
  generated report `wui:i18n/lang-review/<run-id>.json` (`LANG_GCT_OUT_DIR`
  default, `spl-lang-review-gct.func.sh:42`), and puts
  `Lang-review: gct <run-id>` in its commit body so pre-push `wui-lang-review`
  and CI workflow 10 pass.
- **N5. Drifted line citations since `c9dd02117`.** Two spec 182 v0.10 citations
  moved on `6b216a319`: `api:internal/config/config.go` `TopicLoopCap` is now
  `:402` (was `:396`), and `csi-spl-cnf/csi-spl/all.env.yaml` `agent_split_by_kind`
  is `:1601-1606` (incl. `i18n`; full block `:1601-1608`; was `:1567-1574`,
  guards `:1548` and `:1564`). Every row brief re-measures its sites on
  `origin/master` at work time.

## 3. Proposed row briefs

Each row brief carries: `Epic: SPL-2398`,
`Spec: csi-spl-doc/specs/182-topic-loop-prompt`, `Class: feature`, its `Kind:`,
`Topic: cbb1897b-4d35-44df-93c3-a2bbd2b6defa`, its row's verbatim line from
spec 182 section 9.9 (R4), its cross-vendor R7 reviewer assignment (R7),
"plan on `origin/master` at work time, re-measure every cited line", its
binding contract from spec 182 section 9.8, its R2 test column, and the
standing Never list (no prd writes, no installs, no keys, no terraform, no
owner-topic post, PUBLIC repo hygiene, commit as the repo's canonical
identity, no AI trailers, explicit pathspecs, no force-push, release-note
trailers on every commit). Each row gets its own issue at placement and cites
it in its commit subject (e.g. `feat(api, SPL-<n>): ... (spec 182 C1)`), never
closing this plan's issue `SPL-6563`. Every row pushes first to
`review/s182-<row>` for R7 review and lands on `master` only after a verified
`PASS` (`do_spl_review_line_check` rc 0) and the dispatch holder's GO LAND.

### 3.1 C1 - rdb + store

- **Kind / Batch / Vendor / R7:** `complex_coding`. Batch 1 — **place only
  after live `c-904` (s187 S1) and `c-907` (s196 T1) land on `origin/master`,
  and never concurrently with s196 T2** (2.3). Author: `claude` (backup `agy`).
  R7: `agy` (`claude` if authored by `agy`). Never `mistral`.
- **Files (exclusive):**
  - New: `rdb:<NNNN>_channel_loops.sql` (number claimed via
    `cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next`),
    `api:internal/store/channel_loop.go`, `channel_loop_postgres.go`,
    `channel_loop_memory.go`, `channel_loop_test.go`.
  - Modified: `api:internal/store/channels_postgres.go` (`DeleteChannel` `:93`,
    `ArchiveChannel` `:136`, `UnarchiveChannel` `:177`),
    `api:internal/store/channels_memory.go` (`DeleteChannel` `:144`,
    `ArchiveChannel` `:215`, `UnarchiveChannel` `:260`),
    `api:internal/store/rls_test.go` (`rlsTables` `:68-100`, beside
    `"topic_loops"` `:92`),
    `api:internal/store/change_stamp_test.go` (`stampTables` `:22-28`, 2.4 N1),
    `api:internal/store/crosstenant_test.go` (`seedTenantAll` `:426-430`,
    2.4 N1),
    `api:internal/store/channel_copy_apply_postgres.go` (`cpCarried` `:59-77`,
    `"channel_loops": false`, `"channel_loop_state": false`, 2.4 N1/N2),
    `api:internal/channelmove/catalogue.go` (`movedTables` `:93`:
    `channel_loops` `Set: "channel_id = @channel"` before `channel_loop_state`
    `Set: "task_id = ANY(@tasks)"` for FK parent-before-child insert order).
- **Contract:** spec 182 sections 9.5, 9.6, 9.7 and 9.8.1 whole
  (`ChannelLoopStore`, `ChannelLoopsMax = 20`, `ChannelLoopCapDefault = 60`,
  `ChannelLoopTotalCapDefault = 120`, `ChannelOpenTopicsPage = 100`, outcome
  constants `ChannelFireOK`, `ChannelFireTopicCap`, `ChannelFireLoopCap`,
  `ChannelFireChannelCap`, `ChannelFireInactive`, `ChannelLoop`,
  `ChannelLoopTopicState`, `ChannelLoopIdleDue`, `ChannelOpenTopic`, both
  `Memory` and `Postgres` compile-time checks). Reuse `TopicLoopTriggers`,
  `TopicLoopOn`, `TopicLoopPaused`, `TopicLoopIntervalMin..Max`,
  `TopicLoopPromptMax`, `TopicLoopKeywordMax`, `ErrBadTopicLoop`,
  `TopicLoopEdit` (`store/topic_loop.go:35-130`). `UnarchiveChannel` advances
  `next_due_at` / `daily_due_at` forward from `now` and clears stale
  `idle_due_at` / `idle_post` inside its transaction (9.5). Clean-code limits:
  <= 75 lines/func, depth <= 4, <= 7 params, no `SELECT *`.
- **Done test (spec 182 9.9 C1, plus N1 gate tests) & `PRE_PUSH_TIER=full`:** Postgres +
  Memory parity; all 11 triggers + field CHECKs + `ChannelLoopsMax` (20)
  ceiling; `CountChannelLoopFire` enforces all three caps concurrently (12/h
  topic -> `topic_cap`, 60/h loop -> `loop_cap`, 120/h channel total ->
  `channel_cap`, atomic no-op on refusal) and rolls over after 1 h (including
  3-loop 120/h cap interaction); `ClaimDueChannelLoops` and
  `ClaimDueChannelLoopIdles` skip archived channels (kept by `ArchiveChannel`),
  move `next_due_at` / `daily_due_at` (incl. DST in `Europe/Helsinki`), and
  return `Due` + pre-move `DueAt`; `UnarchiveChannel` advances due times from
  `now` and clears stale idle rows; `ChannelOpenTopics` uses
  `topic_head_parts_channel`, skips archived topics and `LobbyTaskID`, filters
  to topics whose canonical channel matches `channel` (a task with
  `topic_head_parts` rows in two channels appears only under its canonical
  channel), and keyset-paginates newest-first with no recency cutoff;
  `DeleteChannel` cascades both tables; RLS + `change_stamp_test.go` +
  `crosstenant_test.go` + `catalogue_test.go` + `channel_copy_apply_postgres_test.go`
  pass.
- **Red controls (both seen RED then GREEN, quoted in commit body):**
  (a) archive a channel with a due loop and drop `notArchived` from
  `ClaimDueChannelLoops` -> archived-channel claim test fails;
  (b) drop the 120/h channel-sum check in `CountChannelLoopFire` -> 3-loop
  channel-cap test passes 120 and fails.
- **Test column (R2), at least:** `store/channel_loop_test.go`,
  `store/rls_test.go`, `store/rls_failclosed_test.go`,
  `store/change_stamp_test.go`, `store/crosstenant_test.go`,
  `store/channel_delete_test.go`, `store/channel_copy_apply_postgres_test.go`,
  `store/channel_move_plan_test.go`, `channelmove/catalogue_test.go`,
  `bash csi-spl-api/src/bash/tests/run-all-tests.sh`, and
  `cd csi-spl-iac && PRE_PUSH_TIER=full ./run -a do_check_pre_push`.
- **Not touched:** any `api:internal/hub/` file, `messages` table, `topic_loops`
  table, `topic_loop*.go`, `csi-spl-wui/`.

### 3.2 C2a - hub routes + config + WS + OpenAPI

- **Kind / Batch / Vendor / R7:** `complex_coding`. Batch 2 (after `C1` lands,
  R16; check R3 against s187 S3/S6/S7/S11 and s196 T3). Author: `claude`
  (backup `agy`). R7: `agy` (`claude` if authored by `agy`). Never `mistral`.
- **Files (exclusive):**
  - New: `api:internal/hub/channel_loop.go`, `channel_loop_test.go`.
  - Modified: `api:internal/hub/view.go` (register `s.routeChannelLoops(mux)`
    beside `s.routeTopicLoops(mux)` `:67`),
    `api:internal/hub/server.go` (`Options.ChannelLoopCap`,
    `Options.ChannelLoopTotalCap` beside `TopicLoopCap` `:121`),
    `api:internal/hub/openapi.json` (`ChannelLoop` schema beside `TopicLoop`
    `:1113`; `/v1/channels/{channel}/loops` and
    `/v1/channels/{channel}/loops/{loop_id}` paths),
    `api:internal/config/config.go` (`SPOOL_HUB_CHANNEL_LOOP_CAP` default `60`,
    `SPOOL_HUB_CHANNEL_TOTAL_CAP` default `120` beside `TopicLoopCap` `:402`),
    `api:cmd/spool/hub.go` (wire both caps beside `TopicLoopCap` `:427`).
- **Contract:** spec 182 sections 9.4, 9.6 and 9.8.2 whole. Routes
  `GET`/`POST`/`OPTIONS /v1/channels/{channel}/loops` and
  `PUT`/`DELETE`/`OPTIONS /v1/channels/{channel}/loops/{loop_id}`; optional
  interface `s.o.Store.(store.ChannelLoopStore)` -> `501 not_implemented` when
  absent; `s.channelDoor` (`channel_members.go:123`) plus `store.ChannelHidden`
  (`channels.go:56`) refusal (`404 unknown_channel` for non-members, archived
  channels, and hidden virtual `#issues` / `#tasks`); CL3 B write door
  `s.mayChannelLoops` calling `s.mayArchiveByPolicy(ctx, t.ID, hum, s.archivePolicy(t), change)`
  where `change` is `channelOwner(row.CreatedBy, hum) || a.TenantOwner || a.Has(rbac.Admin)`
  (`403 not_allowed`); `billing.AllowsWrite`; `ChannelLoopsMax` (20) ->
  `400 bad_loop`; `channelLoopBits` (30 s TTL cache + write refresh, reused by
  `C2b`); `channelLoopIdle` (`author_left` / `author_no_right`); `held_until`
  (60/h per-loop cap OR earliest active `hour_start + 1h` when channel sum >=
  120/h); `channel_loops` WS frame via `s.fanoutChannelFrame` +
  `s.channelMemberSet`.
- **Done test (spec 182 9.9 C2a, plus OpenAPI route/serve tests):** `go test ./internal/hub/... ./internal/config/...`:
  CRUD (`GET`/`POST`/`PUT`/`DELETE`/`OPTIONS`); CL3 B
  `tenants.topic_archive_policy` matrix (`everyone`, `admins`, `starter` on
  user-created and `hub`-created default channels, plus demo workspace forced
  to `starter`) + `rbac.ChannelsEdit` + `demo_read_only` + billing gate;
  `channelDoor` + `ChannelHidden` guard returns `404 unknown_channel` to
  non-members, archived channels, and hidden virtual channels (`#issues` /
  `ChannelTasks`, preventing an FK 500); `501 not_implemented` when store lacks
  `ChannelLoopStore`; `ChannelLoopsMax` (20) refusal; `channelLoopBits` cache
  refresh on write; `channel_loops` WS frame reaches channel members only;
  `idle` (`author_left` / `author_no_right` after policy flip) and `held_until`
  (both 60/h loop cap and 120/h channel cap earliest-rollover) reporting;
  `SPOOL_HUB_CHANNEL_LOOP_CAP` (60) and `SPOOL_HUB_CHANNEL_TOTAL_CAP` (120)
  config defaults; `TestOpenAPIRoutes` (`openapi_routes_test.go`),
  `TestOpenAPIServedToMember` (`openapi_serve_test.go:32`), and
  `TestOpenAPIServeRouteNeedsItsOperation` (`openapi_serve_test.go:77`) green.
- **Red controls (both seen RED then GREEN, quoted in commit body):**
  (a) bypass `channelDoor` -> non-member 404 test fails;
  (b) hard-code `mayChannelLoops` to `true` -> `admins` / `starter` policy
  refusal tests fail.
- **Test column (R2), at least:** `hub/channel_loop_test.go`,
  `hub/openapi_routes_test.go`, `hub/openapi_serve_test.go`,
  `hub/tenant_settings_test.go`, `hub/topic_archive_test.go`,
  `hub/topic_loop_test.go`, `config/*_test.go`,
  `bash csi-spl-api/src/bash/tests/run-all-tests.sh`.
- **Not touched:** `topic_loop.go`, `topic_loop_fire.go`, `message_move.go`,
  `topic_merge.go` (`C2b`'s), any `api:internal/store/` file, `csi-spl-wui/`.

### 3.3 C2b - hub fire + tick + topic lifecycle

- **Kind / Batch / Vendor / R7:** `complex_coding`. Batch 3 (after `C1` and
  `C2a` land, R16; parallel with `C3`; check R3 against s186 M10). Author:
  `claude` (backup `agy`). R7: `agy` (`claude` if authored by `agy`). Never
  `mistral`.
- **Files (exclusive):**
  - New: `api:internal/hub/channel_loop_fire.go`, `channel_loop_fire_test.go`.
  - Modified: `api:internal/hub/topic_loop_fire.go` (`topicLoopFireIf` `:300`,
    `topicLoopHuman` `:209`, `topicLoopBeforeAgent` `:219`, `topicLoopAgent`
    `:233`, `topicLoopKindBlocker` `:244`, `topicLoopIssue` `:270`,
    `TopicLoopTickOnce` `:603`),
    `api:internal/hub/topic_loop.go` (`dropTopicLoops` `:129`),
    `api:internal/hub/message_move.go` (`handleMove` `:197`, after
    `MoveMessage` `:326`),
    `api:internal/hub/topic_merge.go` (`mergeTopic` `:77` after `MergeTopic`
    `:108`; `unmergeTopic` `:128` after `UnmergeTopic` `:137`).
- **Contract:** spec 182 sections 9.3, 9.5, 9.6 and 9.8.1 whole. Unified
  awaited-answer pass across `TopicLoopsOn(T)` and `ChannelLoopsOn(C)` in
  `topicLoopFireIf` (CL1 A both fire; Q10 A + N4 B stops cross-scope
  `after_agent_reply` ping-pong while preserving other checked boxes); CL2 B
  uniform application (no opt-out); exclude archived (`topicClosed`), paused
  (`AnyTopicPaused`), DM (`channel == ""`), and `LobbyTaskID`; fired `msg_id`
  = `uid.FromSeed("channel-loop:" + loopID + ":" + taskID + ":" + cause)` and
  body starts with `topicLoopPromptMark` (`"Loop prompt (background; channel #<channel>, set by @HUM-n, fired by <cause>)"`);
  `TopicLoopTickOnce` runs `channelLoopTickOnce` (keyset-paginated
  `ChannelOpenTopics` newest-first, no recency cutoff, continues past
  `ChannelFireTopicCap`, stops on `ChannelFireLoopCap` / `ChannelFireChannelCap`
  with no carry-over cursor, emits the exact 9.6 structured `Info` log
  contract) and `ClaimDueChannelLoopIdles`; `dropTopicLoops`, `handleMove`,
  `mergeTopic`, and `unmergeTopic` call `DeleteChannelLoopTopicState`; zero
  extra round trips when `channelLoopBits` is false or on DMs.
- **Done test (spec 182 9.9 C2b verbatim):** `go test ./internal/hub/...`: all
  11 triggers fire on existing, newly created, and moved-in open topics, never
  on moved-out, merged-away, paused, archived, DM, or `LobbyTaskID` topics;
  CL1 A additive firing (topic loop + channel loop both fire on same event);
  unified Q10 A + N4 B stops cross-scope `after_agent_reply` ping-pong while
  still allowing another loop's keyword/file/blocker box; CL2 B uniform
  application (no opt-out); CL4 B timed tick scans every open topic
  newest-first across pages (including >25 topics and >7-day-old topics), skips
  paused / no-agent topics without charging caps, continues past a `topic_cap`
  (12/h) topic to older open topics, stops on `loop_cap` (60/h) or
  `channel_cap` (120/h) dropping unreached older topics with no carry-over
  cursor on the next tick, and asserts the log contract (one `Info` line per
  `(loop_id, tick)` with `loop_id`, `channel`, `outcome`, `fired`, `skipped` on
  cap stop, plus `why="topic_cap"` on a skipped topic); `dropTopicLoops`,
  `handleMove`, `mergeTopic`, and `unmergeTopic` clear `channel_loop_state`;
  `TestRoundTripsPerRequest` confirms 0 extra round trips on a tenant with no
  channel loops and on DM sends.
- **Red controls (both seen RED then GREEN, quoted in commit body):**
  (a) drop unified `ev.answer` across topic + channel pools -> cross-scope
  ping-pong test fails;
  (b) stop the tick loop on `topic_cap` instead of continuing -> older open
  topic after a 12/h-capped topic never fires and test fails.
- **Test column (R2), at least:** `hub/channel_loop_fire_test.go`,
  `hub/topic_loop_fire_test.go`, `hub/topic_loop_store_test.go`,
  `hub/topic_loop_test.go`, `hub/topic_archived_refusals_test.go`,
  `hub/roundtrips_perf_test.go`, `hub/wui_send_memo_test.go`,
  `bash csi-spl-api/src/bash/tests/run-all-tests.sh`.
- **Not touched:** `view.go`, `server.go`, `openapi.json`, `config.go`,
  `cmd/spool/hub.go`, `channel_loop.go` (`C2a`'s), `wui.go`, `ws.go`,
  `issues.go`, `message_kind.go`, `topic_archive.go`, `csi-spl-wui/`.

### 3.4 C3 - WUI + i18n + unit tests

- **Kind / Batch / Vendor / R7:** `simple_coding` (+ Google Cloud Translation
  language check). Batch 3 (after `C2a` lands, R16; parallel with `C2b`; check
  R3 against s186 M11/M8/M10, s187 S8, s196 T4/T5a/T5b/T6). Author: `claude`
  (backup `agy`; **never `mistral`**). R7: `agy` (`claude` if authored by
  `agy`).
- **Files (exclusive):**
  - Modified:
    `wui:src/utils/sidebar-row-menu.mjs` (`:14`, `:16`, `:24-37`: add
    `channel-loops` with icon `'refresh'` between `properties` `:32` and
    `archive-channel` `:34`),
    `wui:src/utils/topic-loops.mjs` (add `channelLoopsFromFrame(frame, channelId)`
    beside `loopsFromFrame` `:188`),
    `wui:src/utils/live-ws.mjs` (add `channelLoops: 'channel_loops'` beside
    `channelDeleted` `:35` and route to `onChannel(f)` `:530-531`),
    `wui:src/utils/spool-client.mjs` (`:108-112`),
    `wui:src/utils/spool-client-lazy.mjs` (`:1156-1184`, `:2648-2652`),
    `wui:src/utils/spool-client-mock.mjs` (the five `*ChannelLoop*` methods +
    mock handlers),
    `wui:src/components/SidebarRowMenu.vue` (`:93`, `:112`, `:130-137`,
    `:245-264`),
    `wui:src/components/ChannelSidebar.vue` (`:352-360`, `:641`, `:672`,
    `:1041`, lazy `<LazyTopicLoopsDialog>`),
    `wui:src/components/TopicLoopsDialog.vue` (`:16`, `:102-105`, `:123`
    `defineProps`, `:158` `load`, `:203` `save`, `:216` `toggle`, `:220`
    `remove`, `:224` `onFrame`, `:233` `onMockTopicLoops`: optional `channelId`
    / `channelName` props, scope note, `useLive().onChannel` /
    `onMockChannelLoops`),
    `wui:src/composables/useSidebarChannelAdmin.ts` (`:48`, `:105`),
    `wui:src/types/mjs-shims.d.ts` (`:209-217`; no new `.mjs` module added so
    `SHIMS_CAP = 102` stays green),
    `wui:i18n/locales/*.json` (all 19 locale files:
    `sidebar.row_menu.channel_loops` and `sidebar.channel_loops.*`),
    `wui:tests/unit/sidebar-row-menu.test.mjs`,
    `wui:tests/unit/topic-loops.test.mjs`.
  - New: `wui:i18n/lang-review/<run-id>.json` (generated by
    `do_spl_lang_review_gct`, committed with the locale changes).
- **Contract:** spec 182 sections 9.2 and 9.8.3 whole. No channel row badge, no
  channel system post, no mark on messages (answer 7 C). Clean-code limits:
  <= 75 lines/func, depth <= 4, <= 5 params in TS/Vue; font sizes in `rem`;
  focus rings via canonical token.
- **Language check (required, 2.4 N4):** add keys to `en.json` and translations
  to all 18 other locales, run
  `cd csi-spl-orc && ENV=dev ./run -a do_spl_lang_review_gct`, commit the
  report JSON, and include `Lang-review: gct <run-id>` in the commit body.
- **Done test (spec 182 9.9 C3, plus WUI hygiene gates and pre-push e2e selection):** `pnpm run typecheck`,
  `pnpm run test:unit` (`i18n-parity`, `i18n-untranslated`, `i18n-no-raw-text`,
  `cleancode`, `mjs-shims-exist`, `unused-exports`, `font-size`,
  `focus-tokens`, `sidebar-row-menu` ordering and `channel-loops` entry,
  `channelLoopsFromFrame`, 11-trigger form rules), and
  `cd csi-spl-orc && ENV=dev ./run -a do_spl_lang_review_gct` on the 19 locale
  files; plus every e2e file selected by
  `cd csi-spl-iac && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e`
  (run by both author and R7 reviewer, rulebook 2.7.4).
- **Red controls (both seen RED then GREEN, quoted in commit body):**
  (a) drop `channel-loops` from `rowMenuItems` -> `sidebar-row-menu.test.mjs`
  fails;
  (b) leave a raw string in `TopicLoopsDialog.vue` ->
  `i18n-no-raw-text.test.mjs` fails.
- **Test column (R2), at least:** `tests/unit/sidebar-row-menu.test.mjs`,
  `tests/unit/topic-loops.test.mjs`, `tests/unit/live-ws.test.mjs`,
  `tests/unit/live-ws-lazy.test.mjs`, `tests/unit/spool-client.test.mjs`,
  `tests/unit/spool-client-mock-opener.test.mjs`, `tests/unit/i18n-parity.test.mjs`,
  `tests/unit/i18n-untranslated.test.mjs`, `tests/unit/i18n-no-raw-text.test.mjs`,
  `tests/unit/cleancode.test.mjs`, `tests/unit/mjs-shims-exist.test.mjs`,
  `tests/unit/unused-exports.test.mjs`, `tests/unit/font-size.test.mjs`,
  `tests/unit/focus-tokens.test.mjs`, and the `do_check_pre_push_e2e` selection.
- **Not touched:** `wui:tests/e2e/channel-loops.test.mjs` (`C4`'s),
  `wui:public/help-md/` (`C5`'s), any Go/RDB file.

### 3.5 C4 - WUI e2e

- **Kind / Batch / Vendor / R7:** `tests`. Batch 4 (after `C3` lands, R16).
  Author: `claude` (backup `agy`; **never `mistral`**). R7: `agy` (`claude` if
  authored by `agy`).
- **Files (exclusive):**
  - New: `wui:tests/e2e/channel-loops.test.mjs` only (all mock handlers live in
    `C3`'s `spool-client-mock.mjs`).
- **Done test (spec 182 9.9 C4, plus pre-push e2e selection):**
  `BASE_URL=<generated bundle> pnpm run test:e2e` on mock (plus
  `do_check_pre_push_e2e` selection): right-click channel row -> **Channel
  loops…** -> add, edit, pause/resume, delete a loop with all 11 triggers
  available; verify read-only lock when `may_edit: false` (under `admins` /
  `starter` policy); verify live `channel_loops` WS frame updates an open
  dialog; verify no badge or prompt card appears in the channel.
- **Red control (seen RED then GREEN, quoted in commit body):** drop the
  `channelLoops` emit in `SidebarRowMenu.vue` (temporary local mutation,
  reverted before commit; verify `git diff --stat csi-spl-wui/src/` is empty
  before committing) -> `channel-loops.test.mjs` fails to open the dialog.
- **Test column (R2), at least:** `tests/e2e/channel-loops.test.mjs` on the
  generated bundle (`nuxt generate`), `tests/e2e/channel-properties-esc.test.mjs`
  (neighbor menu entry sanity), and `do_check_pre_push`.
- **Not touched:** any `wui:src/` file, any Go/RDB/doc file.

### 3.6 C5 - spec status + user help

- **Kind / Batch / Vendor / R7:** `specs_and_docs`. Batch 5 (after both `C2b`
  and `C4` land, R16). Author: `agy` (backup `claude`; **never `mistral`**
  because `wui:public/help-md/` is under `csi-spl-wui/`, developer guide 5.1).
  R7: `claude` (`agy` if authored by `claude`).
- **Files (exclusive):**
  - Modified: `csi-spl-doc/specs/182-topic-loop-prompt/spec.md` (mark rows
    `C1`-`C5` landed with their shas and record the 2.4 N1/N5 adjustments),
    `csi-spl-doc/doc/help/channels-and-direct-messages.md` (document Channel
    loops: right-click entry, 11 triggers, dynamic application to open topics,
    CL3 B archive-policy permission, 12/60/120 hourly caps, archive/unarchive
    behaviour),
    `csi-spl-doc/doc/help/index.md` (`:67` summary line),
    `wui:public/help-md/channels-and-direct-messages.md` and
    `wui:public/help-md/index.md` (synced via
    `cd csi-spl-wui && node src/node/help/sync-help.mjs`; English only, no
    locale file touched).
- **Done test (spec 182 9.9 C5, plus `sync-help.mjs --check`):**
  `cd csi-spl-iac && ./run -a do_check_dist_hygiene && ./run -a do_check_pre_push`,
  `cd csi-spl-orc && ./run -a do_check_fleet_rules_drift`,
  `cd csi-spl-wui && node src/node/help/sync-help.mjs --check` (rc 0) and
  `node --test tests/unit/help-sync.test.mjs`.
- **Red control (seen RED then GREEN, quoted in commit body):** edit
  `csi-spl-doc/doc/help/channels-and-direct-messages.md` without running
  `sync-help.mjs` -> `tests/unit/help-sync.test.mjs` fails; run
  `sync-help.mjs` -> passes.
- **Not touched:** any Go, RDB, or `wui:src/` / `wui:i18n/` file;
  `message-levels-and-topics.md` (kept clear of spec 196 T7).

## 4. Consensus

| seat | vendor | sha | verdict |
|---|---|---|---|
| `c-938` (`c002-s182-cl-build-claude-panel-seat`, ask `3343e159`) | `claude` (cross-vendor to `agy` planner) | `6ae5fe136` (v0.1) | FAIL (W1-W3, N1-N4; seat file `review/c002-s182-cl-build-claude-seat` `af5878ff9`) |
| `c-938` (`c002-s182-cl-build-claude-panel-seat`, ask `3343e159`) | `claude` (cross-vendor to `agy` planner) | pending v0.2 | pending |
| holder (`c-002`, dispatch holder) | — | pending | pending GO |

## 5. Versions

| version | what |
|---|---|
| v0.1 | first plan for panel review (`6ae5fe136`), measured on `origin/master` `6b216a319` (`6b216a31990109235fbb11f3537c64e423b13b5c`); adds three verified C1 gate files (`change_stamp_test.go`, `crosstenant_test.go`, `channel_copy_apply_postgres.go`, N1) and live/queued R3 ordering around s187 S1 (`c-904`), s196 T1 (`c-907`), and s186 M11 |
| v0.2 | folds `c-938` FAIL on `6ae5fe136`: W1 replaces non-existent `TestOpenAPIServe` with `TestOpenAPIServedToMember` (`:32`) and `TestOpenAPIServeRouteNeedsItsOperation` (`:77`); W2 drops uncited same-vendor R7 quota waiver in favour of strict rulebook 2.7.2/2.7.3; W3 fixes line citations (`channels_postgres.go:77`, `channel_copy_apply_postgres.go:79`, `TopicLoopsDialog.vue` `:123/:158/:203/:216/:220/:224/:233`, `all.env.yaml:1601-1606`); N1 rewords done-test headings ("spec 182 9.9 Cx, plus ..."); N2 cites `spl-lang-review-gct.func.sh:42`; N4 adds `git diff --stat csi-spl-wui/src/` empty check to C4 red control |
