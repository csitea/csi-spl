# Spec 197: Universal Search Results Page (`/us`)

Status: **Phase 1 — WHAT v1.1 · Phase 2 — HOW v1.1** (2026-11-27; built on landed v1.0 `193ab074a`; folds HUM-10's answers to form `a3d8e5fc`, `msg:9383a7be-8794-4ee7-a067-14b15b51fd42`: Q1=`LIV`, Q2=`ALL`, Q3=`NO`, Q4=`SEP`, Q5=`ALL`, Q6=`INC`, Q7=`UPD`; Q8 in follow-up post `d5d7113d` stays on Recommended default `W2` until answered).
Editor seat: `a-580` (`agy`, doc only).
History: WHAT v0.1 `edfb2ffee` -> v0.2 `a8e89dbfb` (5/5 signed) -> WHAT v1.0 `c798a36c9` (5/5 signed -> `e24ce3478`); HOW v0.1 `b30b5eba5` -> v0.2 `e7c2ee865` (5/5 signed -> `685113016`) -> HOW v1.0 `1cac4cd31` (5/5 signed -> `6828ebe1d`, landed on `origin/master` as `193ab074a`); **v1.1** folds HUM-10's form `a3d8e5fc` answers (`Q2=ALL`, `Q3=NO`, `Q5=ALL` diffs; `Q1=LIV`, `Q4=SEP`, `Q6=INC`, `Q7=UPD` confirmed).
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
     - **Events WUI linkability:** Verified `git grep -n "v1/view/events\|v1/operator/events" origin/master -- csi-spl-wui/src/ | wc -l` -> `0`; `csi-spl-wui/src/pages/monitoring/events/index.vue:6` reads ONLY `GET /api/v1/auth/events` (`human_events`, Mine log, via `createEventsClient` in `utils/event-log.mjs:154`). On the hub, `GET /v1/view/events` (`internal/hub/log_events.go:98,191`, `store/log_events_postgres.go:149`) and `GET /v1/operator/events` (`internal/hub/log_events.go:100,230`, `store/log_events_postgres.go:201`) already serve `workspace_events` and `system_events` (`0240_workspace_system_events.sql:37,52`), whose `id` sequences are independent from `human_events.event_id`. Because HUM-10 chose **Q5 = `ALL`** (`msg:9383a7be`), build row **W6e** adds Workspace and System log tabs + deep links to `/monitoring/events`.
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
  2. The **leftmost sections icon rail only** (`.sidebar--rail`, desktop only via `useSidebarRailOnly.ts:1-3,24,38`) — no channel/DM/search list panel beside the rail, matching the owner's *"top bar and the left most sections panel , but only a listing with the found objects"* (agreed by `c-582` R1 and `c-584` N6; note to `m-585`: panel 1's channel/DM list is hidden here rather than kept open, and on a phone the sections are the usual section strip (`useSidebarRailOnly.ts:31`, as on `/notes` at `:24`)).
  3. The **main results column** (`.feed-col` with `.feed-header` and `.feed-body`, `main.css:135,333,382`) holding ONLY the search header (title, query chip, Refresh, Sort, Copy Link — replaced by the Selection Bar while rows are ticked) and the single flat listing of found objects (no kind filter chips in v1; users filter via `type:` in the Omnibox per owner **Q3 = `NO`**, `msg:9383a7be`).
  4. An optional **right-side Quick Preview pane** (the right topic-pane slot with `PaneDivider` resizer) that opens only when the user invokes preview (`FR-US-12`), and closes cleanly back to the full-width listing.

```text
+-------------------------------------------------------------------+
| TopBar: [logo] [tenant] [theme] [Omnibox: /us deploy     ] [user] |
+----+-------------------------------------------+------------------+
| R  | Universal search `deploy`  [Refresh] [Sort v] [Copy link]    |
| A  |-------------------------------------------| Quick Preview    |
| I  | [ ] [icon Topic] Title match  #lobby  2m  | [<] 3 of 30+ [>] |
| L  | [ ] [icon Issue] SPL-123 ...  SPL-10 14m  | Kind · Title     |
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
| **Card message** (`card_msg`, Level 1 `is_parent=1`; **Q4 = `SEP` confirmed**) | Default | `COALESCE(edited_at, received_at)` | `/m/<msg_id>` (opens in original channel/DM, scrolled & marked) | Same as Topic |
| **Topic message** (`topic_msg`, Level 2 `is_parent=0`; **Q4 = `SEP` confirmed**) | Default | `COALESCE(edited_at, received_at)` | `/m/<msg_id>` (opens thread in original channel/DM, scrolled & marked) | Same as Topic |
| **Issue** (`issue`) | Default | `issues.updated_at` (`0047_issues.sql:67`) | `/issues?issue=<KEY>` | Workspace member (`topics.read`); excludes deleted/archived |
| **Calendar entry** (`calendar`) | Default (all non-deleted entries; not clipped to `±1y` when sorted by `updated_at`) | `calendar_events.updated_at` (`0125_calendar.sql:36`; **Q7 = `UPD` confirmed**; `starts_at` shown in row) | `/calendar?d=<YYYY-MM-DD>&event=<id>` (UTC start day) | Calendar read door (private entries only for creator & named people; deleted never; demo visitor workspace/public only) |
| **Lane** (`lane`, new; active live + queued lanes matching `/monitoring/lanes`, excluding pruned/`done` rows whose deep link has no row, `0096_fleet_lanes.sql:12-14`, `fleet_lanes_view.go:204-211`) | Default for authorised staff; omitted silently for others | `fleet_lanes.updated_at` (`0096_fleet_lanes.sql:27`) | `/monitoring/lanes?lane=<id@box>` (or `<id>` when box withheld) | Operator admin/PO (fleet) or workspace owner/admin (workspace lanes only, operator box & issue key stripped); non-staff gets 0 rows (never 403) |
| **Event** (`event`, **Q5 = `ALL` confirmed**) | Default (authorised scopes only) | Mine: `human_events.received_at`; Workspace: `workspace_events.at` (`0240_workspace_system_events.sql:40`); System: `system_events.at` (`:54`) | Mine: `/monitoring/events#<event_id>`; Workspace: `/monitoring/events?log=workspace#<id>`; System: `/monitoring/events?log=system#<id>` (Workspace & System tabs added by row **W6e**) | Mine = viewer's own `human_id` only; Workspace = workspace owner/admin (`TenantOwner \|\| Has(rbac.Admin)`, `log_events.go:123`, tenant FORCE RLS); System = operator workspace admin (`operatorAdminOf`/`operatorActor`, `log_events.go:231`, `rbac.go:165`). Unauthorised scopes return 0 rows silently (never 403, never `partial_errors`) |
| **File / Attachment** (`file`) | Default | carrying message `received_at` | `/m/<msg_id>` (carrying message) | Same as Topic |
| **Workspace Doc (Qto)** (`doc`) | Default | `workspace_doc_item.updated_at` | `/workspace/docs?doc=<doc_id>&view=doc[#ws-doc-<item_id>]` | Signed-in member with `docs.read` + restricted doc lock; never system repo docs |
| **Contact** (`contact`) | Default (when contacts kill-switch is on) | `personal.contacts.updated_at` (`0226_contacts.sql:78`) | `/people/contact/<id>` | Reader's own personal contacts only (no act-as / box / agent seat) |
| **Note** (`note`, new; **Q6 = `INC` confirmed**) | Default (where Notes enabled) | `personal.notes.updated_at` (`0225_personal_notes.sql:37`) | `/notes?note=<id>` | Reader's own personal realm notes only (where Notes enabled) |
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
  - **Other sort options** from a Sort control in the page header **[Proposal]**: `Oldest first` (`updated_at ASC NULLS LAST`) and `Relevance` (**[Proposal, new cross-kind ranking]** — exact key/title match > FTS `ts_rank_cd` / substring tier > `updated_at DESC` tie-break; `search-v1.md:54` ranks messages only today). Grouped-by-kind sort is omitted from v1 because `type:` filtering in the Omnibox (`FR-US-09`) narrows by kind without starving later kinds behind pages of an earlier kind.
  - Active non-default sort is written to the URL (`&sort=...`), so reload and shared links preserve the order.
- **FR-US-09 (Kind filtering via Omnibox `type:`, Q3 = `NO` confirmed `msg:9383a7be`).**
  - No kind filter chips row above the listing in v1.
  - Users narrow by kind via `type:` in the Omnibox (e.g., `/us type:issue deploy`), assisted by server-driven operator autocomplete (`GET /v1/view/search/operators`, which marks the four universal-only kinds `card_msg`, `topic_msg`, `lane`, `note`).
  - The API/URL `&type=` query parameter remains supported for direct or shared links and stays synced with any top-level `type:` term in `q` (never producing contradictory `?q=type:issue+deploy&type=calendar` URLs).
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
  - Clicking **Back to results**, pressing `Esc` (outside inputs/dialogs), or pressing browser **Back** returns to `/us?...` with the exact query, sort, `type:` filters, loaded pages, selection state, and scroll position restored, with the last-viewed row visibly marked active (stepping with Previous/Next replaces the history entry, so browser Back from the 5th hit cycled returns directly to the `/us` list, not to the 4th hit).
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
  - Selection bar replaces the header in one 44 px row of icon buttons (`aria-label` + `title`), keeping **Multicast**, a **More actions (`...`)** menu button (holding Copy links, Open in tabs, Export CSV; Q2 = `ALL`), and **Clear** reachable on screen at `390 px` with zero horizontal overflow.
  - On an item opened from `/us`, the results strip is one 44 px row of icon buttons (`aria-label` + `title`): Back to results, Previous, `k of N`, Next. It has no horizontal overflow at `390 px`, and it never covers the item's own header or the composer dock.

### 3.7 Selection and Bulk Actions (`FR-US-16` – `FR-US-17`)

- **FR-US-16 (Multi-select, selection lifetime & Universal Selection Bar).**
  - Ticking one or more rows replaces the list header with the **Selection Bar** (modeled on `IssuesBulkBar.vue` and `TopicSelectBar.vue`):
    - Master page checkbox (`none` / `indeterminate` / `all` of loaded rows).
    - Live breakdown count by kind (e.g., `12 selected: 9 topics, 3 issues`).
    - Applicable bulk action buttons: **Multicast** first (`TOPIC_SELECT_DEFAULT_ACTION = 'multicast'`), **Copy links**, **Open in tabs**, **Export CSV** (Q2 = `ALL`, confirmed `msg:9383a7be`), and **Clear**.
  - **Selection lifetime:** The ticks belong to one result list. A change of sort keeps them; when changing sort on a multi-page result set loads a different page window, the bar counts any ticked rows outside the currently loaded page (`3 selected, 1 not shown`). A new query clears them; if more than one row is ticked, the reader confirms first. Opening an item and coming back keeps them (`FR-US-11`). A workspace switch or page reload empties them; they are never stored on the hub (matching `stores/topicSelect.ts`, spec 186 §7.1.6).
  - **Mixed-kind honesty:** If a bulk action applies to only a subset of the selected kinds, the bar/dialog explicitly states what is included and what is skipped before execution (e.g., `Multicast to 9 topics; 3 issues skipped`). If zero selected items qualify, the button is disabled with a tooltip explaining why.
- **FR-US-17 (v1 bulk actions — Multicast, Copy links, Open in tabs, Export CSV; Q2 = `ALL` confirmed `msg:9383a7be`).**
  - **Multicast prompt (primary):** Selecting hits and clicking **Multicast** resolves every eligible hit to its target channel topic (`task_id`), de-duplicated:
    - A `topic` hit in a non-`issues` channel -> its `task_id`.
    - A `card_msg`, `topic_msg`, or `file` hit in a non-`issues` channel -> its carrying topic's `task_id` (added once even if multiple messages from the same topic were ticked).
    - DMs, `issues`-channel discussions, issues, calendar entries, lanes, events, docs, contacts, notes, channels, users, agents, and boxes are **not** multicast targets (per spec 186 Q2 `EX`, Q8 `CHN`, R1) and are reported as skipped.
    - Eligible targets, de-duplicated with `uniquePicks` (`stores/topicSelect.ts:56`) and filtered with `selectableCard` (`:49`, excluding `issues`-channel cards), are passed straight to `useMulticastSend().start(picks)` (`composables/useMulticastSend.ts:185`), which opens `MulticastDialog.vue` (spec 186 M11). `/us` keeps its own ticks (`stores/universalSearch.ts`); channel pages' `stores/topicSelect.ts` selection is neither read nor modified. A finished multicast clears the `/us` ticks.
  - **Copy links:** Copies the canonical absolute URLs (`window.location.origin + item.href`, one per line) for all ticked items with a non-empty `href` via `useCopyText`, skipping empty-`href` items (such as `tenant`) and showing a plain toast (`N links copied`, or `N links copied; M skipped`).
  - **Open in tabs:** Opens each ticked item's `href` in a new tab using `const w = window.open(href, '_blank')` (without `noopener` in the features string, because per WHATWG HTML `noopener` forces `window.open` to return `null` even on success) and immediately sets `w.opener = null` when `w` is non-null (skipping empty `href`). When more than **10** rows are ticked, asks for confirmation first (`Open N tabs?`); if the browser blocks popups (`w === null`), shows a plain non-blocking notice telling the reader how many tabs were blocked.
  - **Export CSV:** Pure client-side CSV download (`universal-search-<YYYYMMDD-HHMM>.csv`, UTF-8 BOM + RFC 4180 escaping + spreadsheet formula-injection guard prefixing leading `=`, `+`, `-`, `@`, tab `0x09`, or CR `0x0D` cells with `'`) over the ticked rows with columns `kind,id,updated_at,title,where,actor,href` (zero hub round trips).
  - Additional bulk actions beyond these four (Bulk issue status, Add to note) are deferred past v1.

### 3.8 Shareable Links and Rights (`FR-US-18`)

- **FR-US-18 (Shareable URL & access control).**
  - The URL `/us?q=<query>[&sort=<sort>][&type=<kinds>]` is the canonical shareable link (a Copy Link button in the page header copies it via `useCopyText`).
  - **Live evaluation under the opener's own rights** (**Q1 = `LIV` confirmed**, `msg:9383a7be`): opening a shared link carries ONLY query/filter/sort state (never hit payloads or tokens) and re-runs the query as the opener under the opener's own session, workspace membership, channel ACLs, DM-party checks, box locks, moderation, personal realm ownership (notes, contacts, Mine events), and role gates (lanes, Workspace/System events, file streams, docs).
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
- Saved searches, scheduled search alerts, or frozen/shared snapshot tables (**Q1 = `LIV` confirmed**).
- Kind filter chips above the listing in v1 (**Q3 = `NO` confirmed**; filter via `type:` in the Omnibox) and bulk actions beyond Multicast, Copy links, Open in tabs, and Export CSV (e.g. Bulk issue status, Add to note; **Q2 = `ALL` confirmed**).

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
2. **Layout & flat chronological listing `(M, H)`:** Signed in as the workspace owner/admin (so `lane` and `workspace` event rows are in scope; operator admin also sees `system` events), top bar and leftmost icon rail only (`.sidebar--rail`, no secondary sidebar list, no kind filter chips row per Q3 = `NO`); middle shows ONE flat list containing mixed kinds (at minimum: topic, card message, topic reply message, issue, calendar entry, lane, event across authorised scopes), sorted newest `updated_at` first; an edited card/topic message ranks above a newer-created unedited message (proving `COALESCE(edited_at, received_at)`); clicking **Load more** across mixed kinds appends zero duplicates in monotonic `updated_at DESC` order; each row displays kind badge, title/highlighted snippet, location, actor, and time.
3. **Coexistence — HC1 & HC2 `(M)`:** Typing `/s deploy` still opens `/search?q=deploy` with `SearchSidePanel.vue` unchanged; every existing `*search*` suite stays green.
4. **Quick Preview & keyboard cycling `(M)`:** Press `ArrowDown` twice, press `Space` -> right-side Quick Preview pane opens for row 3; press `ArrowDown` -> preview updates to row 4 with **zero** extra search requests. Typing `[`, `]`, `x`, `/`, or `Space` inside a composer input types characters normally and never triggers list shortcuts.
5. **Open, item-to-item cycling, and return with state `(M)`:** Press `Enter` on row 4 -> opens item at its canonical full link; top strip shows `4 of N` (or `4 of N+`); press `]` -> steps directly to row 5; click **Back to results** (or browser Back) -> returns to `/us?q=deploy` with loaded pages, scroll position, and row 5 marked active. `Ctrl/Cmd+click` on a row title opens the item in a new tab with no results strip.
6. **Sorting & URL persistence `(M)`:** Switch sort to `Oldest first` -> URL updates with `sort=`; full page reload preserves the exact reversed order.
7. **Multi-select & v1 bulk actions — Multicast, Copy links, Open in tabs, Export CSV `(M, L)`:** Tick two channel-topic hits (or a topic + a message in a second topic) and one issue hit -> Selection Bar shows `3 selected: 2 topics, 1 issue`; clicking **Copy links** copies all 3 canonical absolute URLs (toast confirms); clicking **Export CSV** downloads valid RFC 4180 CSV with formula-injection guard and 3 data rows; clicking **Open in tabs** opens the 3 canonical links (and asks confirmation when > 10 rows are ticked); clicking **Multicast** explicitly notes `2 topics; 1 issue skipped`, opens `MulticastDialog.vue` pre-populated with those 2 de-duplicated topics `(M)`; sending posts the prompt to both topics `(L)`.
8. **Shareable link & zero existence leakage `(H, L)`:** Copy `/us?q=deploy...` link; open as a second member who lacks access to one private channel/DM topic -> that hit is completely absent, zero "hidden" count or hint appears, remaining permitted hits display normally; signed in as a plain member, no `lane`, `workspace` event, or `system` event row appears and nothing hints at one; signed in as a non-operator workspace admin, `workspace` events appear and `system` events do not (zero `partial_errors`).
9. **Signed-out link flow `(L)`:** Open the shared `/us?q=deploy` link while signed out -> redirects to sign-in -> after sign-in, lands directly on `/us?q=deploy` with results.
10. **Phone `390×844` `(M)`:** Steps 1, 2, 4 (bottom-sheet preview), 5 (open with single 44 px results strip & Back restores scroll), and 7 (long-press to enter selection, Multicast + More-actions menu for Copy links / Open in tabs / Export CSV visible on screen in one 44 px bar) all pass with **zero horizontal overflow**.
11. **Empty, error, and partial states `(M)`:** `/us zzqqxx` shows empty state + tips; `/us before:notadate` shows `400 bad_query` token highlight pointer; simulated search failure shows plain error + Retry (and `429` shows `Retry-After`).

---

## 7. Owner Poll Decisions (HUM-10, Form `a3d8e5fc` Answered; `d5d7113d` Pending)

Per `csi-spl-doc/doc/help/how-to-post.md:423` ("One form per message. A second `poll` block in the same post stays a code block") and §7 item 7 (highest-priority question first), the dispatch holder posted Q1–Q7 as one 7-question form (`msg:a3d8e5fc`) and Q8 + the Q5 factual note separately (`msg:d5d7113d`).

**HUM-10 answered form `a3d8e5fc` on 2026-11-27 (`msg:9383a7be-8794-4ee7-a067-14b15b51fd42`), folded into v1.1:**

| Poll | v1.0 Default | HUM-10 Answer (`msg:9383a7be`) | Change in v1.1 |
|---|---|---|---|
| **Q1** Shared link | `LIV` | **`LIV`** — The same search, run live under their own rights | Same (confirmed) |
| **Q2** Bulk actions in v1 | `MCF` | **`ALL`** — Multicast, copy links, open in tabs, export CSV | **Changed:** added Copy links, Open in tabs, Export CSV + row **W7** |
| **Q3** Kind filter chips | `KND` | **`NO`** — No, filter with `type:` in the omnibox | **Changed:** dropped `UsKindChips.vue` from FR-US-04/09 & row **W2** |
| **Q4** Card vs. reply msgs | `SEP` | **`SEP`** — Separate kinds: card, reply, topic | Same (confirmed) |
| **Q5** Events scope | `MIN` | **`ALL`** — Mine, plus workspace (owner/admin) and system (operator admin) | **Changed:** added `workspace_events` + `system_events` in B4/AC9, namespaced event IDs, + row **W6e** (`/monitoring/events` Workspace/System tabs & deep links) |
| **Q6** Personal Notes | `INC` | **`INC`** — Yes | Same (confirmed) |
| **Q7** Calendar sort key | `UPD` | **`UPD`** — By last modified, start date shown in the row | Same (confirmed) |
| **Q8** Other linkable pages (`d5d7113d`) | `W2` | *(pending answer to `d5d7113d`)* | Stays `W2` until answered |

### Q1 — Shared results link behaviour *(DECIDED: `LIV`, `msg:9383a7be`)*

Recommended: **LIV** (matches `/search?q=`, requires no stored snapshot table, and guarantees zero existence leakage when rights change).

```poll
When someone opens a shared /us results link, what should they see?
(LIV) The same query run live under their own current rights (Recommended)
(FRZ) The sharer's saved list as it was, stored on the hub; items the opener may not read are hidden
```

### Q2 — Bulk actions in v1 *(DECIDED: `ALL`, `msg:9383a7be` — differs from v1.0 `MCF`)*

Recommended: **MCF** (ships Multicast prompt fast on top of existing spec 186 components, then adds one bulk action per round).

```poll
Which bulk actions should ship in /us v1?
(MCF) Multicast prompt only in v1, then add more actions one per round (Recommended)
(ALL) Multicast plus Copy links, Open in tabs, and Export CSV in v1
```

### Q3 — Kind filter chips above the flat list *(DECIDED: `NO`, `msg:9383a7be` — differs from v1.0 `KND`)*

Recommended: **KND** (fast one-click narrowing without typing `type:`, synced with the shareable URL).

```poll
Show kind filter chips (All, Topics, Cards, Messages, Issues, Calendar, Lanes, Events...) above the /us list in v1?
(KND) Yes, include kind filter chips synced to the URL in v1 (Recommended)
(NO) No chips in v1; filter via type: in the Omnibox only
```

### Q4 — Card messages vs. topic reply messages *(DECIDED: `SEP`, `msg:9383a7be`)*

Recommended: **SEP** (matches owner msg `32ae406f` naming "topics msgs , card msgs" separately; combined with Section 3.3's deduplication rule so a topic hitting on both title and root body renders once). Reviewer note (`c-584` W2): a third reading is `(TOP) Topics and replies only: a card is its topic *(not posted in form a3d8e5fc; posted form carries SEP/ONE only, and Section 3.3's dedup rule prevents duplicate cards under SEP)*`.

```poll
How should Level 1 card messages and Level 2 topic replies appear in /us?
(SEP) Separate kinds: card_msg (card), topic_msg (reply), and topic (Recommended)
(ONE) One message kind with a card/reply badge inside the row
(TOP) Topics and replies only: a card is its topic
```

### Q5 — Events scope in `/us` *(DECIDED: `ALL`, `msg:9383a7be` — differs from v1.0 `MIN`; W6e adds Workspace/System event tabs & deep links)*

**Factual update (verified on `origin/master` `4ab7b731b`):** `pages/monitoring/events/index.vue:6` reads ONLY `GET /api/v1/auth/events` (`human_events`, Mine log); WUI has no Workspace or System event view (`git grep -n "v1/view/events\|v1/operator/events" origin/master -- csi-spl-wui/src/ | wc -l` -> `0`). Updated recommendation: **MIN** for v1 so every event hit opens a real full link.

```poll
Which event logs should /us search under Events?
(MIN) Reader's own Mine event log only, matching /monitoring/events today (Recommended)
(ALL) Mine plus Workspace (owner/admin) and System (operator admin) logs (requires adding Workspace/System deep links to /monitoring/events or preview-only rows)
```

### Q6 — Personal Notes in `/us` v1 *(DECIDED: `INC`, `msg:9383a7be`)*

Recommended: **INC** (notes have full links `/notes?note=<id>` and belong to the reader's personal realm like contacts, which are already searchable).

```poll
Should /us v1 also search the reader's own personal Notes (/notes?note=...)?
(INC) Yes, include the reader's own personal Notes in /us v1 (Recommended)
(W2) Defer personal Notes to Wave 2
```

### Q7 — Calendar entry sort key in default "last modified" view *(DECIDED: `UPD`, `msg:9383a7be`)*

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

## 8. Phase 2 — HOW (v1.1)

Phase 2 reflects HUM-10's binding answers to form `a3d8e5fc` (`msg:9383a7be-8794-4ee7-a067-14b15b51fd42`: Q1=`LIV`, Q2=`ALL`, Q3=`NO`, Q4=`SEP` + dedup, Q5=`ALL`, Q6=`INC`, Q7=`UPD`), while Q8 in follow-up post `d5d7113d` stays on its Recommended default (`W2`) until answered (Section 8.7 records the remaining Q8 row swap). Every file and line reference below was verified on `origin/master` (`4ab7b731b` and `193ab074a`).

### 8.1 API Contract and Coexistence

- **Normative contract:** [contracts/universal-search-v1.md](./contracts/universal-search-v1.md).
- **HC1/HC2 byte-identical guarantee:** `GET /v1/view/search` and `csi-spl-doc/specs/003-spool-message-bus/contracts/search-v1.md` remain **byte-identical** across every build row (`git diff origin/master -- csi-spl-doc/specs/003-spool-message-bus/contracts/search-v1.md` MUST be empty; `roundtrips_perf_test.go:126` keeps `/v1/view/search?q=seed` pinned at `9`).
- **Route & OpenAPI:** `GET` / `OPTIONS /v1/view/search/universal` registered in `internal/hub/search.go:48-53` (`routeSearch`) and documented in `csi-spl-api/src/go/spool-hub-api/internal/hub/openapi.json` beside `/v1/view/search` (`:24322`) and `/v1/view/search/operators` (`:24434`).
- **Rate limit & time budget:** Shares the per-`(tenant, reader)` **30 searches/min** bucket with `/v1/view/search` (`search-v1.md:445`, `429` + `Retry-After`; cursor "Load more" calls count against this bucket just as `/search` does today) and the **7 s** `statement_timeout` / **8 s** context (`internal/hub/search.go:31-32,162`). Preview cycling never calls this endpoint.
- **Grammar v1.9 (`internal/search/grammar.go:24`):** Adds `TypeCardMsg` (`card_msg`), `TypeTopicMsg` (`topic_msg`), `TypeLane` (`lane`), `TypeNote` (`note`), `search.UniversalDefaultTypes` (15 default kinds; `file_line` and `tenant` stay opt-in), and `search.ParseUniversal(raw, now)` (`type:message` expands to `{card_msg, topic_msg}`). Existing `search.DefaultTypes` (9 types) is untouched; `GET /v1/view/search/operators` marks the 4 new kinds with `"universal_only": true`.
- **Canonical links & multicast metadata in hit JSON:** Every item in `items[]` carries hub-resolved `href` (canonical full link per Section 3.3), lightweight per-kind `preview` metadata (zero extra round trips on `Space`/`ArrowDown`), and `multicast: { eligible, task_id, channel, title }` (directly constructing `TopicPick` without a lookup).

### 8.2 Clean-Code Source Architecture, Cross-Page Dedup, and Kind-Aware Cursor

- **Clean-code compliance (developer guide §2.2.1–2.2.4, enforced by `cleancode_test.go` and `cleancode.test.mjs`):**
  - Every function in Go, TS/Vue, and Bash is `<= 75` lines, nesting `<= 4`, parameters `<= 7` (Go) / `<= 5` (TS/Vue).
  - No `SELECT *`. JSON responses use `wire.WriteJSON` / `wire.WriteError`; any new UUIDs use `internal/uid`.
- **Source interface + K-way merge:** Instead of a monolithic `switch` across 17 kinds, each kind implements a small `universalSource` interface (`Kind() search.Type`, `Fetch(ctx, req) ([]UniversalHit, bool, error)`), registered in a slice. A dedicated `mergeUniversalHits` helper performs an exact k-way merge on `(updated_at DESC NULLS LAST, kind ASC, id DESC)` (or `ASC` for `updated_asc`), applies `mod.keepResults` and `lockKeepResults`, and slices the top `limit` rows.
- **Source-level cross-page Topic vs. `card_msg` dedup:** Enforced at the `card_msg` source (not only in the merge window): when `topic` is in `kinds`, `card_msg` excludes any root message (`is_parent = 1`) whose `task_id` also matches as a `topic` (Batch 1's shared `spool_search_candidates` probe decides both), and the emitted `topic` row carries the root body `snippet` and `preview.msg_id`. Thus a thread with newer replies (`topic.updated_at > card_msg.updated_at`) never emits its opening card twice across pages ([universal-search-v1.md](./contracts/universal-search-v1.md) §3.3).
- **Kind-aware opaque cursor (`universalCursor`):** Base64url JSON `{ v: 1, h: queryHash(q, sort, kinds), a, k, i, nt, o, ro }`. Each dated SQL source applies a **kind-aware boundary** against `(a, k, i)` (strictly `< $a` for `kind < k`, `(updated_at, id) < ($a, $i)` for `kind == k`, inclusive `<= $a` for `kind > k`, and the mirror inequalities for `updated_asc`), preventing skips or duplicates on equal timestamps across kinds. `SearchMessagesUniversal` reads `card_msg` + `topic_msg` together using the inclusive boundary when `card_msg <= k <= topic_msg` and fetches `2*limit + 1` rows so dedup never yields a short page. Bounded-source caps (`event` 500-row cap -> `events_capped_500`; `sort=relevance` pool `max(limit*3, 120)` -> `relevance_pool_capped`) are surfaced explicitly in `notices[]` ([universal-search-v1.md](./contracts/universal-search-v1.md) §4).

### 8.3 Postgres Index Migration, RLS, Batching, and Performance Budget

- **Forward-only migration:** ONE additive file `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_universal_search_indexes.sql` (current head on `origin/master` `4ab7b731b` is `0331_scheduled_tasks.sql`; claim `<next>` at build time via `cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next`).
- **Transaction constraint (verified):** `csi-spl-api/src/go/spool-hub-api/internal/store/migrate.go:157` executes every migration inside `pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error ...)`, which **rules out** `CREATE INDEX CONCURRENTLY`. Therefore B1 uses `SET LOCAL lock_timeout = '5s';` with standard `CREATE INDEX IF NOT EXISTS` (precedent: `0143_messages_search_index.sql:18-20` measured 2 732 ms for 13 057 dev rows and noted 22 934 prd rows on 2026-10-07, no `CONCURRENTLY` needed). **Build-time measurement requirement:** B1 MUST count current prd `messages` (read-only) at build time and record the measured dev index build duration (ms) in the migration file header, as `0143` does, before prd apply:
  1. `messages_tenant_updated ON messages (tenant_id, COALESCE(edited_at, received_at) DESC, msg_id) WHERE loop_id IS NULL` — partial predicate excludes loop-runner rows; enables `updated_at` DESC/ASC index scans without sorting while text queries still narrow via S1r `spool_search_candidates`.
  2. `issues_tenant_updated ON issues (tenant_id, updated_at DESC, number DESC) WHERE deleted_at IS NULL AND archived_at IS NULL` — replaces full-table `ListIssues` Go dump (`issues_postgres.go:404`, up to ~0.9 MB detoast) with SQL-filtered `SearchIssues`.
  3. `calendar_events_tenant_updated ON calendar_events (tenant_id, updated_at DESC, event_id) WHERE deleted_at IS NULL` — serves unclipped `SearchCalendarUniversal` ordered by `updated_at DESC`.
  4. `workspace_doc_item_tenant_updated ON workspace_doc_item (tenant_id, updated_at DESC, id)` — prd baseline 3 444 rows / 4.2 MB (spec 100 §2.1); backs `SearchDocs` keyset paging.
  5. `contacts_person_updated ON personal.contacts (person_id, updated_at DESC, contact_id) WHERE deleted_at IS NULL` — backs `SearchContactsByUpdated` inside `inPerson` RLS.
  6. `notes_person_updated ON personal.notes (person_id, updated_at DESC, note_id) WHERE archived_at IS NULL` — backs `SearchNotesByUpdated` inside `inPerson` RLS (Q6 `INC`).
- **RLS & search index invariants:**
  - **No new policy `TO public` on `messages`.** Reuse existing `SECURITY DEFINER` `spool_search_candidates` (`0143_messages_search_index.sql:21`, granted via `spool-hub-roles/runtime-grants.sql:26`). Note that RESTRICTIVE `channel_scope` (`0169_embed_channel_scope.sql`) already interacts with non-leakproof `@@` inside `spool_search_candidates` (measured ~68.7k buffers on prd, 2026-10-12, n=5); therefore **buffer measurements MUST use `auto_explain` inside the function under the runtime role** — never superuser `EXPLAIN` (which bypasses RLS and hides the real plan).
  - **Personal realm door:** `contacts` and `notes` are read exclusively through the `inPerson` personal-realm door (`0168_personal_realm.sql`, `app.person_id` set with `app.tenant_id` unset), never through a widened grant.
- **4-Batch `pgx.Batch` plan (arithmetic 4–6 DB round trips vs. 9 today on `/v1/view/search`):**
  1. **Batch 1 (1 RT, `inTenant`):** ONE shared `spool_search_candidates($q, 500)` probe (reused by `card_msg`, `topic_msg`, and `topic`, saving 1 RT vs `search-v1`), plus `ViewBoxes`, `TenantHumans`, `ViewChannelStats`, moderation state, and `lockViewFor`.
  2. **Batch 2 (1 RT, `inTenant` + `humanScope`):** `SearchMessagesUniversal` (`is_parent`, `edited_at`), `SearchTopicsUniversal` (`max(GREATEST(received_at, COALESCE(edited_at, received_at)))`), `SearchFiles`, `SearchIssues`, `SearchCalendarUniversal`, and `SearchDocs` (when `docs.read`).
     - **Zero-extra-RT carrying topic title (`multicast.title`):** `SearchMessagesUniversal` and `SearchFiles` wrap their `LIMIT`-bounded query (`<= 2*limit + 1` rows) in an outer `SELECT` that resolves each row's carrying topic title (`left(btrim(split_part(root.body, E'\n', 1)), 140)`) via a single indexed lateral lookup on `messages_task_received (tenant_id, task_id, received_at, msg_id)` (`0022_messages_thread_walk.sql:19`), so `multicast.title` is always the true topic title at 0 extra DB round trips.
     - **Timeout fallback:** If Batch 2 hits Postgres `57014` (`statement_timeout`), fall back to per-source bounded reads within remaining request budget and emit `partial_errors` only for the timed-out source(s).
  3. **Batch 3 (1 RT, `inPerson`, signed-in non-clone person only):** `SearchContactsByUpdated` (when contacts kill-switch is on) + `SearchNotesByUpdated` (when `NotesEnabled`). If `realmRefuses` returns a **store error** (vs. a real refusal, SPL-5694), fail closed for personal realm by omitting `contact`/`note` and emitting `partial_errors: [{kind:"contact",code:"unavailable"},{kind:"note",code:"unavailable"}]` instead of aborting workspace results with `503`; a real refusal (act-as clone / box token / agent seat) still omits them silently with zero `partial_errors`.
  4. **Batch 4 (1–3 RT):** `HumanEventsPage` (`human_events`, hub-wide outside tenant RLS, newest 500 rows) + conditional `WorkspaceEventsPage` (`workspace_events`, `0240_workspace_system_events.sql:37`, `store/log_events_postgres.go:149`, newest 500 rows via `ix_workspace_events_tenant_id:49`, `inTenant` FORCE RLS — workspace owner/admin `TenantOwner || Has(rbac.Admin)` only, `log_events.go:123`; 0 RT for plain members) + conditional `SystemEventsPage` (`system_events`, `0240_workspace_system_events.sql:52`, `store/log_events_postgres.go:201`, newest 500 rows, hub-wide — operator workspace admin `operatorAdminOf`/`operatorActor` only, `log_events.go:231`, `rbac.go:165`; 0 RT for non-operator callers) + conditional `SearchLanes` (owner/admin or operator admin/PO only — 0 RT for plain members; active `fleet_lanes` + `queuedLanes` + `canReadTopic`, skipping heavy `fleetLaneBurn`) + optional isolated `SearchFileLines` (only when explicitly opted in + staff, so 500k-line scans never abort Batch 2). Event hit IDs are namespaced by scope (`mine:<event_id>`, `workspace:<id>`, `system:<id>`) so the three independent sequences never collide in cursor watermarks or WUI row keys.
- **Measured budget pin (`B5`):** `roundtrips_perf_test.go` keeps `/v1/view/search?q=seed` at `9` and adds a new row for `/v1/view/search/universal?q=seed` pinning the **exact measured integer** (not a range). Target before measurement (unmeasured today): `<= 6–8` RT, p95 `< 1 s` warm / `< 2 s` cold on prd `db-f1-micro` shape, `<= 2 000` buffers on rare/prefix message queries (outside the known `0169` probe caveat, verified with `auto_explain`), `$0/mo` extra infra (inside Postgres 16 only).

### 8.4 Access-Control Matrix and Red Controls (Layer H — Real Postgres, `PRE_PUSH_TIER=full`)

Every store/hub build row runs `PRE_PUSH_TIER=full ./run -a do_check_pre_push` (`hub-pg.tst.sh`). Every gate below requires a dedicated Postgres test PLUS a planted **red control** (removing the gate MUST cause the test to fail, developer guide §2.12.1 & §2.12.4):

| # | Kind(s) | Enforced Door | Planted Red Control |
|---|---|---|---|
| AC1 | All tenant kinds | FORCE RLS + explicit `tenant_id` pin | Drop `tenant_id` pin on `workspace_doc` -> system repo doc leaks |
| AC2 | `topic`, `card_msg`, `topic_msg`, `file` | Channel read ACL (`PublicChannels` / `ViewerChannels`, rdb `0028`) | Omit `ViewerChannels` -> non-member private channel hit leaks |
| AC3 | `topic`, `card_msg`, `topic_msg`, `file` | DM-party privacy (`from_id = viewer OR to_id = viewer`) | Drop party check -> third-party DM hit leaks |
| AC4 | `topic`, `card_msg`, `topic_msg`, `file` | Retention (`expires_at > now`, `loop_id IS NULL`), archive (`archivedHideSQL`), relay (`HideRelay`), `mod.keepResults`, `lockKeepResults` | Drop `archivedHideSQL` or `lockKeepResults` -> hidden hit leaks |
| AC5 | `issue` | `topics.read` + `deleted_at IS NULL AND archived_at IS NULL` | Drop `archived_at IS NULL` -> archived issue leaks |
| AC6 | `doc` | `rbac.DocsRead` + `store.WithHuman` restricted doc lock | Drop `DocsRead` -> unauthorized member sees doc hit |
| AC7 | `calendar` | `calendarPrivateSQL` + `deleted_at IS NULL` + `demoAudiences` | Bypass `calendarPrivateSQL` -> private calendar entry leaks |
| AC8 | `lane` | `TenantOwner || Has(rbac.Admin)` / `operatorReadCaller` + `canReadTopic` + strip operator `agent_box` & `issue_key` in workspace view; plain member gets `0` rows and zero `partial_errors` | Drop staff check -> plain member sees lane hit |
| AC9 | `event` (Q5 = `ALL`) | Mine: `human_events` pinned to `sq.Viewer`; Workspace: `workspace_events` tenant FORCE RLS + `TenantOwner \|\| Has(rbac.Admin)` (`log_events.go:123`); System: `system_events` `operatorAdminOf`/`operatorActor` (`log_events.go:231`, `rbac.go:165`). Unauthorised scopes return 0 rows and zero `partial_errors` | Drop viewer pin -> another user's Mine event leaks; drop owner/admin gate -> plain member sees Workspace event; drop tenant scope -> cross-tenant Workspace event leaks; drop operator-admin gate -> non-operator workspace admin sees System event |
| AC10 | `contact`, `note` | `inPerson` RLS (`0168`) + `realmRefuses` (no act-as clone, box token, or agent seat) + kill switches (`contacts.workspaces`, `NotesEnabled`) | Bypass `realmRefuses` -> act-as clone sees contacts/notes |
| AC11 | `user`, `file_line` | `user`: email never searched/returned, disabled/technical/`ChannelGuest` excluded; `file_line`: `fileStreamsStaffRefusal` -> 0 rows + `file_streams_staff_only` notice | Search by email -> must return 0; non-staff `in:file-streams` -> must return 0 + notice |

### 8.5 WUI Architecture, Dark-Launch Flag, Navigation Strip, Keys, Multicast, i18n, and Bundle Budget

- **Dark-launch flag (`env.wui.universal_search`, prevents broken `/us` on prd during W1–W5):**
  - Add `universal_search: false` under `env.wui` in `csi-spl-cnf/csi-spl/all.env.yaml:1850`, baked as `NUXT_PUBLIC_UNIVERSAL_SEARCH` in `.github/workflows/30_wui-build-deploy.yml:257,310,405`, `csi-spl-orc/src/bash/run/deploy-wui.func.sh:105,116`, and `csi-spl-wui/nuxt.config.ts` `runtimeConfig.public.universalSearch` (mirroring `env.wui.seo_index -> NUXT_PUBLIC_SEO_INDEX`; re-render tfvars via `ENV=<env> ./run -a do_tpl_gen && git diff --exit-code`).
  - Defaults to `true` in mock mode (`NUXT_PUBLIC_USE_MOCK=1`) so all local/CI mock e2e suites exercise `/us`, and `false` on live `dev` and `prd` throughout W1–W5.
  - While `false`: `US_CMD_RE` is NOT matched (Omnibox behaviour on prd is 100% unchanged) and `/us` renders the standard not-found view.
  - In **W6** (after B4 + B5 are deployed on dev and prd): flip `universal_search: true` on `dev.env.yaml` first, run the Layer L live proof on dev, then flip `prd.env.yaml` (with owner Go) alongside the FR-US-03 help doc edit.
- **Omnibox `/us` wiring (4 verified places, gated on `universalSearch`, keeping `/s` intact):**
  1. `csi-spl-wui/src/utils/search.mjs`: add `US_CMD_RE = /^\/us(?::|\s|$)/i`, `usQueryOf(text)`, and `usPath({ q, sort, type })`. When `universalSearch` is enabled, check `US_CMD_RE` **first** in `omniboxMode()` (`:145`, returning `'usearch'`), in `channelLookupOf()`'s exclusion guard (`:211`, protecting both `openAsk.beforeSend()` and `searchInstead()` from treating bare `/us` as a channel lookup), in `omniboxTextLeavingSearch()` (`:250`, clearing both `'search'` and `'usearch'`), and in `operatorTokenAt()` (`:285`, enabling operator autocomplete after `/us `).
  2. `csi-spl-wui/src/utils/feed.mjs:21`: `parseOmnibox()` matches `US_CMD_RE` first (when enabled) and returns `{ usearch: q }`; `/search:`, `/search `, `/s ` stay unchanged; `/use`, `/user`, `/usa` do NOT match `US_CMD_RE`.
  3. `csi-spl-wui/src/components/MessageComposer.vue:419` & `csi-spl-wui/src/composables/useComposerSend.ts:48-54,96-101`: `searchMode` is true for both `'search'` and `'usearch'` (distinct mode chip label); `searchInstead()` (`:48`, the global TopBar path) emits `'usearch'` for `'usearch'` mode before checking `'search'` or `channelLookupOf`; non-global `parseOmnibox` path (`:97`) also emits `'usearch'`.
  4. `csi-spl-wui/src/components/TopBar.vue`: `onUsearch(q)` calls `router.push(localePath(usPath({ q })))`; mirror `onSearchPage` / `showQuery` (`:349-365`) for `/us` so `/us?q=...` populates `/us <q>` in the Omnibox and leaving `/us` clears it.
- **Signed-out redirect (verified gap):** `csi-spl-wui/src/utils/signed-out-redirect.mjs:72` explicitly lists `p === '/' || p === '/lobby' || p === '/search'`. Add `p === '/us'` to `isProductScreen` (when `universalSearch` is enabled) and unit-test that `/us?q=a%20b&sort=updated_asc&type=issue` round-trips cleanly through `safeRedirect`.
- **Rail-only layout:** Add `usRailOnly` (`!isMobile.value && isUsPath(route.path)`) in `csi-spl-wui/src/composables/useSidebarRailOnly.ts:38` and bind it in `ChannelSidebar.vue:2` (`.sidebar--rail`).
- **Isolated store & lazy components (HC1 by construction):**
  - New Pinia store `csi-spl-wui/src/stores/universalSearch.ts` holding `{ q, sort, types, rows, next, hasMore, loading, loadingMore, error, warnings, notices, partialErrors, activeKey, scrollTop, ticks }`.
  - **HC1 zero-touch gate:** `stores/universalSearch.ts` NEVER imports or writes `stores/search.ts`. None of `stores/search.ts`, `components/SearchSidePanel.vue`, `components/SideHitList.vue`, or `pages/search.vue` appears in ANY Spec 197 build row's file list (a diff touching them is an automatic review FAIL).
  - Lazy route `csi-spl-wui/src/pages/us.vue` (`.feed-col` / `.feed-header` / `.feed-body`, `main.css:135,333,382`) + lazy components: `UsResultsHeader.vue` (replaced by `UsSelectionBar.vue` while rows are ticked, `pages/issues.vue:16-34` pattern; no `UsKindChips.vue` per Q3 = `NO`), `UsResultList.vue` (roving `tabindex`, `SideHitList`-style keyboard walk without touching `SideHitList.vue`), `UsResultRow.vue` (resolves `actor` display name from the shell's roster with id fallback, zero extra calls; kind badges use `UiIcon` from `utils/uiIcons.ts`), `UsPreviewPane.vue` (desktop right-pane slot with `PaneDivider`, `scrollRowIntoPane` on cycle), `UsPreviewSheet.vue` (phone `UiDialog` bottom sheet), `UsSelectionBar.vue` (44 px phone icon row at `MOBILE_STACK_MAX_PX = 820`, holding Multicast + More-actions menu for Copy links / Open in tabs / Export CSV backed by pure `utils/us-bulk-actions.mjs` per Q2 = `ALL`), `UsResultsStrip.vue`, and desktop row menu (`SearchRowMenu` pattern). Row **W6e** adds Workspace (`GET /v1/view/events`) and System (`GET /v1/operator/events`) log tabs + deep links (`?log=workspace#<id>`, `?log=system#<id>`) to `pages/monitoring/events/index.vue` (Q5 = `ALL`).
- **Results navigation strip (`useState('us-cycling')`, history-position matching, zero first-paint bloat):**
  - `cycling` lives in Nuxt `useState<{ key: string, returnUrl: string, position: number } | null>('us-cycling', () => null)` — **not** imported from `stores/universalSearch.ts` — so `layouts/default.vue` reads only `useState('us-cycling')` and never pulls `stores/universalSearch.ts` into the first-paint entry chunk.
  - Opening a hit from `/us` stores `cycling = { key, returnUrl, position }`, where `position` is the vue-router history position created by the push (`window.history.state.position` after push; never appends `?from=us` to the URL).
  - `layouts/default.vue` mounts `<LazyUsResultsStrip v-if="usCyclingActive" />` while `window.history.state?.position === cycling.position`. Any in-place `router.replace()` preserves `position`, so the strip stays across `/m/<id>` redirects to channels/DMs (`pages/m/[id].vue:46`, `replace: true`), page query rewrites, AND Previous/Next cycling (`router.replace()`).
  - A `router.afterEach` hook, registered only while `cycling` is set and removed when it clears, clears `cycling = null` on any new push (clicking another channel, Omnibox navigation, typed URL) or Back past `position`. A new tab has empty state so shows no strip. Browser Back from the 5th hit cycled returns straight to `/us?...`, restoring loaded pages, `activeKey`, `ticks`, and `scrollTop` after render.
- **Keyboard integration:**
  - List handles its own keys on the list element (`ArrowUp`/`ArrowDown`, `j`/`k`, `Home`/`End`, `Enter`, `Space`, `x`, `Shift+Arrow`, `Ctrl/Cmd+A`, `Esc`, `ContextMenu`/`Shift+F10`) calling `preventDefault()` so `vim-nav` (`utils/vim-nav.mjs:35-47`) never intercepts `Esc` as Back over the list.
  - Window listener for strip `[` / `]` mounts ONLY while `UsResultsStrip` is mounted and checks `inTypingOrOverlay(document.activeElement)` (`utils/msg-shortcuts.mjs:94`, `OVERLAY` at `:91`).
  - Honours `keyboard_shortcuts` preference: when off, native listbox keys (`Arrow`, `Home`/`End`, `Enter`, `Space`, `Tab`) keep working while letter/punctuation shortcuts (`x`, `[`, `]`, `j`, `k`, `/`) do nothing; every action stays a visible button. Add a `/us` section to `MsgShortcutsHelp`.
- **Multicast handoff:** Passes `uniquePicks` built from ticked hits' `item.multicast` fields (`selectableCard`-eligible) directly to `useMulticastSend().start(picks)` (`composables/useMulticastSend.ts:185`), never mutating channel pages' `stores/topicSelect.ts`.
- **Spec 027 initial-JS gzip budget (`perf-budgets.json:4,27`):**
  - Ceiling is **155.0 KB** gzip (`ci_initial_gzip_kb` last estimated at `151.9 KB`, ~3.1 KB headroom).
  - `/us` adds ONLY the lazy route record, `US_CMD_RE`, and the `useState('us-cycling')` check (~0.1–0.2 KB) to first paint; `pages/us.vue`, `stores/universalSearch.ts`, and all `Us*` components stay lazy chunks; zero new dependencies.
  - Row **W1** measures `ci_initial_gzip_kb` before and after (`n=2` each side, recorded in commit body) and fails if delta exceeds `+0.3 KB`.
- **i18n & WUI gates (developer guide §2.7, §3.4):**
  - Every string lives under `us.*` in `en.json` + all 18 other locales (per-row subtrees `us.preview.*`, `us.strip.*`, `us.select.*` to prevent parallel merge conflicts; reuse existing `search.type.*` keys where present); `i18n-parity`, `i18n-untranslated`, and `i18n-no-raw-text` stay green.
  - Every row adding locale strings runs `ENV=dev ./run -a do_spl_lang_review_gct` (`csi-spl-orc`) and carries `Lang-review: gct <run id>` in its commit message.
  - Every WUI row runs `pnpm run typecheck` and `BASE_URL=<generated bundle> pnpm run test:e2e`.

### 8.6 Dependency-Ordered Build Rows

Routing follows `csi-spl-cnf/csi-spl/all.env.yaml:1555-1615` (`mistral_ui_allowed: false`, `mistral_coding_allowed: false`, `mistral_review_allowed: false`): coding and test rows go to `claude` (backup `agy`), R7 cross-vendor review goes to `agy` (never `mistral`), and every row carries an `Issue:` under Epic **SPL-1292**, `Spec: csi-spl-doc/specs/197-universal-search-results`, and either its `csi-spl-doc/` update or `Docs: none (<why>)`.

| Row | Kind | Vendor (Backup) | R7 Review | Scope & Exact Files | After | Verification & Gates |
|---|---|---|---|---|---|---|
| **B1** Universal search indexes migration | `simple_coding` | `claude` (`agy`) | `agy` | `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_universal_search_indexes.sql` (`do_rdb_migration_next`), `csi-spl-api/src/go/spool-hub-api/internal/store/search_universal_migrate_test.go` | WHAT v1.0 | `PRE_PUSH_TIER=full` (pg16 parse, idempotent apply, `lock_timeout`, 6 indexes incl. `WHERE loop_id IS NULL`); count current prd `messages` (read-only) and record dev build ms in migration header (as `0143` does) |
| **B2** Grammar v1.9 + universal types & operators | `simple_coding` | `claude` (`agy`) | `agy` | `csi-spl-api/src/go/spool-hub-api/internal/search/{grammar.go,values.go,universal.go,universal_test.go}`, `internal/hub/search.go` (operators metadata only; `DefaultTypes` untouched) | WHAT v1.0 | `go test -race ./internal/search ./internal/hub` (`internal/search >= 98.1%`; existing `search-v1` goldens unchanged) |
| **B3** Store universal queries + 4-batch Postgres path | `complex_coding` | `claude` (`agy`) | `agy` | `csi-spl-api/src/go/spool-hub-api/internal/store/{search_universal.go,search_universal_postgres.go,search_universal_memory.go,search_universal_test.go}` | B1, B2 | `PRE_PUSH_TIER=full` (`hub-pg.tst.sh`: `COALESCE(edited_at, received_at)`, kind-aware cursor SQL, outer lateral `messages_task_received` topic title, source-level `card_msg` dedup, SQL issues/calendar/contacts/notes/messages/topics/docs, `inPerson` RLS, `internal/store >= 80.4%`) |
| **B4** Hub `GET /v1/view/search/universal`, k-way merge, cursor, dedup, preview & rights | `complex_coding` | `claude` (`agy`) | `agy` | `csi-spl-api/src/go/spool-hub-api/internal/hub/{search_universal.go,search_universal_sources.go,search_universal_cursor.go,search_universal_preview.go,search_universal_lanes.go,search_universal_test.go}`, `internal/hub/search.go` (route hook), `internal/hub/openapi.json` | B2, B3 | `PRE_PUSH_TIER=full` (`hub-pg.tst.sh`: AC1–AC11 red controls incl. all 3 event scopes `mine`/`workspace`/`system` via `store.LogEvents.WorkspaceEventsPage` & `SystemEventsPage`, namespaced event IDs `mine:`/`workspace:`/`system:` + canonical `/monitoring/events` hrefs, equal-timestamp & cross-page cursor zero-dup/monotonicity, 2-page topic/`card_msg` dedup test, `realmRefuses` store-error vs refusal, `events_capped_500`/`relevance_pool_capped` notices, `search-v1.md` git diff empty, `internal/hub >= 82.2%`) |
| **B5** Round-trip pin & prd-shape perf proof | `tests` | `claude` (`agy`) | `agy` | `csi-spl-api/src/go/spool-hub-api/internal/hub/roundtrips_perf_test.go` (keep `/v1/view/search?q=seed` at `9`; add `/v1/view/search/universal?q=seed` with measured integer pin), `internal/store/search_universal_perf_test.go` | B4 | `PRE_PUSH_TIER=full` (`TestRoundTripsPerRequest`, `TestUniversalSearchP95`, `auto_explain` inside `spool_search_candidates`) |
| **W1** Dark-launch flag, `/us` Omnibox wiring + red-control unit gate (`R0`), signed-out redirect, rail-only empty `/us` shell | `simple_coding` | `claude` (`agy`) | `agy` | `csi-spl-cnf/csi-spl/all.env.yaml` (`wui.universal_search: false` + `do_tpl_gen`), `.github/workflows/30_wui-build-deploy.yml`, `csi-spl-orc/src/bash/run/deploy-wui.func.sh`, `csi-spl-wui/nuxt.config.ts`, `src/utils/{search.mjs,feed.mjs,signed-out-redirect.mjs}`, `src/composables/{useComposerSend.ts,useSidebarRailOnly.ts}`, `src/components/{MessageComposer.vue,TopBar.vue,ChannelSidebar.vue}`, `src/pages/us.vue`, `i18n/locales/*.json`, `tests/unit/us-omnibox-guard.test.mjs` (**R0** lands IN W1's commit — never alone on trunk; prove RED locally/throwaway branch before W1 code and record failing output + base sha in W1 commit body, covering flag-off + flag-on + `/s` + `/us` + bare `/us` + `/use`/`/user`/`/usa`) | WHAT v1.0 | R0 red control proven locally or on a throwaway branch before W1 code (failing output + base tree sha in W1's commit body; R0 covers flag-off: `/us x` -> today's behaviour and `/us` not routed), then GREEN in W1; `do_tpl_gen && git diff --exit-code`; `do_spl_lang_review_gct`; `ci_initial_gzip_kb` delta `<= +0.3 KB` (`n=2`); `pnpm run typecheck`; e2e scenarios 1 & 3 (mock); HC1 zero-touch check |
| **W2** `universalSearch` store, flat list, rows, header, sort, paging & mock corpus (no kind chips per Q3 = `NO`) | `complex_coding` | `claude` (`agy`) | `agy` | `csi-spl-wui/src/stores/universalSearch.ts`, `src/components/{UsResultsHeader.vue,UsResultList.vue,UsResultRow.vue}`, `src/pages/us.vue`, `src/utils/mock-data.mjs`, `i18n/locales/*.json`, `tests/e2e/universal-search-acceptance.test.mjs` | W1 | `pnpm run typecheck`; `do_spl_lang_review_gct`; actor roster-name resolution; Omnibox `type:` filtering + `&type=` URL sync (no kind chips); mock e2e scenarios 1, 2, 3, 6, 11 (desktop + phone); HC1 zero-touch check |
| **W3** Quick Preview right pane (desktop) & bottom sheet (phone) | `simple_coding` | `claude` (`agy`) | `agy` | `csi-spl-wui/src/components/{UsPreviewPane.vue,UsPreviewSheet.vue}`, `src/pages/us.vue`, `i18n/locales/*.json` (`us.preview.*`), `tests/e2e/us-preview.test.mjs` | W2 | `pnpm run typecheck`; `do_spl_lang_review_gct`; `us-preview.test.mjs` (scenarios 4 & 10 preview, 0 search requests while cycling) |
| **W4** Results navigation strip (`useState('us-cycling')`, history-position matching, `[`/`]`, `router.replace`) & return-with-state | `simple_coding` | `claude` (`agy`) | `agy` | `csi-spl-wui/src/components/UsResultsStrip.vue`, `src/layouts/default.vue` (1 `LazyUsResultsStrip` line reading `useState('us-cycling')` only — never importing `stores/universalSearch.ts`), `src/components/MsgShortcutsHelp.vue`, `i18n/locales/*.json` (`us.strip.*`), `tests/e2e/us-strip.test.mjs` | W2 | `pnpm run typecheck`; `do_spl_lang_review_gct`; `us-strip.test.mjs` (open `card_msg` `/m/<id>` redirected + `topic` hit, strip shows on both, unrelated nav clears strip, Back skips cycled hits, scroll restored, 44 px strip at 390 px); `ci_initial_gzip_kb` unchanged |
| **W5** Universal Selection Bar & Multicast handoff (`useMulticastSend().start`) | `simple_coding` | `claude` (`agy`) | `agy` | `csi-spl-wui/src/components/UsSelectionBar.vue`, `src/components/UsResultList.vue`, `i18n/locales/*.json` (`us.select.*`), `tests/unit/us-multicast-picks.test.mjs`, `tests/e2e/us-select.test.mjs` | W2 | `pnpm run typecheck`; `do_spl_lang_review_gct`; unit picks test; `us-select.test.mjs` (scenario 7 M Multicast + scenario 10 long-press at 390 px); channel `topicSelect` untouched |
| **W6e** `/monitoring/events` Workspace & System log tabs + deep links (Q5 = `ALL`) | `simple_coding` | `claude` (`agy`) | `agy` | `csi-spl-wui/src/utils/{spool-client-lazy.mjs,spool-client.mjs}` (hub methods for `GET /v1/view/events` and `GET /v1/operator/events` in `spool-client-lazy.mjs`, matching `fleetLanes` at `:2080`, with thin lazy forwarders via `loadLazy()` at `spool-client.mjs:598`; `createEventsClient` in `event-log.mjs:154` stays auth/Mine-only), `src/utils/event-rows.mjs`, `src/pages/monitoring/events/index.vue`, `i18n/locales/*.json` (`events.logs.*`), `tests/e2e/events-workspace-system.test.mjs` | WHAT v1.1 | `pnpm run typecheck`; `do_spl_lang_review_gct`; `events-workspace-system.test.mjs` (Mine `/monitoring/events#<id>` unchanged; Workspace tab `GET /v1/view/events` & `/monitoring/events?log=workspace#<id>` for owner/admin; System tab `GET /v1/operator/events` & `/monitoring/events?log=system#<id>` for operator admin; tabs hidden for plain member; 390 px zero overflow) |
| **W7** Extra v1 bulk actions — Copy links, Open in tabs, Export CSV (Q2 = `ALL`) | `simple_coding` | `claude` (`agy`) | `agy` | `csi-spl-wui/src/utils/us-bulk-actions.mjs`, `src/components/UsSelectionBar.vue`, `i18n/locales/*.json` (`us.bulk.*`), `tests/unit/us-bulk-actions.test.mjs`, `tests/e2e/us-bulk-actions.test.mjs` | W5 | `pnpm run typecheck`; `do_spl_lang_review_gct`; unit tests (absolute link formatting + skipped count, RFC 4180 CSV + UTF-8 BOM + `=`, `+`, `-`, `@`, `0x09` tab, `0x0D` CR formula-injection guard, `window.open` without `noopener` + `w.opener = null` + `null`-return blocked-popup count, > 10 tabs threshold); `us-bulk-actions.test.mjs` (desktop buttons + phone 44 px More-actions menu, zero overflow at 390 px) |
| **W6** Live hub wiring, unified e2e composition, FR-US-03 help disambiguation, dev rollout + Layer L live proof, then prd flip | `complex_coding` | `claude` (`agy`) | `agy` | `csi-spl-wui/src/utils/spool-client.mjs` (1 `universalSearch` method), `src/stores/universalSearch.ts`, `tests/e2e/universal-search-acceptance.test.mjs` (composes W3–W5 + W6e + W7 steps), `tests/e2e/universal-search-live.proof.mjs`, `csi-spl-doc/doc/help/index.md` (`:52`), `csi-spl-wui/src/public/help-md/index.md` (`:48`), `csi-spl-cnf/csi-spl/dev.env.yaml` (`wui.universal_search: true` + `do_tpl_gen`; then `prd.env.yaml` after Layer L proof + owner Go) | W2, W3, W4, W5, W6e, W7, **B4 & B5 deployed on dev + prd** (`do_check_deploy_lag` clean, G8) | `pnpm run typecheck`; full `universal-search-acceptance.test.mjs`; Layer L dev live proof (scenarios 1, 7 real multicast send, 8 two-member zero-leak + plain-member no-lane/no-workspace-event/no-system-event + non-operator admin no-system-event, 9 signed-out redirect); all existing `*search*` suites green |

*Parallelism:* **B1**, **B2**, and **W6e** run in parallel; **W1–W5** and **W7** (on mock, dark on live dev/prd via `env.wui.universal_search: false`) run in parallel with **B1–B5**; after **W2**, rows **W3**, **W4**, and **W5** run in parallel with disjoint e2e files (`us-preview`, `us-strip`, `us-select`, `us-bulk-actions`, `events-workspace-system`) and disjoint locale subtrees (`us.preview.*`, `us.strip.*`, `us.select.*`, `us.bulk.*`, `events.logs.*`), **W7** follows **W5**, and all converge at **W6** only after **B4 & B5** are live on dev and prd (G8).

### 8.7 Owner Poll (Q1–Q8) Resolution and Remaining Row Swap

Q1–Q7 were answered by HUM-10 (`msg:9383a7be`, form `a3d8e5fc`) and are **folded directly into v1.1** (`Q1=LIV`, `Q2=ALL` -> row **W7**, `Q3=NO` -> dropped `UsKindChips.vue`, `Q4=SEP`, `Q5=ALL` -> `workspace_events` + `system_events` in B4/AC9 + row **W6e**, `Q6=INC`, `Q7=UPD`). Only **Q8** (`msg:d5d7113d`) remains pending:

| Poll | Alternate Answer | Exact Build-Row Swap |
|---|---|---|
| **Q8** *(pending `d5d7113d`)* | `V1` (Goals & Releases in v1) instead of `W2` | Add narrow row **B4b** after B4 for `goal` (`/goals/<id>`) and `release` (`release_notes`, `/releases/<ref>`) in Batch 2; W2 adds their kind icon/label. |
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
| 2026-11-27 | `a-580` (Editor) | Published WHAT v1.0 (`c798a36c9`) folding the three non-blocking v0.2 signature notes (`c-582` FR-US-11, `c-584` N7/N8) |
| 2026-11-27 | `c-003` (Holder) | Cleared panel to proceed into Phase 2 HOW v0.1 on Recommended Q1–Q8 defaults while owner polls `a3d8e5fc` / `d5d7113d` await answers (msg `c3f9ac27`) |
| 2026-11-27 | `c-582`, `c-584`, `a-583`, `m-585` | All four sibling seats signed WHAT v1.0 (`c798a36c9`) via commits `ad219908b`, `c05b5a308`, `0b4ae49c6`, and `e24ce3478` (5/5 consensus); `c-582`, `c-584`, and `a-583` sent Phase 2 HOW inputs (`4e94101c`, `126efc55`, `ea34bdb9`) |
| 2026-11-27 | `a-580` (Editor) | Published Phase 2 HOW Draft v0.1 (`b30b5eba5`: `spec.md` §8 + `contracts/universal-search-v1.md`) on `review/c002-bcfd15e1-search-results-spec` |
| 2026-11-27 | `m-585` (UI Design) | Sent HOW v0.1 WUI design layer notes (W-A..W-J, msg `8e036634`); folded into HOW v0.2 |
| 2026-11-27 | `c-582` (User View) | Reviewed HOW v0.1 `b30b5eba5` (msg `48335613`, blocker K1 `/m/<id>` history-position strip + K2–K4); all folded into HOW v0.2 |
| 2026-11-27 | `a-583` (Search Engine Expert) | Reviewed HOW v0.1 `b30b5eba5` (msg `8cf0cd5e`, blockers E1 kind-aware cursor & E3 lateral topic title + E2, E4); all folded into HOW v0.2 |
| 2026-11-27 | `c-584` (Reviewer) | Reviewed HOW v0.1 `b30b5eba5` (msg `05fbb668`, FAIL: W1 R0 in W1, W2 dark-launch flag, W3 source-level cross-page dedup + N1–N5); all folded into HOW v0.2 |
| 2026-11-27 | `a-580` (Editor) | Published Phase 2 HOW Draft v0.2 (`e7c2ee865`) folding K1–K4, E1–E4, W1–W3/N1–N5, and W-A..W-J |
| 2026-11-27 | `c-582`, `c-584`, `a-583`, `m-585` | All four sibling panel seats signed HOW v0.2 (`e7c2ee865`) via commits `90ec001e9`, `4b418fb57`, `b9f43aa07`, and `685113016` (5/5 consensus); `c-584` noted non-blocking N6 (W1 R0 proof location + flag-off cases) |
| 2026-11-27 | `a-580` (Editor) | Published Phase 2 HOW v1.0 folding `c-584` N6; out for final HOW v1.0 signatures |
| 2026-11-27 | `c-582`, `a-583`, `c-584`, `m-585` | All four sibling seats signed HOW v1.0 (`1cac4cd31`) via `795417168`, `d2fc6a364`, `d7f95bdaa` (R7 PASS), `6828ebe1d`; landed on `origin/master` as `193ab074a` (CI green) |
| 2026-11-27 | HUM-10 (`msg:9383a7be`) | Answered form `a3d8e5fc`: Q1=`LIV`, Q2=`ALL`, Q3=`NO`, Q4=`SEP`, Q5=`ALL`, Q6=`INC`, Q7=`UPD` (relayed by `c-003` `0d46f9e3`) |
| 2026-11-27 | `a-580` (Editor) | Published v1.1 on top of `193ab074a` folding Q2=`ALL` (+W7), Q3=`NO` (drop `UsKindChips.vue`), Q5=`ALL` (Workspace/System events + W6e), and confirming Q1/Q4/Q6/Q7 |
| 2026-11-27 | `c-819` (Reviewer, claude) | Reviewed v1.1 `86bf80dea` against `origin/master` `de9cfd667` (msg `423d3146`): FAIL on blocking W1 (`window.open(..., 'noopener')` returns `null` per WHATWG HTML, breaking popup-block detection) + non-blocking N1–N5 |
| 2026-11-27 | `a-580` (Editor) | Folded `c-819` W1 (`window.open(href, '_blank')` + `w.opener = null` + W7 unit test) and N1–N4 (`rbac.go:165`, OWASP CSV tab/CR guard, multi-page sort selection wording, W6e `spool-client-lazy.mjs` hub client) into v1.1 |

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
| `a-580` (Editor) | agy | HOW v0.1 | `e24ce3478` | Published Phase 2 HOW v0.1 (`spec.md` §8 + `contracts/universal-search-v1.md`) folding `c-582` H1–H10, `a-583` §8.1–8.6, and `c-584` G1–G9 |
| `a-580` (Editor) | agy | HOW v0.2 | `b30b5eba5` | Published HOW v0.2 closing all round-1 HOW blockers (`c-582` K1–K4, `a-583` E1–E4, `c-584` W1–W3/N1–N5, `m-585` W-A..W-J) |
| `c-582` (User View) | claude | HOW v0.2 | `e7c2ee865` | PASS: K1 (history-position strip, survives `/m/<id>` replace), K2 (`useState`, no store in first paint), K3 (disjoint e2e files + locale subtrees), K4 (roster display name) folded; H1-H10 intact |
| `c-584` (Reviewer) | claude | HOW v0.2 | `e7c2ee865` | PASS: W1 (R0 inside W1), W2 (dark-launch flag `env.wui.universal_search`), W3 (source-level dedup + 2-page H test) closed; new cites re-run on `4ab7b731b`. N: W1 Verify names where R0's red runs (local or throwaway branch, output in the commit body) and pins the flag-off cases |
| `a-583` (Search Engine Expert) | agy | HOW v0.2 | `e7c2ee865` | Signed — E1–E4 folded cleanly across `spec.md` §8 and `contracts/universal-search-v1.md` (kind-aware cursor, source-level cross-page dedup, `messages_task_received` lateral `multicast.title`, `WHERE loop_id IS NULL` partial index, `realmRefuses` fail-closed `partial_errors`); no open engine blockers |
| `m-585` (UI Design) | mistral | HOW v0.2 | `e7c2ee865` | contributor (UI design): signed — W-A–W-J folded into §8.5/§8.6 (UiDialog phone sheet, `SearchRowMenu` desktop row menu, `scrollRowIntoPane`, 44 px phone selection row, roster actor name, `UiIcon` badges, `useState('us-cycling')` strip, dark-launch flag in W1, disjoint `us-preview`/`us-strip`/`us-select` e2e + locale subtrees, help edit moved to W6); all §8.5/§8.6 WUI file:line cites re-verified on `origin/master` `4ab7b731b` (search.mjs:145/211/250/285, feed.mjs:21, useComposerSend.ts:48, MessageComposer.vue:419, TopBar.vue:349-365, signed-out-redirect.mjs:72, useSidebarRailOnly.ts:38, ChannelSidebar.vue:2, vim-nav.mjs:35-47, msg-shortcuts.mjs:91/94, useMulticastSend.ts:185, topicSelect.ts:49/56, pages/m/[id].vue:46, pages/issues.vue:16-34, utils/uiIcons.ts:1, main.css:135/333/382, all.env.yaml:1850/1864, 30_wui-build-deploy.yml:257/310/405, deploy-wui.func.sh:105/116, nuxt.config.ts:471-481, perf-budgets.json:4/27, help index.md:52 / help-md:48); no open blockers |
| `a-580` (Editor) | agy | HOW v1.0 | `685113016` | Published HOW v1.0 (5/5 HOW v0.2 consensus + `c-584` N6 W1 Verify R0 location & flag-off cases); ready for HOW v1.0 signatures |
| `c-582` (User View) | claude | HOW v1.0 | `1cac4cd31` | PASS: the diff over signed HOW v0.2 (685113016..1cac4cd31) holds only the status, the W1 R0 verify cell (c-584 N6) and the log rows; user-view points H1-H10 and K1-K4 unchanged |
| `a-583` (Search Engine Expert) | agy | HOW v1.0 | `1cac4cd31` | Signed — verified diff `685113016..1cac4cd31` (§8.1–8.4, B1–B5, and `contracts/universal-search-v1.md` unchanged from signed HOW v0.2 `e7c2ee865`; `c-584` N6 folded cleanly into W1 Verify); ready to build |
| `c-584` (Reviewer) | claude | HOW v1.0 | `1cac4cd31` | PASS: diff over signed HOW v0.2 is the 4 stated lines (status, W1 Verify folds N6 incl. flag-off R0 cases, 9.1 log, editor row); contract unchanged since `e7c2ee865`; cited paths unchanged on `origin/master` `35467af49` vs `4ab7b731b`. N: the editor row names `685113016` (the v0.2 sign tip) as sha read, the v1.0 commit is `1cac4cd31` |
| `m-585` (UI Design) | mistral | HOW v1.0 | `1cac4cd31` | contributor (UI design): signed — diff `685113016..1cac4cd31` verified as only the 4 editor lines (status header, W1 Verify cell folding `c-584` N6 R0 proof location + flag-off cases, §9.1 log, editor §9.2 row); W-A–W-J WUI input intact in §8.5/§8.6; no open blockers |
| `a-580` (Editor) | agy | WHAT+HOW v1.1 | `193ab074a` | Published v1.1 folding HUM-10 form `a3d8e5fc` answers (`msg:9383a7be`: Q2=`ALL` +W7, Q3=`NO` drop `UsKindChips.vue`, Q5=`ALL` Workspace/System events +W6e; Q1=`LIV`, Q4=`SEP`, Q6=`INC`, Q7=`UPD` confirmed; Q8 `d5d7113d` pending `W2`) |
