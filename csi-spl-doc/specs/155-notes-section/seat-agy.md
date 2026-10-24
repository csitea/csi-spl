# Spec 155 v1.0 (Notes section) - agy cross-vendor reviewer seat review & verdict

Seat: `a-089` (agy, cross-vendor reviewer seat).
Epic: `SPL-2403`. Issue: `SPL-3216`.
Placement slug: `c002-s155-agy-reviewer`.
Spec reviewed: `csi-spl-doc/specs/155-notes-section/spec.md` (v1.0 written by c-005@sat at `471c55f24`).
Verified on tree: `origin/master` at `851294586` (spec.md at `471c55f24`).

---

## 1. Summary of Verdicts

| # | Check / Area | Verdict | Notes |
|---|---|---|---|
| 1 | Section 1.2 code facts (29 facts) | **OK** | All 29 facts printed via `git show origin/master:<path>` and verified; all 29 hold. |
| 2 | Data and privacy (D1 personal realm, RLS, operator scope, erase / export) | **OK** | Notes reside in `personal.*` with `person_scope` RLS. Other persons, workspace admins, and operator read 0 rows. Erase/export complete. |
| 3 | Links and privacy (D7, B7, D4) | **OK** | Links store typed ref + label, no object body. Non-member workspaces return `label: ""` and `left: true`; clicks navigate to target origin where target RBAC protects content. No leakage. |
| 4 | Build rows (B1-B10 disjointness, dependencies, smallest first, precedent `2835ff381`) | **DEFECTS FOUND (W1-W4)** | Parallel rows B8 and B9 are strictly disjoint. B1 follows `2835ff381`. However, B2, B4, B5, and B10 have missing files and test seed gaps (W1-W4). |
| 5 | Cases C1-C31 with red controls | **OK** | Every case C1-C31 has a verifiable red control failing on master today. |
| 6 | WUI requirements (first-screen strings, no page-meta keys, no `:style`, CSP, chunk budget) | **OK** | Translations loaded in B5 for all 19 locales; CSS in stylesheets; `/notes` page is its own async route chunk. |

Final verdict: **NOT SIGNED** pending resolution and fold of numbered defects **W1..W4** into v1.1.

---

## 2. Section 1.2 Code Facts Verification (All 29 Facts)

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

## 4. Numbered Defects (W1..W4)

Before signing, the following four defects in the build rows and test suites must be resolved and folded into spec 155:

### W1: B2 files list omits `store/personal_rls_test.go` and test seed requirements
- **File & line**: `csi-spl-doc/specs/155-notes-section/spec.md:411` (row B2 files)
- **Problem**: In B2, `personalTables` (`store/personal_catalogue_test.go:23`) will be widened to include `notes`, `note_items`, and `note_links`. Because `store/personal_rls_test.go:264, 317` shares package `store` and iterates over `personalTables`, `TestRLSPersonStore` will fail with:
  `T-N1: inPerson(P) reads P: 0 rows of personal.<tb>, want > 0`
  unless `realmSeedPG` in `store/personal_rls_test.go:277-301` seeds rows for those three tables.
  Similarly, `seedRealm` in `store/personal_catalogue_test.go:256-288` must seed rows for those three tables so `TestRLSPersonalPolicy` passes "P reads P (control)".
- **Fix**: Add `api/internal/store/personal_rls_test.go` to B2's files list in Section 8 and document that `seedRealm` (in `personal_catalogue_test.go`) and `realmSeedPG` (in `personal_rls_test.go`) seed test rows for `personal.notes`, `personal.note_items`, and `personal.note_links`.

### W2: B4 files list omits Go config, server options, and session claims plumbing
- **File & line**: `csi-spl-doc/specs/155-notes-section/spec.md:353-356, 413` (Section 6 and row B4 files)
- **Problem**: Section 6 specifies kill switch `env.hub.notes.enabled` in `csi-spl-cnf/csi-spl/all.env.yaml`, stating that "every notes route answers 404 and the WUI hides the tab and the 'Add to note' items (the flag rides the session claims)."
  However, B4's file list includes only `hub/realm_notes.go`, `hub/realm_notes_test.go`, `hub/channel_order.go`, and `all.env.yaml`. It omits the Go config loader `api/internal/config/config.go`, server options in `api/internal/hub/server.go`, CLI instantiation in `api/cmd/spool/hub.go`, and the session claims handler in `api/internal/auth/handler.go` (or `api/internal/hub/rbac.go`). Without these files, the config flag cannot be loaded into the hub process, C15 cannot be tested against server options, and the flag cannot ride session claims into the WUI.
- **Fix**: Add `api/internal/config/config.go`, `api/internal/hub/server.go`, `api/cmd/spool/hub.go`, and the relevant session claims handler (`api/internal/auth/handler.go` or `api/internal/hub/rbac.go`) to B4's files list in Section 8.

### W3: B5 files list omits `help-settings-coverage.test.mjs` and synced help markdown files
- **File & line**: `csi-spl-doc/specs/155-notes-section/spec.md:414` (row B5 files)
- **Problem**:
  1. Adding `notes` to `RAIL_TABS` in `csi-spl-wui/src/utils/rail-order.ts` causes `csi-spl-wui/tests/unit/help-settings-coverage.test.mjs:83-88` to fail immediately on `pnpm test`:
     `RAIL_TABS has "notes" but no RAIL_HELP mapping — add a help page and map it`.
  2. Adding `csi-spl-doc/doc/help/notes.md` causes `csi-spl-wui/tests/unit/help-sync.test.mjs:18-20` to fail because the served copy in `csi-spl-wui/src/public/help-md/` drifts from `csi-spl-doc/doc/help/`.
- **Fix**: Add `csi-spl-wui/tests/unit/help-settings-coverage.test.mjs`, `csi-spl-wui/src/public/help-md/notes.md`, and `csi-spl-wui/src/public/help-md/pages.json` to B5's files list in Section 8 (precedent commit `8708821ac`).

### W4: B10 files list omits `user-settings.md` documentation coverage
- **File & line**: `csi-spl-doc/specs/155-notes-section/spec.md:419` (row B10 files)
- **Problem**: Adding `notes` to `SETTINGS_SECTIONS` in `csi-spl-wui/src/utils/settings-nav.mjs` causes `csi-spl-wui/tests/unit/help-settings-coverage.test.mjs:51-55` to fail:
  `SETTINGS_SECTIONS has "notes" but user-settings.md never names /settings/notes`.
- **Fix**: Add `csi-spl-doc/doc/help/user-settings.md` (and `csi-spl-wui/src/public/help-md/user-settings.md`) to B10's files list in Section 8.

---

## 5. Verdict

**NOT SIGNED**

The spec architecture, data privacy model, RLS guarantees, link privacy design, and case controls (C1-C31) are solid and well-conceived. Once defects **W1..W4** are folded into spec 155 v1.1, this seat will re-check and sign.
