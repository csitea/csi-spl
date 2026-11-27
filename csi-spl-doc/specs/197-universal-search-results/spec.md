# Spec 197: Universal Search Results Page (`/us`)

Status: **Phase 1 — WHAT v1.0** (2026-11-27; unanimous 5/5 panel consensus on v0.2 `a8e89dbfb`; owner polls Q1–Q8 posted as `a3d8e5fc` and `d5d7113d`, answers pending).
Editor seat: `a-580` (`agy`, doc only).
v0.1 `edfb2ffee`; v0.2 `a8e89dbfb` folded all round-1 reviews (`c-582` R1–R8, `a-583` S1–S7, `c-584` W1–W3/N1–N6, `m-585` D1–D12) and was signed by all five seats (`993ceb8c1`, `9c4eb9b56`, `04145b860`, `140c72b6b`); v1.0 folds the three non-blocking v0.2 signature notes (`c-582` FR-US-11 row-menu link wording, `c-584` N7 posted-form parity and N8 `useSidebarRailOnly.ts:31` line cite).
Epic: **SPL-1292**. Issue: **SPL-6662**. Class: `feature`. Kind: `specs_and_docs`.
Discussion: `topic:bcfd15e1-2022-473f-b4a9-ae34eb756f1e` (`t1` `#spool-hub-ui`).
Review branch: `review/c002-bcfd15e1-search-results-spec`.
Builds on: [search-v1 contract](../003-spool-message-bus/contracts/search-v1.md), [022 top bar + global search](../022-spool-wui-top-bar-search/spec.md), [100 search index](../100-search-index/spec.md), [153 monitoring lanes tab](../153-monitoring-lanes-tab/spec.md), [154 contacts section](../154-contacts-section/spec.md), [155 notes section](../155-notes-section/spec.md), [160 file streams](../160-file-streams/spec.md), [186 multicast prompt](../186-multicast-prompt/spec.md), and [187 scheduled tasks & activities](../187-scheduled-tasks-activities/spec.md).

Measured baseline: `origin/master` `4ab7b731b` (2026-11-27).
Spec number **197**: `origin/master` ends at `196-topic-tags` (`git ls-tree --name-only origin/master csi-spl-doc/specs/ | sort -V | tail -n 3` -> `195-message-revoke`, `196-topic-tags`, `README.md`), and no `origin/review/*`, `origin/wip/*`, or sibling worktree holds a `197-*` folder.

### Panel Seats

| Seat | Agent | Vendor | Responsibility |
|---|---|---|---|
| Editor | `a-580` | agy | Owns spec text and branch; folds seat findings; compiles owner polls |
| User View | `c-582` | claude | Searching UX on desktop and phone, keyboard, preview/cycle/return, bulk actions, shared-link rights |
| Search Engine Expert | `a-583` | agy | Index & API: flat paged cross-kind list, `updated_at`, kind enum, sort, rights per object, prd cost/latency budget, full links |
| Reviewer | `c-584` | claude | Cross-vendor audit of each version against the owner's words and `origin/master`; PASS or FAIL with W/N |
| UI Design | `m-585` | mistral | Visual hierarchy, row layout, preview pane/sheet, selection bar, desktop & phone ergonomics |

---

## 0. The Owner's Words (HUM-10, `t1` `#spool-hub-ui`, topic `bcfd15e1-2022-473f-b4a9-ae34eb756f1e`, verbatim)

- msg `02c61f26` (07:52Z):
  > "we need to create the universal search use case e2e"
- msg `32ae406f` (07:55Z):
  > "I would like to be able to search for any object in the system so that the search results will go into a special search results page which will have the top bar and the left most sections panel , but only a listing with the found objects , sorted by last modified by default , but containing their type - topics msgs , card msgs , issues , calendar entries , lanes , events - basically anything which can be listed and accessed via a full link in the ui ... , the search should work so that one should be able t oquckli open and check the item - or even have a quick preview for it ( we could start building the quick preview meta data , while cycling between the items and bome back to the search results,  the search results should be shareable by links and the search results should be selectable and multiple actions applied to them , for example multicast prompt"
- msg `eacb7ad6` (08:0xZ):
  > "actually we need a panel of experts on how exactly this should work"
- msg `66276a6e` (08:0xZ):
  > "and this is the most important topic to work from now on in the spool hub workspace for today"
- msg `6a634a85` (08:1xZ):
  > "we should not remove the existing search use cses where the results are output into the left pane - as long as the whole universal search is not implemented properly .."
- msg `987e27de`:
  > "thus it should be triggered by not \"/s\" in the omnibox , but \"/us\" - aka universal search"
- msg `8f84b262`:
  > "and only after the universal search has been done so well that it is become a production grade feature , we will replace the current /s search with it"

### Hard Constraints (Non-Negotiable)

- **HC1 — Left-pane search stays untouched until owner replaces it.** The existing left-pane search (`SearchSidePanel.vue`, `/search?q=`, grouped hits, per-section "Load more", and `GET /v1/view/search`) stays working and unchanged while `/us` is built and hardened. Only an explicit owner decision retires it.
- **HC2 — New `/us` prefix only.** The universal search results page is opened by `/us` in the top-bar Omnibox (`/us <query>`, `/us:<query>`, bare `/us`). `/search:`, `/search ` and `/s ` keep opening today's left-pane search unchanged. `/us` replaces `/s` only later, on an explicit owner decision after `/us` meets the **Production-Grade Bar** (Section 5).

---

## 1. The Problem and What Exists Today (Measured on `origin/master` `4ab7b731b`)

Today, global search outputs grouped hits into a narrow left sidebar panel (`SearchSidePanel.vue`), optimised for quick jumps within channels and DMs. It does not provide a dedicated full-width results page where a user can search across every linkable object in the workspace in one chronological list, preview and cycle through hits rapidly, share a results URL with a teammate, or multi-select hits to run bulk actions such as Multicast prompt.

### 1.1 Verified Facts on `origin/master` (`4ab7b731b`)

1. **Omnibox command matching & `/us` collision:**
   - `git grep -n "SEARCH_CMD_RE\s*=" origin/master -- csi-spl-wui/src` -> `csi-spl-wui/src/utils/search.mjs:21`: `const SEARCH_CMD_RE = /^\/(?:search|s)(?::|\s|$)/i`.
   - `git grep -n "parseOmnibox\|search|s" origin/master -- csi-spl-wui/src/utils/feed.mjs` -> `:19`, `:21`: `const m = t.match(/^\/(?:search|s)(?::|\s|$)([\s\S]*)$/i)`.
   - `git grep -n "CHANNEL_LOOKUP_RE =" origin/master -- csi-spl-wui/src/utils/search.mjs` -> `:199` (`channelLookupOf` at `:208`).
   - **Impact:** Today `/us deploy` is treated as a plain message send (it posts a message), and a bare `/us` is treated by `channelLookupOf` as a lookup for a channel named `us`. Universal search MUST match `/us` before both `channelLookupOf` and plain send.
2. **Route & locale availability for `/us`:**
   - `ls csi-spl-wui/src/pages/u*` -> only `csi-spl-wui/src/pages/users.vue`.
   - `ls csi-spl-wui/i18n/locales/` -> 19 locale files (`bg`, `el`, `en`, `es`, `et`, `fi`, `he`, `lt`, `lv`, `mk`, `nl`, `pl`, `ro`, `ru`, `sk`, `sr`, `sv`, `tr`, `uk`); none is `us`.
   - **Impact:** `/us` (`pages/us.vue`, deep-linked as `/us?q=...`) has zero route or locale-prefix collisions.
3. **Shell layout (Top Bar + leftmost icon rail only):**
   - `csi-spl-wui/src/components/ChannelSidebar.vue:2` and `csi-spl-wui/src/composables/useSidebarRailOnly.ts:1-3,24,38` already implement rail-only pages (`.sidebar--rail`), where the top bar and leftmost vertical icon rail stay visible while the middle pane holds the full view (`/issues` without epics, `/calendar`, `/monitoring`, `/reporting`, `/notes`, `/expenses`, `/help`, `/workspace/docs`).
   - The page frame uses `.feed-col`, `.feed-header`, and `.feed-body` (`csi-spl-wui/src/assets/css/main.css:135,333,382`). Phone single-panel cutoff is `MOBILE_STACK_MAX_PX = 820` (`csi-spl-wui/src/utils/mobile-stack.mjs:21`).
4. **Existing left-pane search state, cycling & e2e suites:**
   - `csi-spl-wui/src/pages/search.vue`, `csi-spl-wui/src/components/SearchSidePanel.vue`, `csi-spl-wui/src/stores/search.ts:94-95` (`activeKey`, `scrollTop`), `csi-spl-wui/src/components/SideHitList.vue:166-182` (`ArrowDown`, `ArrowUp`, `Home`, `End`, `Enter`).
   - Existing `*search*` e2e and proof suites (`ls csi-spl-wui/tests/e2e | grep -i search`): `flow-search-acceptance.test.mjs`, `flow-search-live.proof.mjs`, `issue-parent-search.test.mjs`, `search-budget-message.test.mjs`, `search-channel-name.test.mjs`, `search-help-start.test.mjs`, `search-in-contacts.test.mjs`, `search-left.test.mjs`, `search-original-live.proof.mjs`, `search-original.test.mjs`, `search-type-calendar.test.mjs`, `section-search.test.mjs`, `top-bar-search.proof.mjs`.
5. **Searchable types & `updated_at` coverage today vs. the owner's list:**
   - `git grep -n "var Types =\|var DefaultTypes =" origin/master -- csi-spl-api/src/go/spool-hub-api/internal/search/grammar.go` (grammar `1.8`, `:24`):
     - `:77` (`Types`, 14 kinds): `message`, `topic`, `file`, `robot`, `user`, `channel`, `box`, `tenant`, `event`, `issue`, `doc`, `file_line`, `contact`, `calendar`.
     - `:87` (`DefaultTypes`, 9 kinds): `message`, `topic`, `file`, `robot`, `user`, `channel`, `box`, `doc`, `contact`.
   - **Gaps against owner msg `32ae406f`:**
     - **Card msgs vs. topic msgs:** Two-level message model (`csi-spl-doc/doc/help/index.md:48-50`): Level 1 (`is_parent = 1`, `:49`) are middle-pane **card messages** (topic openers) and Level 2 (`is_parent = 0`, `:50`) are **topic reply messages**. Both live in `messages` (`edited_at` added in `0026_message_revisions.sql:38`), but `searchMessagesSQL` (`internal/store/search_postgres.go:440`) merges both into `message` without distinguishing `is_parent` or using `COALESCE(edited_at, received_at)` as `updated_at`.
     - **Opt-in types today:** `issue` (`0047_issues.sql:67` `updated_at`), `calendar` (`0125_calendar.sql:36` `updated_at`, omitted from search JSON today and clipped to `[now-1y, now+1y]` at `internal/hub/search_calendar.go:32`), and `event` are absent from `DefaultTypes`.
     - **Events WUI linkability:** Verified `git grep -n "v1/view/events\|v1/operator/events" origin/master -- csi-spl-wui/src/ | wc -l` -> `0`; `csi-spl-wui/src/pages/monitoring/events/index.vue:6` reads ONLY `GET /api/v1/auth/events` (`human_events`, Mine log). `workspace_events` and `system_events` (`0240_workspace_system_events.sql:37,52`) have no WUI event view or deep link today, and their `id` sequences are separate from `human_events.event_id`.
     - **Missing types today:** **`lane`** (`git grep -n TypeLane origin/master -- csi-spl-api/src/ | wc -l` -> `0`; `fleet_lanes.updated_at` in `0096_fleet_lanes.sql:27`, deep-linked at `/monitoring/lanes?lane=<id@box>`, `csi-spl-wui/src/pages/monitoring/lanes/index.vue:34-36`) and personal **`note`** (`personal.notes.updated_at` in `0225_personal_notes.sql:37`, `/notes?note=<id>`, `csi-spl-wui/src/pages/notes.vue:8-9`, `internal/hub/realm_notes.go:521`).
     - **Contact & timeless roster timestamps:** `personal.contacts` has `updated_at` (`0226_contacts.sql:78`), omitted from search JSON today; `channel` has `last_ts`, `box` has `last_hello_at`, while `robot` and `user` have no modification timestamp (`updated_at: null`, sorted after dated hits).
6. **API contract gap (Phase 2 scope note):**
   - `csi-spl-doc/specs/003-spool-message-bus/contracts/search-v1.md:53-55`: `GET /v1/view/search` returns grouped sections (default 5 per section, max 20), `cursor` continues ONE section only, `sort` is `newest|relevance` (where `relevance` ranks messages only and every other type keeps its own order), and no total count is computed (avoids a second scan, `search-v1.md:261-262`).
   - **Impact:** One flat, paged, cross-kind listing sorted by `updated_at` is a **hub API contract change** (Phase 2 HOW — separate universal endpoint/mode so `GET /v1/view/search` and its 9-round-trip test `roundtrips_perf_test.go:126` stay untouched), not a WUI-only change.
7. **Rate limit & quick preview:**
   - `search-v1.md:445`: rate limit is **30 searches/min** per `(tenant, reader)`; time budget is **7 s** (`search-v1.md:446`). Quick preview while cycling results MUST NOT issue a search request per row.
   - `POST /v1/view/previews` (`internal/hub/view.go:60`, `internal/store/link_preview.go:26,30-36`, `PreviewBodyMax = 1200`) already fetches topic/message preview metadata in one batch under the reader's access door.
8. **Multicast & bulk selection neighbours:**
   - Spec 186 select-then-Multicast is already on `origin/master` (`git grep -l -i "multicast\|topicSelect" origin/master -- csi-spl-wui/src/ csi-spl-api/src/`): `csi-spl-wui/src/stores/topicSelect.ts` (`TopicPick`, `selectableCard`, `uniquePicks`, `TOPIC_SELECT_DEFAULT_ACTION = 'multicast'` at `:38`), `csi-spl-wui/src/components/MulticastDialog.vue`, `csi-spl-wui/src/components/TopicSelectBar.vue`, `csi-spl-api/src/go/spool-hub-api/internal/hub/wui_multicast.go`.
   - Bulk selection bars exist for Issues (`csi-spl-wui/src/components/IssuesBulkBar.vue`) and Events (`csi-spl-wui/src/components/EventsBulkBar.vue`).
   - Full-link resolution exists in `searchTarget()` (`csi-spl-wui/src/utils/search-results.mjs:238`), `originalHref()` (`:359`), `parentSection()` (`csi-spl-wui/src/utils/parent-section.mjs:133-134`), and detail routes `pages/m/[id].vue`, `pages/monitoring/agents/[id].vue`, `pages/monitoring/boxes/[id].vue`, `pages/people/[id].vue`.
9. **Help wording collision:**
   - `csi-spl-doc/doc/help/index.md:52` and `csi-spl-wui/src/public/help-md/index.md:48` already label the `/search` / `/s` bullet **"Universal Search & Filters"**. When `/us` ships, the docs must distinguish the two clearly so users never confuse `/s` (left-pane quick search) with `/us` (Universal Search results page).

---

## 2. Users and Jobs to Be Done

| User | Situation | Goal |
|---|---|---|
| Workspace member (desktop `1440×900` or phone `390×844`) | Knows a word, key, person, or timeframe, not which section holds the object | Type `/us <query>` once, scan one newest-first list across every object kind, preview or jump straight to the right item, and come back without losing place |
| Power user / operator | Reviewing many matching topics, messages, issues, or lanes | Cycle through hits with keyboard (`ArrowDown`, `Space`, `Enter`, `[`/`]`), tick matching topics across channels, and fire one **Multicast prompt** to all of them |
| Teammate receiving a shared link | Clicks a `/us?q=...` link pasted in a topic or DM | Lands on the exact same search, sort, and filters, seeing only objects their own workspace permissions allow — zero leakage of restricted items |
| Workspace owner / admin | Auditing lanes, events, or file streams alongside discussions and issues | Finds restricted objects (`lane`, `file_line`, `event`) in the same universal search under existing role gates |

---

## 3. What Users See and Do (Phase 1 — WHAT)

Proposals not explicitly stated in the owner's words are marked **[Proposal]** and paired with owner poll questions in Section 7 where appropriate.

### 3.1 Entry and Coexistence (`FR-US-01` – `FR-US-03`)

- **FR-US-01 (`/us` prefix in Omnibox).** The top-bar Omnibox recognises `/us <query>`, `/us:<query>`, and a bare `/us` (case-insensitive, `/^\/us(?::|\s|$)/i`) **before** `channelLookupOf` and **before** plain message send:
  - `/us <query>` or `/us:<query>` + Enter navigates to `/us?q=<query>` and **never posts a message**.
  - A bare `/us` + Enter navigates to `/us` (empty query with help and examples) and **never looks up a channel named `us`**.
  - While the line starts with `/us`, the Omnibox enters *universal search mode*: mode chip reads **Universal Search**, Submit button reads **Search**, `@`-mention autocomplete is off, and server-driven operator autocomplete (`GET /v1/view/search/operators`) works identically to `/search`.
  - While on `/us?q=<query>`, the Omnibox displays `/us <query>` ready to refine; leaving `/us` clears a `/us …` line (matching `omniboxTextLeavingSearch` in `search.mjs:250`) while preserving any non-search draft.
- **FR-US-02 (Coexistence — HC1 & HC2).** `/search:`, `/search `, `/s `, `/search?q=`, `SearchSidePanel.vue`, and `GET /v1/view/search` remain 100% unchanged and continue opening today's left-pane grouped search. Nothing removes or degrades them.
- **FR-US-03 (Help disambiguation).** When `/us` ships, the `/us` WUI build row updates `csi-spl-doc/doc/help/index.md:52` and `csi-spl-wui/src/public/help-md/index.md:48` to rename the existing `/s` bullet to **Quick Search & Filters (`/s`, `/search`)** and add **Universal Search Results (`/us`)**, so the two entry points cannot be confused.

### 3.2 Page Shell and Layout (`FR-US-04` – `FR-US-05`)

- **FR-US-04 (Desktop shell).** `/us` renders inside `layouts/default.vue` with:
  1. The persistent **Top Bar** (with the Omnibox).
  2. The **leftmost sections icon rail only** (`.sidebar--rail`, desktop only via `useSidebarRailOnly.ts:1-3,24,38`) — no channel/DM/search list panel beside the rail, matching the owner's *"top bar and the left most sections panel , but only a listing with the found objects"* (agreed by `c-582` R1 and `c-584` N6; note to `m-585`: panel 1's channel/DM list is hidden here rather than kept open, and on a phone the sections are the usual section strip (`useSidebarRailOnly.ts:31`, as on `/notes` at `:24`).
  3. The **main results column** (`.feed-col` with `.feed-header` and `.feed-body`, `main.css:135,333,382`) holding ONLY the search header (title, query chip, Refresh, Sort, Copy Link — replaced by the Selection Bar while rows are ticked), optional kind chips, and the single flat listing of found objects.
  4. An optional **right-side Quick Preview pane** (the right topic-pane slot with `PaneDivider` resizer) that opens only when the user invokes preview (`FR-US-12`), and closes cleanly back to the full-width listing.

```text
+-------------------------------------------------------------------+
| TopBar: [logo] [tenant] [theme] [Omnibox: /us deploy     ] [user] |
+----+-------------------------------------------+------------------+
| R  | Universal search `deploy`  [Refresh] [Sort v] [Copy link]    |
| A  | [All] [Topics] [Cards] [Messages] [Issues] [Calendar] ...    |
| I  |-------------------------------------------| Quick Preview    |
| L  | [ ] [icon Topic] Title match  #lobby  2m  | [<] 3 of 30+ [>] |
|    | [ ] [icon Issue] SPL-123 ...  SPL-10 14m  | Kind · Title     |
|    | [ ] [icon Cal  ] Review ...   11-28   1h  | Where · Who · At |
|    | ...                                       | Snippet / fields |
|    | [Load more]                               | [Open full link] |
+----+-------------------------------------------+------------------+
```

- **FR-US-05 (Phone shell, `<= 820px` `MOBILE_STACK_MAX_PX`, verified at `390×844`).** The Top Bar stays (following SPL-4264 strip behaviour); level 1 is the standard phone section strip/drawer (`ChannelSidebar`), level 2 is `/us` full width with `MobileBack` in `.feed-header`, 44 px tap targets, and **zero horizontal overflow**. Quick Preview opens as a bottom sheet.

### 3.3 Searchable Object Kinds, `updated_at`, and Full Links (`FR-US-06`)

Every object in the workspace included in v1 is represented with a stable **kind**, a human-readable badge (`UiIcon` + localised word), a **canonical full link**, an **access gate**, and a **`last_modified` (`updated_at`) timestamp** used for the default sort (`updated_at DESC NULLS LAST`).

**Topic vs. Card Message deduplication [Proposal]:** `topic` = the topic (title match, or any message of the topic when filtered to `type:topic`); `card_msg` = a Level 1 opener message (`is_parent = 1`, `help/index.md:49`) whose body matched; `topic_msg` = a Level 2 reply (`is_parent = 0`, `help/index.md:50`) whose body matched. When the same topic matches both as `topic` (title) and as its own `card_msg` (root body), the flat list shows **ONE** row (the `topic` row carrying the body snippet) so the same card is never duplicated.

| Kind (display label) | Default or opt-in in plain `/us <q>` | `updated_at` source | Canonical full link in UI | Access gate (unchanged from each feature) |
|---|---|---|---|---|
| **Topic** (`topic`) | Default | `max(GREATEST(received_at, COALESCE(edited_at, received_at)))` | `/channel/<ch>?topic=<task_id>` (DM/fallback: `/t/<task_id>`; `issues` channel: `/issues?issue=<KEY>` or `/t/<task_id>`, never `/channel/issues`, `parent-section.mjs:133-134`) | Workspace member + channel read ACL / DM party + retention (`expires_at > now`, `loop_id IS NULL`), archive, relay, demo moderation (`mod.keepResults`), and box locks (`lockKeepResults`) |
| **Card message** (`card_msg`, Level 1 `is_parent=1`; Q4) | Default | `COALESCE(edited_at, received_at)` | `/m/<msg_id>` (opens in original channel/DM, scrolled & marked) | Same as Topic |
| **Topic message** (`topic_msg`, Level 2 `is_parent=0`; Q4) | Default | `COALESCE(edited_at, received_at)` | `/m/<msg_id>` (opens thread in original channel/DM, scrolled & marked) | Same as Topic |
| **Issue** (`issue`) | Default | `issues.updated_at` (`0047_issues.sql:67`) | `/issues?issue=<KEY>` | Workspace member (`topics.read`); excludes deleted/archived |
| **Calendar entry** (`calendar`) | Default (all non-deleted entries; not clipped to `±1y` when sorted by `updated_at`) | `calendar_events.updated_at` (`0125_calendar.sql:36`; Q7; `starts_at` shown in row) | `/calendar?d=<YYYY-MM-DD>&event=<id>` (UTC start day) | Calendar read door (private entries only for creator & named people; deleted never; demo visitor workspace/public only) |
| **Lane** (`lane`, new; active live + queued lanes matching `/monitoring/lanes`, excluding pruned/`done` rows whose deep link has no row, `0096_fleet_lanes.sql:12-14`, `fleet_lanes_view.go:204-211`) | Default for authorised staff; omitted silently for others | `fleet_lanes.updated_at` (`0096_fleet_lanes.sql:27`) | `/monitoring/lanes?lane=<id@box>` (or `<id>` when box withheld) | Operator admin/PO (fleet) or workspace owner/admin (workspace lanes only, operator box & issue key stripped); non-staff gets 0 rows (never 403) |
| **Event** (`event`) | Default | `human_events.received_at` (Workspace/System `at` only if Q5 = `ALL`) | Mine: `/monitoring/events#<event_id>` (Workspace/System deep links or preview-only per Q5) | Mine = viewer's own `human_id` only; Workspace = owner/admin; System = operator admin (Q5) |
| **File / Attachment** (`file`) | Default | carrying message `received_at` | `/m/<msg_id>` (carrying message) | Same as Topic |
| **Workspace Doc (Qto)** (`doc`) | Default | `workspace_doc_item.updated_at` | `/workspace/docs?doc=<doc_id>&view=doc[#ws-doc-<item_id>]` | Signed-in member with `docs.read` + restricted doc lock; never system repo docs |
| **Contact** (`contact`) | Default (when contacts kill-switch is on) | `personal.contacts.updated_at` (`0226_contacts.sql:78`) | `/people/contact/<id>` | Reader's own personal contacts only (no act-as / box / agent seat) |
| **Note** (`note`, new; **[Proposal, Q6]**) | Per Q6 | `personal.notes.updated_at` (`0225_personal_notes.sql:37`) | `/notes?note=<id>` | Reader's own personal realm notes only (where Notes enabled) |
| **Channel** (`channel`) | Default | `last_ts` (nullable) | `/channel/<slug>` | Visible channels only (`!Hides`) |
| **Person / User** (`user`) | Default | `null` (timeless; sorted after dated hits) | `/people/<HUM-n>` (note: `/search` links `/dm/<HUM-n>`) | Active workspace members only (no disabled/technical/guest); **email never searched or returned** |
| **Agent / Robot** (`robot`) | Default | `null` (timeless; sorted after dated hits) | `/monitoring/agents/<id>@<box>` (note: `/search` links `/dm/<id>@<box>`) | Workspace roster + box lock filter |
| **Box** (`box`) | Default | `last_hello_at` (nullable) | `/monitoring/boxes/<box_id>` | Workspace boxes + box lock filter |
| **File stream line** (`file_line`) | **Opt-in** (`type:file_line` or `in:file-streams`; high-noise 500k+ lines) | line `at` | `/monitoring/file-streams?box=<box>&stream=<stream>&seq=<seq>` | Workspace owner/admin only (no act-as); notice `file_streams_staff_only` otherwise |
| **Workspace / Tenant** (`tenant`) | **Opt-in** (`type:tenant`; no in-workspace full link) | `null` | Workspace host switch | Reader's own memberships only |

### 3.3b Linkable UI Objects Not Included in v1 (Verified on `origin/master` `4ab7b731b`)

Audited via `git ls-tree -r --name-only origin/master csi-spl-wui/src/pages`. To avoid silently narrowing the owner's *"basically anything which can be listed and accessed via a full link in the ui"*, every other object-like route is accounted for below and paired with owner poll **Q8**:

| Page / Feature | Full link | Status / Reason deferred past v1 |
|---|---|---|
| Goals (`pages/goals/[id].vue`) | `/goals/<id>` | Not in `search-v1`; candidate for Wave 2 (or v1 if owner selects `V1` in Q8) |
| Release notes (`pages/releases/[ref].vue`) | `/releases/<ref>` | Not in `search-v1`; candidate for Wave 2 (or v1 if owner selects `V1` in Q8) |
| Help pages (`pages/help/[[page]].vue`) | `/help/<page>` | Static bundled help markdown, not tenant workspace data; Wave 2 candidate |
| Public blog (`pages/blog.vue`) & Roadmap (`pages/roadmap.vue`) | `/blog`, `/roadmap` | Public marketing/static content, not tenant workspace objects |
| Expenses (`pages/expenses/[[tab]].vue`) & Reporting (`pages/reporting/**`) | `/expenses/<tab>`, `/reporting/...` | Aggregate dashboards/tabs rather than individual searchable records |
| Archive (`pages/archive.vue`) | `/archive` | Archived topics/notes/issues are deliberately excluded from active search unless explicitly requested |
| Monitoring Topics (`pages/monitoring/topics/index.vue`) | `/monitoring/topics` | Alternate table view of topics already indexed as `topic` in 3.3 |
| Scheduled tasks & activities (spec 187) | Not built yet (`187-scheduled-tasks-activities/spec.md:7`: *"Nothing below is built"*) | No tables or UI pages exist on `origin/master`; add when spec 187 lands |

### 3.4 Row Anatomy, Sorting, Filtering, and Paging (`FR-US-07` – `FR-US-10`)

- **FR-US-07 (Row anatomy).** Every hit renders in one flat list. Left to right on desktop (compact row; two lines on phone with 44 px touch targets: line 1 = kind + title, line 2 = where + who + when):
  1. **Selection tick box:** always visible on desktop (on a phone, it shows after a long press). Focus stays on the row (roving `tabindex`): `Space` on the row previews and `x` ticks. The tick box is clickable and is announced with the row (`aria-checked`); a `Tab` that lands on the tick box itself makes `Space` tick, as everywhere else.
  2. **Kind badge:** `UiIcon` + localised kind word (`Topic`, `Card`, `Message`, `Issue`, `Calendar`, `Lane`, `Event`, `File`, `Doc`, `Note`, `Contact`, `Channel`, `Person`, `Agent`, `Box`, `File line`).
  3. **Title & match highlight:** topic title, `KEY + title` for issues, entry title + start day for calendar, agent/scope summary for lane, first line / snippet for messages & cards — with match ranges wrapped in `<mark>` as escaped **text nodes** (never server HTML, `search-v1.md` §4).
  4. **Where it lives:** channel (`#slug`) or DM peer, issue epic, calendar day, box id.
  5. **Who** last modified/authored it (display name / agent id, omitted where a kind has no actor).
  6. **When** it was last modified: relative time (e.g., `12m ago`, `3d ago`), with exact timestamp in the reader's time zone on hover (`how-to-post.md` §4).
  7. **Quick Preview button** (eye icon) and **Open** (row click / Enter).
- **FR-US-08 (Sorting).**
  - **Default:** `Last modified (newest first)` (`updated_at DESC NULLS LAST, kind ASC, id DESC`), per owner `32ae406f`.
  - **Other sort options** from a Sort control in the page header **[Proposal]**: `Oldest first` (`updated_at ASC NULLS LAST`) and `Relevance` (**[Proposal, new cross-kind ranking]** — exact key/title match > FTS `ts_rank_cd` / substring tier > `updated_at DESC` tie-break; `search-v1.md:54` ranks messages only today). Grouped-by-kind sort is omitted from v1 because kind filter chips (`FR-US-09`) narrow by kind without starving later kinds behind pages of an earlier kind.
  - Active non-default sort is written to the URL (`&sort=...`), so reload and shared links preserve the order.
- **FR-US-09 (Kind filter chips) [Proposal, Q3].**
  - A compact row of kind chips above the list (`All`, `Topics`, `Cards`, `Messages`, `Issues`, `Calendar`, `Lanes`, `Events`, …); counts shown only if cheap/provided (no forced second table scan).
  - Clicking a kind chip updates `&type=` and stays synced with any top-level `type:` term in the Omnibox (never producing contradictory `?q=type:issue+deploy&type=calendar` URLs).
- **FR-US-10 (Paging).**
  - Loads **30 rows** per page (owner's page size from `search-v1.md:53`) with an opaque cross-kind cursor so paging never duplicates or skips rows across kinds, loading the next 30 on scrolling near the bottom **plus** an explicit **Load more** button (for keyboard users, screen readers, and deterministic e2e tests).
  - Loading another page never jumps scroll back to the top.
  - Consistent with `search-v1.md:261-262`, no expensive total-count scan is required; the UI displays `N` loaded (or `N+` while `has_more` is true).

### 3.5 Open, Quick Preview, Cycle, and Return (`FR-US-11` – `FR-US-13`)

- **FR-US-11 (Open, cycle, & return with full state).**
  - Each row's title is a real link (`<a href>` = the hit's canonical full link from `FR-US-06`). `Ctrl/Cmd+click`, middle-click, and the row menu's "Open in new tab" (desktop right-click / `ContextMenu` / `Shift+F10`) open it in a new tab; the new tab shows the item alone (with no results strip), and the `/us` tab keeps its place.
  - Plain click, tap, or `Enter` opens the hit in the current tab at its canonical full link (reusing `openMessage()` / `searchTarget()`).
  - While viewing an item opened from `/us`, a slim **Results navigation strip** at the top of the view shows `k of N` (or `k of N+` when `has_more` is true), **Previous**, **Next**, and **Back to results**.
  - `[` and `]` (or `Alt+ArrowUp` / `Alt+ArrowDown`) step directly to the previous/next hit in the result list without returning to `/us` first (stepping past the last loaded hit fetches the next page when `has_more` is true). Single-key shortcuts (`[`, `]`, `x`, `/`, `Space`, `Esc`) act ONLY while focus is not in a text field, a `contenteditable`, or an open dialog; in the composer they type as usual.
  - Clicking **Back to results**, pressing `Esc` (outside inputs/dialogs), or pressing browser **Back** returns to `/us?...` with the exact query, sort, kind filters, loaded pages, selection state, and scroll position restored, with the last-viewed row visibly marked active.
  - A hit that was deleted, or the reader lost access to it, after the list loaded opens the item page's usual not-found or no-access state (`OpenMessageToast` "This message is gone or not yours to see" or the route's not-found view). The strip stays, so Previous, Next, and Back to results still work.
  - The list is the answer to the query as it ran. It never re-sorts or inserts rows under the reader while they cycle. A **Refresh** button in the header re-runs the query, and reloading the page does too.
- **FR-US-12 (Quick Preview without leaving `/us`).**
  - Desktop: pressing `Space` on the active row or clicking its eye button opens a **right-side Quick Preview pane** beside the listing. Pressing `ArrowUp` / `ArrowDown` (or `[` / `]`) moves the active row (scrolling it into view) and updates the preview live; pressing `Enter` or clicking **Open** in the preview opens the full link.
  - Phone: tapping the eye button opens a **bottom sheet** preview; swipe down closes, and Previous/Next controls (plus swipe left/right) cycle adjacent hits.
  - **Incremental preview metadata (owner: *"we could start building the quick preview meta data"*):**
    - Baseline (every kind, Day 1): lightweight `preview` metadata carried in the hit payload (kind badge, full title, location, actor, last modified time, matched snippet, and **Open** button) so preview renders instantaneously with **zero** extra round trips.
    - Rich metadata expanded kind-by-kind: Topics & Messages (first lines, reply count, file count, channel/DM context — reusing `POST /v1/view/previews` on demand if expanded), Issues (key, status, priority, assignee, epic, description excerpt), Calendar entries (start/end time, all-day flag, location, audience, description excerpt), Lanes (agent, box, state, linked topic/issue), Events (status, method/path, error code, message).
- **FR-US-13 (Preview rate-limit invariant).** Cycling Quick Preview across rows MUST NOT trigger `/v1/view/search` or universal-search calls (must not burn the 30/min search budget of `search-v1.md:445`).

### 3.6 Keyboard (Desktop) and Touch (Phone) (`FR-US-14` – `FR-US-15`)

- **FR-US-14 (Desktop keyboard).** Single-key shortcuts (`[`, `]`, `x`, `/`, `Space`, `Esc`) act ONLY while focus is not in a text field, a `contenteditable`, or an open dialog; in the composer they type as usual.
  - `Tab`: skip-link is the first stop (`layouts/default.vue`, FR-007).
  - `ArrowDown` in the Omnibox (universal search mode): hands focus to the results list (`omnibox.focusResults`).
  - `ArrowDown` / `ArrowUp`: move cursor row (and update Quick Preview if open).
  - `Home` / `End`: jump to first / last loaded row.
  - `Enter`: open active row at its full link.
  - `Space`: toggle Quick Preview pane for active row (unless focus is explicitly on the tick box itself, `FR-US-07`).
  - `x`: toggle selection tick box on active row.
  - `Shift+ArrowDown` / `Shift+ArrowUp` (and `Shift+click`): extend selection range (`rangeSelect`).
  - `Ctrl+A` / `Cmd+A` (when list has focus): select all loaded rows.
  - `ContextMenu` / `Shift+F10`: open row context menu (Open, Quick preview, Copy link).
  - `Esc`: first clears selection (if any); second closes Quick Preview (if open).
  - `/`: focuses the Omnibox with the current `/us <query>` ready to edit.
  - **No keyboard-only actions:** every action above has a visible clickable button/control.
- **FR-US-15 (Phone touch, `390×844`).**
  - Tap on row opens the hit; tap on eye icon opens bottom-sheet preview.
  - A long press on a `/us` row ticks the row and enters selection mode (unlike topic cards in spec 186 §4.6, `186-multicast-prompt/spec.md:528-530`, where long-press opens the card menu whose first item is "Select", a `/us` row has no card menu). While selection mode is active, tapping any row toggles its tick.
  - Selection bar replaces the header in one 44 px row of icon buttons (`aria-label` + `title`), keeping **Multicast** reachable on screen at `390 px` with zero horizontal overflow.
  - On an item opened from `/us`, the results strip is one 44 px row of icon buttons (`aria-label` + `title`): Back to results, Previous, `k of N`, Next. It has no horizontal overflow at `390 px`, and it never covers the item's own header or the composer dock.

### 3.7 Selection and Bulk Actions (`FR-US-16` – `FR-US-17`)

- **FR-US-16 (Multi-select, selection lifetime & Universal Selection Bar).**
  - Ticking one or more rows replaces the list header with the **Selection Bar** (modeled on `IssuesBulkBar.vue` and `TopicSelectBar.vue`):
    - Master page checkbox (`none` / `indeterminate` / `all` of loaded rows).
    - Live breakdown count by kind (e.g., `12 selected: 9 topics, 3 issues`).
    - Applicable bulk action buttons (Multicast first, `TOPIC_SELECT_DEFAULT_ACTION = 'multicast'`) and **Clear**.
  - **Selection lifetime:** The ticks belong to one result list. A change of sort or kind chip keeps them, and the bar counts any ticked rows the list no longer shows (`3 selected, 1 not shown`). A new query clears them; if more than one row is ticked, the reader confirms first. Opening an item and coming back keeps them (`FR-US-11`). A workspace switch or page reload empties them; they are never stored on the hub (matching `stores/topicSelect.ts`, spec 186 §7.1.6).
  - **Mixed-kind honesty:** If a bulk action applies to only a subset of the selected kinds, the bar/dialog explicitly states what is included and what is skipped before execution (e.g., `Multicast to 9 topics; 3 issues skipped`). If zero selected items qualify, the button is disabled with a tooltip explaining why.
- **FR-US-17 (v1 flagship bulk action — Multicast prompt).**
  - Selecting hits and clicking **Multicast** resolves every eligible hit to its target channel topic (`task_id`), de-duplicated:
    - A `topic` hit in a non-`issues` channel -> its `task_id`.
    - A `card_msg`, `topic_msg`, or `file` hit in a non-`issues` channel -> its carrying topic's `task_id` (added once even if multiple messages from the same topic were ticked).
    - DMs, `issues`-channel discussions, issues, calendar entries, lanes, events, docs, contacts, notes, channels, users, agents, and boxes are **not** multicast targets (per spec 186 Q2 `EX`, Q8 `CHN`, R1) and are reported as skipped.
  - Eligible targets populate `stores/topicSelect.ts` (`TopicPick[]`, de-duplicated via `uniquePicks`) and open the existing `MulticastDialog.vue` (spec 186 M11), where the author sees the exact target topics grouped by channel, confirms/edits the list, writes one prompt (with optional files), and sends.
  - Additional bulk actions (Copy links, Open in tabs, Export CSV, Bulk issue status, Add to note) are deferred past v1 unless selected by owner poll (`Q2`).

### 3.8 Shareable Links and Rights (`FR-US-18`)

- **FR-US-18 (Shareable URL & access control).**
  - The URL `/us?q=<query>[&sort=<sort>][&type=<kinds>]` is the canonical shareable link (a Copy Link button in the page header copies it via `useCopyText`).
  - **Live evaluation under the opener's own rights** (recommended; owner poll `Q1`): opening a shared link carries ONLY query/filter/sort state (never hit payloads or tokens) and re-runs the query as the opener under the opener's own session, workspace membership, channel ACLs, DM-party checks, box locks, moderation, personal realm ownership (notes, contacts, events), and role gates (lanes, file streams, docs).
  - **Zero existence leakage:** Hits the opener may not read are silently omitted. The UI NEVER displays `"N hidden results"` or hints that inaccessible objects matched.
  - **Signed-out opener:** Redirected to sign-in, then returned straight to the full `/us?...` URL.
  - **Cross-workspace link:** Opens in that workspace only if the opener is a member of it; otherwise shows the standard no-access page.
  - Active row selection is NEVER encoded in the URL.

### 3.9 Empty, Loading, Partial, and Error States (`FR-US-19`)

- **Empty `/us` (no query):** Shows concise `/us` usage help, clickable example queries, and the server-sourced operator list.
- **Loading:** Announces `Searching...` (`aria-live="polite"`); while refining an existing query, prior rows stay dimmed until replaced.
- **Zero hits:** Shows `Nothing found for "<query>"` plus up to three actionable tips (try shorter words, clear a `type:` or date filter, check spelling).
- **Bad query (`400 bad_query`):** Displays the hub's error detail and highlights the offending token at its UTF-16 offset (`search-v1.md` §5.1) above the list.
- **Rate limit / Timeout / Offline (`429` with `Retry-After` seconds, `503 search_budget` 7 s, network failure):** Displays one plain sentence and a **Retry** button (`LazySearchErrorNotice` pattern); status/token/reference appear only when the Debug pane is enabled.
- **Partial source failure:** If one backend source times out or fails while others succeed, renders the hits that arrived plus a non-blocking notice naming the source that could not be searched with a **Retry** action. A source omitted by role, feature kill-switch, or access gating (e.g., `lane` for non-staff) is never a partial failure; notices fire only on real timeouts or errors for sources the caller is authorised to search.
- **Warnings and notices:** Displayed above the list just as on `/search` today (unknown operators searched as text; `file_streams_staff_only`, etc.).

---

## 4. Out of Scope (v1)

- Removing, hiding, or modifying `/s`, `/search`, `/search?q=`, `SearchSidePanel.vue`, or `GET /v1/view/search` (**HC1 & HC2**).
- Automatically switching `/s` to open `/us` (requires explicit owner Go after Section 5 is met).
- Cross-workspace / federated multi-tenant search in a single list (search stays strictly single-workspace and RLS-isolated, per `search-v1.md` §0 & §8).
- Semantic / vector search, external search engines, or indexing inside binary file contents (`search-v1.md` §8, spec 100 §3.2 — stays inside Postgres with 0 sync lag and ~$0 extra infra).
- Linkable routes accounted for in Section 3.3b (`goals`, `releases`, `help`, `blog`, `roadmap`, `expenses`, `reporting`, `archive`, spec 187 scheduled tasks) unless promoted by owner poll **Q8**.
- Saved searches, scheduled search alerts, or frozen/shared snapshot tables (unless owner chooses `FRZ` in Q1).
- Bulk actions other than Multicast prompt in v1 (Copy links, Open in tabs, Export CSV, Bulk issue status, Add to note — deferred unless owner chooses `ALL` in Q2).

---

## 5. Production-Grade Bar (Gate to Replace `/s` with `/us`)

Per owner msg `8f84b262`, `/us` replaces `/s` **only after** all six gates below are verified true and the owner gives explicit **Go**:

1. **Object completeness & accuracy:** Every v1 object kind in `FR-US-06` is searchable, carries an accurate `updated_at`, opens its verified canonical full link, and passes automated access-control tests (cross-tenant isolation, non-member channel hiding, DM-party privacy, personal-realm isolation, role-gated lanes/file-streams/docs, zero existence leakage).
2. **Performance & cost budget:** Flat cross-kind paging meets the prd latency, round-trip (target `<= 6–8` DB round trips via batched reads, unmeasured today; exact budget measured and pinned in Phase 2 HOW), and buffer budget (inside Postgres, well under the 7 s hard ceiling; preview cycling costs 0 search quota).
3. **E2E, hub, & live acceptance green:** All three verification layers of Section 6 — **(M)** mock WUI e2e, **(H)** hub Postgres tests, and **(L)** dev live proof — pass green on desktop (`1440×900`) and phone (`390×844`), light and dark themes, zero page errors, zero horizontal overflow.
4. **Live on dev and prd:** All build rows landed on `origin/master` and verified served on both `dev` and `prd` (`do_check_deploy_lag` clean).
5. **Zero regression on existing search:** Every `*search*` e2e and proof suite under `csi-spl-wui/tests/e2e/` (`flow-search-acceptance`, `flow-search-live.proof`, `issue-parent-search`, `search-budget-message`, `search-channel-name`, `search-help-start`, `search-in-contacts`, `search-left`, `search-original-live.proof`, `search-original`, `search-type-calendar`, `section-search`, `top-bar-search.proof`) and `TestRoundTripsPerRequest` remain green.
6. **Owner sign-off:** 14 days of live owner use on prd with zero open P1/P2 search defects, followed by an explicit owner `(GO)` poll approving the `/s` cutover.

---

## 6. Acceptance — Universal Search Use-Case Verification

Modeled on `csi-spl-wui/tests/e2e/flow-search-acceptance.test.mjs`, acceptance is proven across **three complementary layers** (because a mock WUI suite alone cannot prove real Postgres cross-kind cursors, second-member ACL isolation, or real sign-in redirects):

- **(M) Mock WUI E2E** (`csi-spl-wui/tests/e2e/universal-search-acceptance.test.mjs`): steps 1–6, step 7 up to `MulticastDialog.vue` displaying the 2 de-duplicated target topics, steps 10–11, desktop (`1440×900`) and phone (`390×844`), light & dark themes, zero page errors, zero horizontal overflow. Mock data (`utils/mock-data.mjs`) gains at least one hit of every default kind in Section 3.3.
- **(H) Hub Postgres Tests** (exact file named in Phase 2 HOW): flat `updated_at DESC` ordering across kinds (including `COALESCE(edited_at, received_at)`), opaque cross-kind cursor paging (zero duplicates or skips across pages), every access gate in Section 3.3 with a red control, and step 8's zero leakage (hidden hit absent, no hidden count).
- **(L) Live Proof on Dev** (`csi-spl-wui/tests/e2e/universal-search-live.proof.mjs`, like `top-bar-search.proof.mjs` and `flow-search-live.proof.mjs`): steps 1, 7 (actual multicast send delivered to both topics), and 8–9 with two real members and a signed-out session.

### Scenarios

1. **Entry & non-post safety `(M, L)`:** Signed in on desktop (`1440×900`) in `#lobby`, type `/us deploy` in the Omnibox and press Enter -> navigates to `/us?q=deploy`, posts **nothing** to `#lobby`. Typing bare `/us` + Enter opens `/us` help and does **not** look up channel `us`.
2. **Layout & flat chronological listing `(M, H)`:** Signed in as the workspace owner/admin (so `lane` rows are in scope), top bar and leftmost icon rail only (`.sidebar--rail`, no secondary sidebar list); middle shows ONE flat list containing mixed kinds (at minimum: topic, card message, topic reply message, issue, calendar entry, lane, event), sorted newest `updated_at` first; an edited card/topic message ranks above a newer-created unedited message (proving `COALESCE(edited_at, received_at)`); clicking **Load more** across mixed kinds appends zero duplicates in monotonic `updated_at DESC` order; each row displays kind badge, title/highlighted snippet, location, actor, and time.
3. **Coexistence — HC1 & HC2 `(M)`:** Typing `/s deploy` still opens `/search?q=deploy` with `SearchSidePanel.vue` unchanged; every existing `*search*` suite stays green.
4. **Quick Preview & keyboard cycling `(M)`:** Press `ArrowDown` twice, press `Space` -> right-side Quick Preview pane opens for row 3; press `ArrowDown` -> preview updates to row 4 with **zero** extra search requests. Typing `[`, `]`, `x`, `/`, or `Space` inside a composer input types characters normally and never triggers list shortcuts.
5. **Open, item-to-item cycling, and return with state `(M)`:** Press `Enter` on row 4 -> opens item at its canonical full link; top strip shows `4 of N` (or `4 of N+`); press `]` -> steps directly to row 5; click **Back to results** (or browser Back) -> returns to `/us?q=deploy` with loaded pages, scroll position, and row 5 marked active. `Ctrl/Cmd+click` on a row title opens the item in a new tab with no results strip.
6. **Sorting & URL persistence `(M)`:** Switch sort to `Oldest first` -> URL updates with `sort=`; full page reload preserves the exact reversed order.
7. **Multi-select & Multicast bulk action `(M, L)`:** Tick two channel-topic hits (or a topic + a message in a second topic) and one issue hit -> Selection Bar shows `3 selected: 2 topics, 1 issue`; clicking **Multicast** explicitly notes `2 topics; 1 issue skipped`, opens `MulticastDialog.vue` pre-populated with those 2 de-duplicated topics `(M)`; sending posts the prompt to both topics `(L)`.
8. **Shareable link & zero existence leakage `(H, L)`:** Copy `/us?q=deploy...` link; open as a second member who lacks access to one private channel/DM topic -> that hit is completely absent, zero "hidden" count or hint appears, remaining permitted hits display normally; and, signed in as a plain member, no `lane` row appears and nothing hints at one.
9. **Signed-out link flow `(L)`:** Open the shared `/us?q=deploy` link while signed out -> redirects to sign-in -> after sign-in, lands directly on `/us?q=deploy` with results.
10. **Phone `390×844` `(M)`:** Steps 1, 2, 4 (bottom-sheet preview), 5 (open with single 44 px results strip & Back restores scroll), and 7 (long-press to enter selection, Multicast button visible on screen) all pass with **zero horizontal overflow**.
11. **Empty, error, and partial states `(M)`:** `/us zzqqxx` shows empty state + tips; `/us before:notadate` shows `400 bad_query` token highlight pointer; simulated search failure shows plain error + Retry (and `429` shows `Retry-After`).

---

## 7. Open Questions for the Owner (Poll Forms)

Per `csi-spl-doc/doc/help/how-to-post.md:423` ("One form per message. A second `poll` block in the same post stays a code block") and §7 item 7 (highest-priority question first), the dispatch holder posts either one multi-question form or one message per poll. **Status:** Q1–Q7 were posted to HUM-10 by the dispatch holder (`c-002`) as one 7-question form (`msg:a3d8e5fc`, Q1 first; do not re-send Q1–Q7). **Q8** is new from round-1 review (`c-584` W3) and is sent to the dispatch holder separately, along with a factual update on **Q5** (`a-583` S3).

### Q1 — Shared results link behaviour *(posted in `a3d8e5fc`)*

Recommended: **LIV** (matches `/search?q=`, requires no stored snapshot table, and guarantees zero existence leakage when rights change).

```poll
When someone opens a shared /us results link, what should they see?
(LIV) The same query run live under their own current rights (Recommended)
(FRZ) The sharer's saved list as it was, stored on the hub; items the opener may not read are hidden
```

### Q2 — Bulk actions in v1 *(posted in `a3d8e5fc`)*

Recommended: **MCF** (ships Multicast prompt fast on top of existing spec 186 components, then adds one bulk action per round).

```poll
Which bulk actions should ship in /us v1?
(MCF) Multicast prompt only in v1, then add more actions one per round (Recommended)
(ALL) Multicast plus Copy links, Open in tabs, and Export CSV in v1
```

### Q3 — Kind filter chips above the flat list *(posted in `a3d8e5fc`)*

Recommended: **KND** (fast one-click narrowing without typing `type:`, synced with the shareable URL).

```poll
Show kind filter chips (All, Topics, Cards, Messages, Issues, Calendar, Lanes, Events...) above the /us list in v1?
(KND) Yes, include kind filter chips synced to the URL in v1 (Recommended)
(NO) No chips in v1; filter via type: in the Omnibox only
```

### Q4 — Card messages vs. topic reply messages *(posted in `a3d8e5fc` with `SEP`/`ONE`)*

Recommended: **SEP** (matches owner msg `32ae406f` naming "topics msgs , card msgs" separately; combined with Section 3.3's deduplication rule so a topic hitting on both title and root body renders once). Reviewer note (`c-584` W2): a third reading is `(TOP) Topics and replies only: a card is its topic *(not posted in form a3d8e5fc; posted form carries SEP/ONE only, and Section 3.3's dedup rule prevents duplicate cards under SEP)*`.

```poll
How should Level 1 card messages and Level 2 topic replies appear in /us?
(SEP) Separate kinds: card_msg (card), topic_msg (reply), and topic (Recommended)
(ONE) One message kind with a card/reply badge inside the row
(TOP) Topics and replies only: a card is its topic
```

### Q5 — Events scope in `/us` *(posted as ALL-recommended in `a3d8e5fc`; corrected to MIN-recommended in follow-up post `d5d7113d` after `a-583` S3)*

**Factual update (verified on `origin/master` `4ab7b731b`):** `pages/monitoring/events/index.vue:6` reads ONLY `GET /api/v1/auth/events` (`human_events`, Mine log); WUI has no Workspace or System event view (`git grep -n "v1/view/events\|v1/operator/events" origin/master -- csi-spl-wui/src/ | wc -l` -> `0`). Updated recommendation: **MIN** for v1 so every event hit opens a real full link.

```poll
Which event logs should /us search under Events?
(MIN) Reader's own Mine event log only, matching /monitoring/events today (Recommended)
(ALL) Mine plus Workspace (owner/admin) and System (operator admin) logs (requires adding Workspace/System deep links to /monitoring/events or preview-only rows)
```

### Q6 — Personal Notes in `/us` v1 *(posted in `a3d8e5fc`)*

Recommended: **INC** (notes have full links `/notes?note=<id>` and belong to the reader's personal realm like contacts, which are already searchable).

```poll
Should /us v1 also search the reader's own personal Notes (/notes?note=...)?
(INC) Yes, include the reader's own personal Notes in /us v1 (Recommended)
(W2) Defer personal Notes to Wave 2
```

### Q7 — Calendar entry sort key in default "last modified" view *(posted in `a3d8e5fc`)*

Recommended: **UPD** (keeps one consistent `updated_at` timeline across every object kind while displaying `starts_at` clearly in the row).

```poll
In the default "last modified" sort, how should calendar entries be ordered?
(UPD) By last modified (updated_at), showing the event start date in the row (Recommended)
(STR) By event start time (starts_at)
```

### Q8 — Other linkable UI objects (Section 3.3b) *(NEW from round 1, `c-584` W3)*

Recommended: **W2** (keeps v1 fast and focused on workspace objects already asked for, then adds Goals & Releases once `/us` is production grade).

```poll
Other linkable pages (Goals /goals/<id>, Releases /releases/<ref>, Help, etc., Section 3.3b) — include in /us v1?
(W2) Wave 2, after the v1 kinds are production grade (Recommended)
(V1) Include Goals and Releases in /us v1 too
```

---

## 8. Phase 2 — HOW (Blocked Until WHAT v1.0 Is Signed)

Phase 2 begins ONLY once all panel seats sign WHAT v1.0. It will specify:
- Hub API contract change (`GET /v1/view/search/universal` so `GET /v1/view/search` stays untouched), unified hit envelope, `updated_at`, stable kind enum, sort, opaque composite cross-kind cursor, and partial-error reporting.
- Index & query strategy inside Postgres 16 / Cloud SQL `db-f1-micro` (reusing S1r `spool_search_candidates`, replacing full `ListIssues` dump, SQL `updated_at` queries for calendar/contacts/lanes/notes, batched reads targeting `<= 6–8` DB round trips), and prd latency/buffer budget.
- Quick Preview metadata contract (`preview` in hit payload + on-demand `POST /v1/view/previews` without consuming search quota).
- WUI architecture (`pages/us.vue`, `useSidebarRailOnly`, Omnibox `/us` mode, flat list, quick preview pane/sheet, results navigation strip, selection bar -> `topicSelect` -> `MulticastDialog`, i18n keys across 19 locales, spec 027 bundle budget).
- Full access-control matrix and red-control test plan.
- Dependency-ordered build rows (`kind`, `vendor`, `files`, `after`, verification tests).

---

## 9. Panel Review Log and Signatures

### 9.1 Review Log

| Date (UTC) | Seat | Event |
|---|---|---|
| 2026-11-27 | `c-582` (User View) | Round-1 user-view input (U1–U13, Q-U1–Q-U3) on `4ab7b731b` (msg `c76f6c1d`); folded into WHAT v0.1 |
| 2026-11-27 | `c-584` (Reviewer) | Pre-check facts 1–5 on `4ab7b731b` (msg `7480378f`); folded into WHAT v0.1 |
| 2026-11-27 | `a-583` (Search Engine Expert) | Round-1 engine/API/rights/links/budget findings on `4ab7b731b` (msg `bf54c851`); folded into WHAT v0.1 |
| 2026-11-27 | `a-580` (Editor) | Published WHAT Draft v0.1 (`edfb2ffee`) on `review/c002-bcfd15e1-search-results-spec`; sent to panel and holder (`c-002` posted Q1–Q7 as form `a3d8e5fc`) |
| 2026-11-27 | `m-585` (UI Design) | Round-1 UI design input (D1–D12, msg `f0ccffab`); folded into WHAT v0.2 (keeping `.sidebar--rail` per owner `32ae406f`, `c-582` R1, `c-584` N6) |
| 2026-11-27 | `c-582` (User View) | Reviewed v0.1 `edfb2ffee` (msg `fe0b4f36`, R1–R8); all 8 folded into WHAT v0.2 |
| 2026-11-27 | `a-583` (Search Engine Expert) | Reviewed v0.1 `edfb2ffee` (msg `4a8bdee5`, S1–S7 incl. critical S3 on events view); all 7 folded into WHAT v0.2 |
| 2026-11-27 | `c-584` (Reviewer) | Reviewed v0.1 `edfb2ffee` (msgs `006bcc5d` & `5fe72660`, FAIL: W1–W3, N1–N6); all folded into WHAT v0.2 |
| 2026-11-27 | `a-580` (Editor) | Published WHAT Draft v0.2 (`a8e89dbfb`) on `review/c002-bcfd15e1-search-results-spec`; sent Q8 form + Q5 factual correction (`ALL` -> `MIN`) to holder |
| 2026-11-27 | `c-002` (Holder) | Verified `a8e89dbfb` and events-page grep; posted Q5 correction (`MIN` recommended) + Q8 poll (`W2`/`V1`) to HUM-10 as `msg:d5d7113d` (msg `113380e0`) |
| 2026-11-27 | `c-582`, `c-584`, `m-585`, `a-583` | All four sibling panel seats signed WHAT v0.2 (`a8e89dbfb`) via commits `993ceb8c1`, `9c4eb9b56`, `04145b860`, and `140c72b6b` (5/5 consensus) |
| 2026-11-27 | `a-580` (Editor) | Published WHAT v1.0 folding the three non-blocking v0.2 signature notes (`c-582` FR-US-11, `c-584` N7/N8) |

### 9.2 Signatures

Each seat signs a version with its own commit on `review/c002-bcfd15e1-search-results-spec`, adding one row below (`seat | vendor | version | sha read | note`).

| Seat | Vendor | Version | SHA Read | Note |
|---|---|---|---|---|
| `a-580` (Editor) | agy | WHAT v0.2 | — | Draft v0.2 folding all round-1 findings (R1–R8, S1–S7, W1–W3, N1–N6, D1–D12) |
| `c-582` (User View) | claude | WHAT v0.2 | `a8e89dbfb` | PASS: R1-R8 folded (R2-R4 blockers closed). N: FR-US-11 still names a long-press "Open in new tab", but a phone long-press now ticks the row (FR-US-15); drop it or move it into the row menu |
| `c-584` (Reviewer) | claude | WHAT v0.2 | `a8e89dbfb` | PASS: W1–W3 closed (6 M/H/L, 3.3 dedup, 3.3b + Q8); new cites re-run on `4ab7b731b`; notes N7–N8 for v0.3 |
| `m-585` (UI Design) | mistral | WHAT v0.2 | `a8e89dbfb` | contributor (UI design): D1–D12 folded (rail-only `.sidebar--rail` confirmed, wireframe in FR-US-04, OpenMessageToast in FR-US-11, ContextMenu/Shift+F10 row menu in FR-US-14, Retry-After in FR-US-19); no open blockers |
| `a-583` (Search Engine Expert) | agy | WHAT v0.2 | `a8e89dbfb` | Signed — all S1–S7 folded; object kinds, `updated_at`, rights, links, and budget targets verified |
| `a-580` (Editor) | agy | WHAT v1.0 | `140c72b6b` | WHAT v1.0 published (5/5 v0.2 consensus + N7/N8/FR-US-11 polish); ready for v1.0 signatures & Phase 2 HOW |
| `c-582` (User View) | claude | WHAT v1.0 | `c798a36c9` | PASS: diff over signed v0.2 holds only the 3 agreed notes; FR-US-11 row-menu wording as sent. Nit: FR-US-04 item 2 leaves its "(agreed by" parenthesis unclosed |
| `c-584` (Reviewer) | claude | WHAT v1.0 | `c798a36c9` | PASS: diff from v0.2 read line by line (FR-US-04 `:31` cite, FR-US-11 row menu, Q4/Q5 posted-form parity); `d5d7113d` checked in the `dispatch-bcfd15e1` spool log |
| `a-583` (Search Engine Expert) | agy | WHAT v1.0 | `c798a36c9` | Signed WHAT v1.0; moving to Phase 2 HOW |
| `m-585` (UI Design) | mistral | WHAT v1.0 | `c798a36c9` | contributor (UI design): signed — D1–D12 carried through v0.2→v1.0 unchanged (rail-only shell, wireframe, row anatomy, preview pane/sheet, selection bar + Multicast first, states, 390 px, keyboard, shared link); no open blockers; HOW v0.1 WUI input sent on dispatch-bcfd15e1 |
