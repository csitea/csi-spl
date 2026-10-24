# Spec 155 (Notes section) - agy cross-vendor reviewer seat review & verdict

Seat: `a-089` (agy, cross-vendor reviewer seat).
Epic: `SPL-2403`. Issue: `SPL-3216`.
Placement slug: `c002-s155-agy-reviewer`.
Spec reviewed: `csi-spl-doc/specs/155-notes-section/spec.md`.
Commits reviewed: `471c55f24` (v1.0 draft) and `12443cd0d` (v1.1 fold of W1-W4).
Verified on tree: `origin/master` at `12443cd0d`.

---

## 1. Summary of Verdicts

| # | Check / Area | Verdict | Notes |
|---|---|---|---|
| 1 | Section 1.2 code facts (29 facts in v1.0, rows 30-32 in v1.1) | **OK** | All 32 facts printed via `git show origin/master:<path>` and verified; all hold. |
| 2 | Data and privacy (D1 personal realm, RLS, operator scope, erase / export) | **OK** | Notes reside in `personal.*` with `person_scope` RLS. Other persons, workspace admins, and operator read 0 rows. Erase/export complete. |
| 3 | Links and privacy (D7, B7, D4) | **OK** | Links store typed ref + label, no object body. Non-member workspaces return `label: ""` and `left: true`; clicks navigate to target origin where target RBAC protects content. No leakage. |
| 4 | Build rows (B1-B10 disjointness, dependencies, smallest first, precedent `2835ff381`) | **OK (folded in v1.1)** | Parallel rows B8 and B9 are strictly disjoint. B1 follows `2835ff381`. Defects W1-W4 in B2, B4, B5, and B10 are fully resolved and folded in v1.1. |
| 5 | Cases C1-C31 with red controls | **OK** | Every case C1-C31 has a verifiable red control failing on master today. |
| 6 | WUI requirements (first-screen strings, no page-meta keys, no `:style`, CSP, chunk budget) | **OK** | Translations loaded in B5 for all 19 locales; CSS in stylesheets; `/notes` page is its own async route chunk. |

Final verdict: **SIGN**. All checks verified OK with 0 outstanding defects.

---

## 2. Section 1.2 Code Facts Verification (All 32 Facts)

Every cited file and line range was printed directly from `origin/master` using `git show origin/master:<path> | sed -n '<a>,<b>p'`:

| # | What cited | Path & Lines | Terminal Output Verification | Verdict |
|---|---|---|---|---|
| 1 | Rail tabs | `csi-spl-wui/src/utils/rail-order.ts:16, 19, 52, 63` | `export type RailId` (10 ids); `RAIL_TABS` at :19; `calendar` at :52; `reporting` at :63 | **Holds** |
| 2 | Pending rail id | `csi-spl-wui/src/utils/rail-order.ts:80-90, 96-99` | `RAIL_HUB_PENDING = Object.freeze([])`; `wireRailOrder` drops pending ids | **Holds** |
| 3 | Hub rail list & DB CHECK | `csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go:1003`; `csi-spl-rdb/src/sql/postgres/spool-hub/0209_human_rail_order_reporting.sql:41-42` | `var RailTabs = []string{...}` (13 ids); 0209 CHECK has cardinality 13 with `<@` and `@>` array | **Holds** |
| 4 | WUI section shell precedent | Commit `8708821ac` (SPL-2351) | 38 files changed: `ChannelSidebar.vue`, `sidebar-tabs.mjs`, `section-strip.mjs`, `rail-order.mjs`, `uiIcons.ts`, 19 locale JSONs, `reporting.md`, rail tests | **Holds** |
| 5 | Rail only section | `csi-spl-wui/src/composables/useSidebarRailOnly.ts:21, 32` | `reportingRailOnly` at :21; `railOnly` computed at :32 | **Holds** |
| 6 | List-then-open pattern | `csi-spl-wui/src/pages/issues.vue:1-6` | One sheet; modal above 820 px; level-3 full screen on phone | **Holds** |
| 7 | Phone breakpoint | `csi-spl-wui/src/composables/useMobileStack.ts:32, 42` | `:32` "place that decides which panel is on screen at <= 820 px"; `:42` `stack.isMobile` | **Holds** |
| 8 | Written form of internal object | `csi-spl-doc/doc/help/how-to-post.md:83-88` | Rule 11: `msg:<uuid>`, `topic:<uuid>`, workspace host, unknown workspace stays text | **Holds** |
| 9 | WUI links typed ref | `csi-spl-wui/src/utils/id-links.mjs:37, 258-264, 22-23` | `TYPED_RE` at :37; `resolveTyped` at :258-264; "No workspace, no link" at :22-23 | **Holds** |
| 10 | Workspace host | `csi-spl-wui/src/utils/tenant-host.mjs:22` | `tenantOrigin(tenant, siteUrl, apexTenant)` | **Holds** |
| 11 | Issue address | `csi-spl-wui/src/utils/issue-key-links.mjs:24, 39-42` | `issueKeyPrefix` at :24; `issueHref` returns `/issues?issue=<KEY>` at :39-42 | **Holds** |
| 12 | Calendar entry address | `csi-spl-wui/src/utils/calendar-event-link.mjs:3` | `<origin>/calendar?d=<day>&event=<id>` in header doc | **Holds** |
| 13 | Doc address | `csi-spl-wui/src/utils/docs.mjs:24` | `docsRoute` returns `'/docs/' + path` | **Holds** |
| 14 | Topic, message, channel pages | `csi-spl-wui/src/pages/{t/[task_id],m/[id],channel/[name]}.vue` | All 3 page templates exist on origin/master | **Holds** |
| 15 | Message menu items & choose | `csi-spl-wui/src/utils/msg-menu.mjs:67, 71, 97`; `csi-spl-wui/src/components/MessageMenu.vue:140-160` | `msgMenuItems` at :67 (`copy` :71, `make-issue` :97); `choose(id)` emits per id at :140-160 | **Holds** |
| 16 | Shortcut keys | `csi-spl-wui/src/utils/msg-shortcuts.mjs:35-50, 310-320` | `MSG_SHORTCUTS`: H R E A O P B U L C K T M D; `ISSUE_SHORTCUTS`: R E A O P L K M D; `N` is free in both | **Holds** |
| 17 | Issue actions | `csi-spl-wui/src/components/IssueDetailActions.vue:38-46`; `csi-spl-wui/src/components/IssueRowMenu.vue` | Buttons `copy`, `archive`, `delete` in `IssueDetailActions.vue`; `IssueRowMenu.vue` exists | **Holds** |
| 18 | Sidebar row menu & calendar dialog | `csi-spl-wui/src/components/SidebarRowMenu.vue:138, 230`; `csi-spl-wui/src/components/CalendarEventDialog.vue:221-222` | `type RowItem` at :138, `choose` at :230; Copy link button at :221-222 | **Holds** |
| 19 | Omnibox modes | `csi-spl-wui/src/components/TopBar.vue:1-6`; `csi-spl-wui/src/utils/search.mjs:21, 136`; `csi-spl-wui/src/stores/omnibox.ts:5-7` | TopBar omnibox composer; `SEARCH_CMD_RE` at :21; `omniboxMode` at :136; `OmniboxTarget` in store | **Holds** |
| 20 | Command palette groups | `csi-spl-wui/src/composables/usePaletteItems.ts:40` | `PALETTE_GROUPS = ['sections', 'channels', 'people', 'topics', 'docs', 'settings'] as const` | **Holds** |
| 21 | Hub search entity types | `csi-spl-api/src/go/spool-hub-api/internal/search/grammar.go:31-45` | `Types`: message, topic, file, robot, user, channel, box, tenant, event, issue (10 types, no note) | **Holds** |
| 22 | Personal realm storage & RLS | `csi-spl-rdb/src/sql/postgres/spool-hub/0168_personal_realm.sql:16-23, 138-149` | `person_id` first FK humans CASCADE, no `tenant_id`, ENABLE + FORCE RLS, `person_scope` policy loop | **Holds** |
| 23 | Personal realm grants | `csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql:38-51` | Explicit grants per table in `personal`; no default privileges in schema `personal` | **Holds** |
| 24 | Catalogue test | `csi-spl-api/src/go/spool-hub-api/internal/store/personal_catalogue_test.go:30-42` | `personalCatalogueGaps` pins table list (`hours_receipts,profile,receipt_due,settings`) and policies | **Holds** |
| 25 | Person scope in Go | `csi-spl-api/src/go/spool-hub-api/internal/store/rls.go:59, 82`; `csi-spl-api/src/go/spool-hub-api/internal/store/personal_scope_test.go:25, 36` | `pgScopePerson` at :59, `inPerson` at :82; `personCallers` at :25, `realmTenantCallers` at :36 | **Holds** |
| 26 | Realm route gate | `csi-spl-api/src/go/spool-hub-api/internal/hub/realm.go:62-70, 108-123` | `realmCaller` rejects `tenant_named` and `member_named`; `realmRefuses` rejects act-as, clones, loads `Memberships` | **Holds** |
| 27 | Realm routes today | `csi-spl-api/src/go/spool-hub-api/internal/hub/realm.go:431-438`; `csi-spl-api/src/go/spool-hub-api/internal/hub/channel_order.go:119-120` | `routeRealm` in `realm.go`; `routeRealmHoursRead`/`Write` registered in `channel_order.go:119-120` | **Holds** |
| 28 | Settings sections | `csi-spl-wui/src/utils/settings-nav.mjs:6`; `csi-spl-wui/src/pages/settings/[[section]].vue` | `SETTINGS_SECTIONS` array at :6; `[[section]].vue` exists | **Holds** |
| 29 | Next migration | `csi-spl-rdb/src/sql/postgres/spool-hub/` | Latest migration is `0222_hours_v2_terminals.sql`; `<next>` is 0223 | **Holds** |
| 30 | Realm RLS seeds (v1.1, W1) | `store/personal_rls_test.go:274-277, 317`; `store/personal_catalogue_test.go:256` | `realmSeedPG` seeds P & Q, loops over `personalTables`; `seedRealm` plants rows of policy test | **Holds** |
| 31 | Hub env config plumbing (v1.1, W2) | `api/internal/config/config.go:281-283`; `api/cmd/spool/hub.go:319`; `hub/server.go:42`; `csi-spl-cnf/csi-spl/all.env.yaml:748` | `config.Hub` struct env tags; `baseOptions` builds `hub.Options`; `all.env.yaml` sets hub env vars | **Holds** |
| 32 | Help coverage gates (v1.1, W3, W4) | `csi-spl-wui/tests/unit/help-settings-coverage.test.mjs:32, 66-69`; `csi-spl-wui/tests/unit/help-sync.test.mjs` | `RAIL_HELP` maps rail tabs to help pages; lines 66-69 require `/settings/<id>` documented; `sync-help.mjs` syncs copy | **Holds** |

---

## 3. Detailed Empirical Judgments

### 3(a) Data and Privacy
- **Realm and RLS**: Tables `personal.notes`, `personal.note_items`, and `personal.note_links` are placed in the `personal` schema with `person_id` first (FK to `humans(human_id) ON DELETE CASCADE`).
- **Isolation**: Row-level security is both `ENABLE` and `FORCE`. The `person_scope` policy strictly requires:
  `person_id = NULLIF(current_setting('app.person_id', true), '') AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator'`.
  - Another person cannot read notes because their `app.person_id` will not match.
  - A workspace admin cannot read notes because any workspace query sets `app.tenant_id`, which fails `NULLIF(current_setting('app.tenant_id', true), '') IS NULL`. Furthermore, `realmCaller` rejects requests containing the `TenantHeader` with 400 `tenant_named`.
  - The operator cannot read notes because `current_setting('app.rls_scope', true)` equals `'operator'`, yielding 0 rows.
- **Erase and Export**:
  - `GET /v1/me/realm/notes/export` exports all notes (including archived ones) in JSON format.
  - `DELETE /v1/me/realm/notes` cascades to wipe all notes, items, and links for that person.
  - Account deletion via `humans(human_id) ON DELETE CASCADE` automatically erases all note records.
  - B10 adds the user settings surface (Export and typed confirmation Erase).

### 3(b) Links and Workspace Privacy
- **Leakage Prevention**: Notes store typed references (`msg`, `topic`, `issue`, `event`, `doc`, `channel`, `url`), workspace id, and an initial user-editable label. An object's full body or message content is never stored in `personal.note_links`.
- **Workspace Departure (D4)**: When a person leaves a workspace, `realmCaller` loads their active seats (`ml.Memberships`). If `workspace_id` is not among active memberships:
  - The link is returned with `label: ""` and `left: true`.
  - The UI displays "Link to a workspace you left".
  - Any subsequent PATCH or link update on that note zeroes out the stored label in PostgreSQL.
- **Navigation Safety**: Clicking an internal link resolves to `<origin>/...` using `tenantOrigin(workspace, ...)`. Navigating across workspace boundaries executes under the target workspace's host, where that page's own RBAC access gates evaluate permissions.

### 3(c) Build Rows and Disjointness
- **Parallel Independence (B8 & B9)**:
  - B8 files: `wui/utils/msg-menu.mjs`, `wui/components/MessageMenu.vue`, `wui/utils/msg-shortcuts.mjs`, `wui/components/IssueRowMenu.vue`, `wui/components/IssueDetailActions.vue`, `wui/components/SidebarRowMenu.vue`, `wui/components/CalendarEventDialog.vue`, `wui/components/AddToNotePicker.vue`, `wui-tests/unit/msg-menu.test.mjs`, `wui-tests/unit/msg-shortcuts.test.mjs`, new e2e test.
  - B9 files: `wui/utils/search.mjs`, `wui/components/TopBar.vue`, `wui/composables/usePaletteItems.ts`, `wui-tests/unit/search.test.mjs`, `wui-tests/unit/palette.test.mjs`.
  - File lists share zero common files; B8 and B9 can run concurrently without collision.
- **Dependencies and Ordering**: Smallest first (B1 is 6 files). Ordering B1 (hub rail order) -> B2 (DDL) -> B3 (store) -> B4 (routes) -> B5 (WUI shell) -> B6 (editor) -> B7 (links) -> B8/B9 (actions/search) -> B10 (settings) is correct.
- **B1 Precedent**: Follows commit `2835ff381` (Reporting rail entry) across the exact same 6 files and test structure.

### 3(d) Cases C1-C31 Red Controls
- Every case C1 to C31 has an empirical control that is red on master today (`851294586` / `2daeaf1fa`).
- Verified empirically: e.g. C28 `omniboxMode('/note buy milk')` returns `'send'` on master today (expected `'note'`).

### 3(e) WUI Requirements
- All strings are keyed in `en.json` and 19 locales in B5; no hardcoded UI literals; no page-meta keys.
- CSP compliance: no `:style` inline styling.
- Bundle budget: `pages/notes.vue` is an independent async route chunk.

---

## 4. Initial Review Defects (W1..W4) in v1.0

The initial review of v1.0 (`fafbb86d0`, `seat-agy.md`) returned **NOT SIGNED** and identified four defects:
- **W1 (spec.md:411, row B2 files)**: B2 omitted `store/personal_rls_test.go` and test seed requirements.
- **W2 (spec.md:353-356, 413, Section 6 and row B4 files)**: B4 omitted Go config, server options, and kill switch plumbing.
- **W3 (spec.md:414, row B5 files)**: B5 omitted `help-settings-coverage.test.mjs` (`RAIL_HELP`) and synced help files.
- **W4 (spec.md:419, row B10 files)**: B10 omitted `user-settings.md` coverage and synced help copy.

---

## 5. Re-check of v1.1 Fold on `12443cd0d` (W1..W4)

Editor c-005@sat folded all four findings into `spec.md` at `12443cd0d` on `origin/master`. Re-checked empirically:

| Defect | Fold Verified | Status |
|---|---|---|
| **W1** | Section 8 row B2 now includes `store/personal_rls_test.go` (`realmSeedPG`, v1.1 W1) and `store/personal_catalogue_test.go` (`seedRealm`). Section 1.2 row 30 explains that widening `personalTables` requires seed rows in both tests. | **OK** |
| **W2** | Section 6 redesigned cleanly: the kill switch is environment variable `SPOOL_HUB_NOTES_ENABLED` set via `all.env.yaml`, loaded through `config.go`, `cmd/spool/hub.go`, and `hub.Options`. When off, routes return 404 `notes_off`. The WUI detects 404 `notes_off` directly from `GET /v1/me/realm/notes`, avoiding session-claims bloat. Section 8 row B4 lists `hub/server.go`, `config.go`, `cmd/spool/hub.go`, and `all.env.yaml`. C15 updated to test `notes_off`. | **OK** |
| **W3** | Section 8 row B5 now lists `wui-tests/unit/help-settings-coverage.test.mjs` (`RAIL_HELP`), `doc/help/notes.md`, and its synced copies `wui/public/help-md/notes.md` + `pages.json` via `sync-help.mjs`. Section 1.2 row 32 documents the gate requirement. | **OK** |
| **W4** | Section 8 row B10 now lists `doc/help/user-settings.md` and synced copy `wui/public/help-md/user-settings.md` (documenting `/settings/notes`). Section 1.2 row 32 correctly points to coverage check lines 66-69 in `help-settings-coverage.test.mjs`. | **OK** |

All four items are correctly, cleanly, and completely addressed. No secondary defects or broken references were introduced.

---

## 6. Signature

All 32 code facts, privacy designs, link safety guarantees, red controls (C1-C31), and build row boundaries have been verified on `origin/master`. All review findings (W1..W4) are completely folded in v1.1.

**SIGN**: `a-089` (agy cross-vendor reviewer seat) signs **spec 155 v1.1** (`12443cd0d`).
