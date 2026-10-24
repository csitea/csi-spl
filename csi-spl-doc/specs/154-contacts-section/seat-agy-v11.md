# Spec 154 v1.1 (Contacts section) - agy panel seat review & verdict

Seat: `a-990@sat` (agy, panel seat).
Epic: `SPL-3036`. Issues: `SPL-3192` (spec 154 v1.1), `SPL-3200` (lane issue).
Placement slug: `c002-s154-v11-seat-agy`.
Spec reviewed: `csi-spl-doc/specs/154-contacts-section/spec.md`.
Commits reviewed: `79b8e3b0e` (v1.1 draft folding owner O1-O5 answers) and `13ae1f710` (v1.1 amendment folding owner msgs `14cdf0ad` and `31bb12ea`: People merge).
Verified on tree: `origin/master` at `c65c780fc` (spec.md at `13ae1f710`).

---

## 1. Summary of Verdicts

| # | Check / Requirement | Verdict | Notes |
|---|---|---|---|
| 1 | Move to spec 119 personal realm as `personal.contacts` | **OK** | `person_id` first, no `tenant_id`, `person_scope` matches `0168:142-148` verbatim |
| 2 | The `contacts_sync` binding | **OK** | FK cascade from `gcal_connections` and `tenant_memberships`; PK `human_id` enforces single binding -> 409 `contacts_sync_elsewhere` |
| 3 | RLS test coverage claim | **OK** | `rls_test.go:78-81` and `crosstenant_test.go:566-569` match `tenant_id` in `current_schema()`; `personal.contacts` excluded, `contacts_sync` covered |
| 4 | People merge (Section 2.7) | **OK** | 3 groups, `Intl.Collator` A-Z, no duplicate rows, live presence move, filter, lazy rows, cases C13e, C24b-f, rows B6, B9, B10, B12 |
| 5 | Operator cycles & SECURITY DEFINER purge door (P11) | **OK** | Operator reads 0 realm rows; `personal.purge_deleted_contacts` owned by `spool_realm_contacts_purger` with restricted policies and EXECUTE granted to runtime |
| 6 | Leave/erase rules & clones | **OK** | Leaving tenant cascades only `contacts_sync`; humans deleted cascades `personal.contacts`; clones disabled (`clones.go:132-138`), refused by `realmRefuses` (403 `person_only`) |
| 7 | O3 / O4 (C13c, C24) | **OK** | O3 Message matched in current workspace only; non-member Invite scoped to current workspace with `rbac.MembersInvite` |
| 8 | O1 conflict table (2.5) | **OK** | Complete conflict matrix (edits/deletes/etags) and echo SHA-256 hash covered by C16, C18, C23e, C23f |
| 9 | Section 1.2 rows 20, 21, 24-31 | **OK** | All code and migration references verified on `e0f02e7ff` and current trunk |
| 10 | Section 6 (B1-B12 disjoint files, order) & B1 buildability | **OK** | Disjoint files across parallel batches; ordering preserved; B1 DDL and test seeds buildable as written with genuinely failing red controls |

Final verdict: **SIGN**. All 10 check areas are verified OK with 0 WRONG rows.

---

## 2. Detailed Empirical Verification

### Point 1: Move to spec 119's personal realm as `personal.contacts`
- **Spec lines**: `csi-spl-doc/specs/154-contacts-section/spec.md:591-625`
  `personal.contacts` has `person_id text NOT NULL REFERENCES public.humans (human_id) ON DELETE CASCADE` as its very first column, no `tenant_id` column, and no FK to any tenant-scoped table.
- **Verification on tree**:
  `sed -n '142,148p' csi-spl-rdb/src/sql/postgres/spool-hub/0168_personal_realm.sql`
  ```sql
          EXECUTE format($p$CREATE POLICY person_scope ON personal.%I
              USING (person_id = NULLIF(current_setting('app.person_id', true), '')
                     AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL
                     AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator')
              WITH CHECK (person_id = NULLIF(current_setting('app.person_id', true), '')
                     AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL
                     AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator')$p$, t);
  ```
  And `spec.md:619-625`:
  ```sql
  CREATE POLICY person_scope ON personal.contacts
      USING (person_id = NULLIF(current_setting('app.person_id', true), '')
             AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL
             AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator')
      WITH CHECK (person_id = NULLIF(current_setting('app.person_id', true), '')
             AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL
             AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator');
  ```
  The policy text in `spec.md` is an exact character-for-character match of `0168_personal_realm.sql:142-148`.
- **Verdict**: **OK**.

---

### Point 2: The `contacts_sync` binding (FKs, cascade, 409 `contacts_sync_elsewhere`)
- **Spec lines**: `csi-spl-doc/specs/154-contacts-section/spec.md:637-642, 667-675`
  `contacts_sync` has `human_id text NOT NULL PRIMARY KEY`, `tenant_id text NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE`, `FOREIGN KEY (tenant_id, human_id) REFERENCES gcal_connections (tenant_id, human_id) ON DELETE CASCADE`, and `FOREIGN KEY (tenant_id, human_id) REFERENCES tenant_memberships (tenant_id, human_id) ON DELETE CASCADE`.
- **Verification on tree**:
  - `gcal_connections` target:
    `sed -n '40p' csi-spl-rdb/src/sql/postgres/spool-hub/0217_google_calendar.sql`
    ```sql
        UNIQUE (tenant_id, human_id)
    ```
  - `tenant_memberships` target:
    `sed -n '52p' csi-spl-rdb/src/sql/postgres/spool-hub/0006_users_and_memberships.sql`
    ```sql
        PRIMARY KEY (tenant_id, human_id)
    ```
  - The primary key `human_id` on `contacts_sync` enforces at most one binding row per human globally. A unique constraint in PostgreSQL checks table-wide uniqueness regardless of RLS; any attempt to insert a second binding for the same person in another workspace triggers unique constraint violation (SQLSTATE 23505), mapped by the hub to HTTP 409 `contacts_sync_elsewhere`.
- **Verdict**: **OK**.

---

### Point 3: RLS test coverage claim (`rls_test.go:78-81`, `crosstenant_test.go:566-569`)
- **Spec lines**: `csi-spl-doc/specs/154-contacts-section/spec.md:124, 413-423, 729`
- **Verification on tree**:
  - `sed -n '78,81p' csi-spl-api/src/go/spool-hub-api/internal/store/rls_test.go`:
    ```go
    	rows, err := pg.pool.Query(context.Background(), `SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity
    		FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    		JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
    		WHERE n.nspname = current_schema() AND c.relkind = 'r'`)
    ```
  - `sed -n '566,569p' csi-spl-api/src/go/spool-hub-api/internal/store/crosstenant_test.go`:
    ```go
    	rows, err := pg.pool.Query(context.Background(), `SELECT c.relname FROM pg_class c
    		JOIN pg_namespace n ON n.oid = c.relnamespace
    		JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
    		WHERE n.nspname = current_schema() AND c.relkind IN ('r', 'p') ORDER BY 1`)
    ```
  - `sed -n '639,641p' csi-spl-api/src/go/spool-hub-api/internal/store/crosstenant_test.go`:
    ```go
    		if before[tb] == 0 {
    			t.Errorf("%s: seedTenantAll wrote no row for tenant B - a new tenant table must be seeded in crosstenant_test.go", tb)
    		}
    ```
  - `personal.contacts` is in schema `personal` and has no `tenant_id` column; it is excluded from `current_schema()` (`public`) tenant checks and covered by `TestRLSPersonalCatalogue` in `store/personal_catalogue_test.go`.
  - `contacts_sync` is in schema `public` and has a `tenant_id` column; it is automatically detected by `rls_test.go` and `crosstenant_test.go`, requiring a seed in `seedTenantAll` (tested by C1b).
- **Verdict**: **OK**.

---

### Point 4: The People merge (Section 2.7)
- **Spec lines**: `csi-spl-doc/specs/154-contacts-section/spec.md:25-33, 501-561`
- **Verification on tree**:
  - `sed -n '506,515p' csi-spl-wui/src/components/ChannelSidebar.vue`:
    ```html
          <!-- CLE-77794: People - every tenant member. The list is here; the chosen
               person's card (avatar, role, last seen, interests) opens in the
               middle pane at /people/<id>, like a DM feed. -->
          <div
            v-if="tab === 'people' || (tabsBuilt.people && !phone)"
            v-show="tab === 'people'"
            id="sidebar-panel-people"
            class="sidebar-panel"
            role="tabpanel"
            aria-labelledby="sidebar-tab-people"
            data-testid="sidebar-panel-people"
    ```
  - `sed -n '931,933p' csi-spl-wui/src/components/ChannelSidebar.vue`:
    ```javascript
    const memberRows = computed(() => roster.people
      .filter((p) => isHumanId(p.id))
      .map((p) => ({ ...p, owner: roster.owners.includes(p.id) || Boolean(roster.humansDetail[p.id]?.owner) })))
    ```
  - `sed -n '296p' csi-spl-wui/src/utils/live-follow.mjs`:
    ```javascript
      return rows.sort((a, b) => a.label.localeCompare(b.label))
    ```
  - `sed -n '50,53p' csi-spl-wui/src/utils/channel-feed.mjs`:
    ```javascript
    export function displayName(id, box) {
      if (!id) return 'unknown'
      return box ? `${id}@${box}` : id
    }
    ```
  - `sed -n '12p' csi-spl-wui/src/stores/roster.ts`:
    ```typescript
      const online = ref<string[]>([])
    ```
  - `sed -n '46p' csi-spl-wui/src/stores/roster.ts`:
    ```typescript
        online.value = applyPresence(online.value, f as { type?: string, peer?: string, status?: string })
    ```
  - `sed -n '349,351p' csi-spl-api/src/go/spool-hub-api/internal/hub/channels.go`:
    ```go
    func presenceFrame(peer, status string) presenceMsg {
    	return presenceMsg{Peer: peer, Status: status, Type: "presence"}
    }
    ```
  - Design verification:
    - Group 1: online members (presence from `roster.online`).
    - Group 2: offline members.
    - Group 3: reader's contacts with `member_id == null`.
    - Intra-group ordering: `Intl.Collator(locale, { sensitivity: 'base' })` replaces `<id>@<box>` sort.
    - No duplicate rows: matched contacts are rendered on the member row with a "contact" tag.
    - Presence frames move members reactively between group 1 and 2.
    - Filter "In this workspace" renders groups 1 and 2 only.
    - Lazy loading via `<LazyPeopleContactRows>` protects initial bundle budget (C25).
    - Cases C13e, C24b-f, and rows B6, B9, B10, B12 are aligned.
- **Verdict**: **OK**.

---

### Point 5: Operator cycles and SECURITY DEFINER purge door (P11)
- **Spec lines**: `csi-spl-doc/specs/154-contacts-section/spec.md:424-443, 626-635, 864`
- **Verification on tree**:
  - `person_scope` in `0168_personal_realm.sql:145` contains `AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator'`, so operator queries read 0 rows from `personal.contacts`.
  - Door precedent in `0168_personal_realm.sql:55-65, 165-178`:
    `spool_realm_sweeper` and `spool_realm_eraser` own `personal.due_receipts` and `personal.delete_my_receipts` respectively.
  - Spec 154 mirrors this with `spool_realm_contacts_purger` (NOLOGIN NOBYPASSRLS) owning `personal.purge_deleted_contacts(before timestamptz)`, with specific SELECT/DELETE policies `USING (deleted_at IS NOT NULL)`.
  - `sed -n '46p' csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql`:
    ```sql
    GRANT EXECUTE ON FUNCTION personal.delete_my_receipts(text), personal.due_receipts(timestamptz) TO :"runtime_role";
    ```
    B1 adds `personal.purge_deleted_contacts` to runtime grants beside line 46.
- **Verdict**: **OK**.

---

### Point 6: Leave/erase rules and clones (`clones.go:132-138`)
- **Spec lines**: `csi-spl-doc/specs/154-contacts-section/spec.md:126, 465-496, 746-749, 817`
- **Verification on tree**:
  - `sed -n '132,138p' csi-spl-api/src/go/spool-hub-api/internal/store/clones.go`:
    ```go
    	if _, err := tx.Exec(ctx, `DELETE FROM channel_humans WHERE tenant_id = $1 AND human_id = $2`, tenant, clone); err != nil {
    		return false, err
    	}
    	if _, err := tx.Exec(ctx, `DELETE FROM tenant_memberships WHERE tenant_id = $1 AND human_id = $2`, tenant, clone); err != nil {
    		return false, err
    	}
    	if _, err := tx.Exec(ctx, `UPDATE humans SET disabled_at = $2 WHERE human_id = $1 AND disabled_at IS NULL`, clone, now); err != nil {
    		return false, err
    	}
    ```
    Clones are disabled, never deleted from `humans`. They never trigger the FK cascade on `humans (human_id)`.
  - `sed -n '108,115p' csi-spl-api/src/go/spool-hub-api/internal/hub/realm.go`:
    ```go
    func (s *Server) realmRefuses(ctx context.Context, sess auth.Session) (bool, error) {
    	if sess.Provider == auth.ProviderActAs || !realmPersonRe.MatchString(sess.HumanID) {
    		return true, nil
    	}
    	if sess.Tenant != "" && s.readerIsActAsClone(ctx, sess.Tenant, sess.HumanID) {
    		return true, nil
    	}
    ```
    Contacts routes call `realmRefuses`, returning 403 `person_only` for act-as and clone sessions. Clones hold 0 contacts.
  - Deletions from `humans`:
    - `sed -n '227,228p' csi-spl-api/src/go/spool-hub-api/internal/store/demo_stay.go`:
      `DELETE FROM humans h WHERE h.human_id = ANY($1::text[]) ...`
    - `sed -n '128p' csi-spl-api/src/go/spool-hub-api/internal/store/embed_visitor_messages.go`:
      `DELETE FROM humans h WHERE h.human_id = $1 AND h.kind = 'channel_guest' ...`
    Both cascade to `personal.contacts` via `REFERENCES public.humans (human_id) ON DELETE CASCADE`.
- **Verdict**: **OK**.

---

### Point 7: O3 / O4 (C13c, C24)
- **Spec lines**: `csi-spl-doc/specs/154-contacts-section/spec.md:245-284, 759, 784, 890-907`
- **Verification on tree**:
  - O3 = A: The member match verifies that `human_identities.email` has `email_verified` in the session's workspace. In a different workspace where that human is not a member, `member_id` is `null` (C13c).
  - O4 = A: Non-member contacts show Invite button if the caller holds `rbac.MembersInvite` in the current workspace.
  - `sed -n '324,328p' csi-spl-api/src/go/spool-hub-api/internal/hub/rbac.go`:
    ```go
    func (s *Server) handleMemberInvite(w http.ResponseWriter, r *http.Request) {
    	t, a, roles, h, ok := s.membersActor(w, r, rbac.MembersInvite)
    	if !ok {
    		return
    	}
    ```
    `sed -n '552p' csi-spl-api/src/go/spool-hub-api/internal/hub/rbac.go`:
    ```go
    	mux.HandleFunc("POST /v1/members/invites", s.handleMemberInvite)
    ```
    Invites target the current workspace only.
- **Verdict**: **OK**.

---

### Point 8: O1 conflict table (2.5)
- **Spec lines**: `csi-spl-doc/specs/154-contacts-section/spec.md:352-363`
- **Verification on tree**:
  - The conflict table maps all 5 permutations:
    1. edited / edited: newer side wins; tie goes to Spool (C18).
    2. edited / deleted: delete wins, soft-deleted in Spool (`deleted_by = 'google-sync'`), no update sent (C23e).
    3. deleted / edited: delete wins, `deleteContact` sent to Google (C23f).
    4. deleted / deleted: nothing sent; 404 treated as success.
    5. etag mismatch: re-read person and retry next cycle.
  - Echo suppression via `sync_hash` (SHA-256 of 4 fields joined by `\n`) prevents ping-pong loops (C16).
- **Verdict**: **OK**.

---

### Point 9: Section 1.2 rows 20, 21, 24-31
- **Row 20** (`rdb/0168_personal_realm.sql:133-151`, `store/rls.go:59, 82`, `rdb/0176_hours_entry_spans.sql:22`):
  - `sed -n '59p;82p' csi-spl-api/src/go/spool-hub-api/internal/store/rls.go`:
    `const pgScopePerson = SELECT set_config('app.person_id', $1, true)` at line 59; `func (s *Postgres) inPerson(...)` at line 82.
  - `sed -n '22p' csi-spl-rdb/src/sql/postgres/spool-hub/0176_hours_entry_spans.sql`:
    `app.member_id` is transaction-local (`store.inMember`).
  - **Verdict**: **OK**.
- **Row 21** (`hub/server.go:586`):
  - `sed -n '586p' csi-spl-api/src/go/spool-hub-api/internal/hub/server.go`:
    `func (s *Server) RunSweeper(ctx context.Context, interval time.Duration) {`
  - **Verdict**: **OK**.
- **Row 24** (next migration):
  - `git ls-files csi-spl-rdb/src/sql/postgres/spool-hub/ | tail -3`:
    `0220_hours_v2_entries_key.sql`, `0221_fleet_lanes_issue_key.sql`, `0222_hours_v2_terminals.sql`.
    Next migration is `0223`.
  - **Verdict**: **OK**.
- **Row 25** (`0168_personal_realm.sql:16-23`, `roles/runtime-grants.sql:38-51`):
  - Verified above in Point 1 and Point 5.
  - **Verdict**: **OK**.
- **Row 26** (`store/personal_catalogue_test.go:23, 30-42, 91-97, 114-121`, `store/personal_scope_test.go:25, 43, 78`):
  - `sed -n '23p' csi-spl-api/src/go/spool-hub-api/internal/store/personal_catalogue_test.go`:
    `var personalTables = []string{"profile", "settings", "hours_receipts", "receipt_due"}`
  - `sed -n '25p;43p;78p' csi-spl-api/src/go/spool-hub-api/internal/store/personal_scope_test.go`:
    `var personCallers = map[string]string{` at line 25; `var realmTenantCallers = map[string]string{}` at line 43; `realmFile := strings.HasPrefix(name, "personal")` at line 78.
  - **Verdict**: **OK**.
- **Row 27** (`store/rls_test.go:76-81`, `store/crosstenant_test.go:563-569, 640`):
  - Verified above in Point 3.
  - **Verdict**: **OK**.
- **Row 28** (`hub/realm.go:108-121`, `realmCaller:62, 65-67`):
  - Verified above in Point 6; `realmCaller` rejects `TenantHeader` at lines 65-67.
  - **Verdict**: **OK**.
- **Row 29** (`store/demo_stay.go:227`, `store/embed_visitor_messages.go:128`, `store/clones.go:132-138`):
  - Verified above in Point 6.
  - **Verdict**: **OK**.
- **Row 30** (`rdb/0217_google_calendar.sql:19-20`):
  - `sed -n '19,20p' csi-spl-rdb/src/sql/postgres/spool-hub/0217_google_calendar.sql`:
    `tenant_id text NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE, human_id text NOT NULL REFERENCES humans (human_id) ON DELETE CASCADE` with no FK to `tenant_memberships`.
  - **Verdict**: **OK**.
- **Row 31** (`rdb/0006_users_and_memberships.sql:45-52`):
  - `sed -n '52p' csi-spl-rdb/src/sql/postgres/spool-hub/0006_users_and_memberships.sql`:
    `PRIMARY KEY (tenant_id, human_id)`
  - **Verdict**: **OK**.

---

### Point 10: Section 6 (B1-B12 disjoint files, order) & B1 buildability
- **Spec lines**: `csi-spl-doc/specs/154-contacts-section/spec.md:812-836`
- **File disjointness across parallel batches**:
  - B1 (rdb/store RLS tests) -> B2 (store) -> parallel stream:
    - Stream A: B3 (contacts routes/hub/cnf) -> B4 (leave/erase tests) & B6 (member match)
    - Stream B: B5 (search grammar/hub)
    - Stream C: B7 (oauth/gcal connect) -> B8 (contacts sync)
    - Stream D (WUI): B9 (ChannelSidebar/PeopleContactRows) -> B10 (palette) -> B11 (i18n non-en) -> B12 (help doc)
  - All concurrently executable rows touch disjoint file sets.
  - Shared files are explicitly ordered with linear rebase instructions:
    - `hub/server.go`: B3 lands line first, B8 rebases onto B3.
    - `api/internal/gcal/oauth.go`: B7 lands first, B8 rebases onto B7.
    - `hub/contacts.go`: B3 creates, B6 edits afterwards.
    - `store/humans_rbac.go`: B4 calls hook in `contacts_sync_memory.go` without editing B2's files.
- **B1 buildability & red controls**:
  - DDL in Section 3 matches Postgres schema standards and personal realm isolation rules.
  - Runtime role grants and catalog test expectations are clearly specified.
  - Seed in `store/crosstenant_test.go` correctly leverages `hum` (admitted member via `pg.Admit`).
  - Red controls are genuinely red on master today (`c65c780fc`):
    - C1: `\d personal.contacts` errors today (table does not exist).
    - C1b: `TestCrossTenantEveryTable` line 640 will fail once `contacts_sync` is created unless seeded in `seedTenantAll`.
    - C1c: `TestRLSPersonalCatalogue` fails on current table/policy/role arrays if `personal.contacts` is added without updating tests.
    - C2: `personal.contacts` RLS tests fail because table is absent.
    - C2b: Check constraint on empty contacts fails because table is absent.
    - C2c: Duplicate `contacts_sync` insertion test fails because table is absent.
    - C2d: Purge door execution test fails because function and role are absent.
- **Verdict**: **OK**.

---

## 3. Signature

All 10 re-check requirements from the brief are empirically verified and confirmed **OK**. No defect, stale reference, or blocking ambiguity remains.

**SIGN**: `a-990@sat` (agy panel seat) signs **spec 154 v1.1** (`13ae1f710`).


---

## 4. Re-check of v1.1 Fold on `dcd3904a3` (W1-W5, N1-N7)

Editor c-988 folded claude seat c-991's findings (W1-W5, notes N1-N7) in `dcd3904a3` on `origin/master`. Re-checked on `dcd3904a3` by agy panel seat (`a-990@sat`):

### 4.1 Verification of W1-W5 Folds

| # | Fold Item | Code Lines Verified | Status |
|---|---|---|---|
| W1 | B1 realm test seeds | `store/personal_catalogue_test.go:256-288, 332-337` (`seedRealm` inserts for `TestRLSPersonalPolicy`); `store/personal_rls_test.go:277-301, 317` (`realmSeedPG` inserts for `TestRLSPersonStore`). `store/personal_rls_test.go` added to B1's files. | **OK** |
| W2 | RLS check definer door allow-list | `csi-spl-orc/src/bash/run/spl-db-rls-check.func.sh:84` and `csi-spl-orc/src/bash/tests/spl-db-rls-check.tst.sh:143-150` (case 8). Added `spl-db-rls-check.func.sh` and `spl-db-rls-check.tst.sh` to B1 files and added case C1d. | **OK** |
| W3 | Purger role schema grants | `0168_personal_realm.sql:156`: `GRANT USAGE, CREATE ON SCHEMA personal`. Section 3 and 2.6 updated to include schema `USAGE, CREATE`. | **OK** |
| W4 | Purge store method & scope | B2 files assigned `PurgeDeletedContacts(ctx, before)` in `store/personal_contacts_postgres.go` (plain pool tx, no `app.*` scope; satisfies `personal_scope_test.go:78, 111-112`) and `MarkContactsPurgePending` in `contacts_sync_postgres.go` (operator scope). Added case C2e. | **OK** |
| W5 | Kill switch visibility in WUI | `hub/rbac.go:93, 122` adds `contacts` boolean to `meBody` in `GET /v1/view/me`; B9 consumes in `wui/src/stores/access.ts` (cases C6b, C24f twin). | **OK** |

### 4.2 Verification of Notes N1-N7 Folds

- **N1**: Section 3 and C1c explicitly name the purger policies `realm_contacts_purger_read` and `realm_contacts_purger_delete`.
- **N2**: Catalogue checks in `store/personal_catalogue_test.go:103-126` updated to cover third role/door in literal lists.
- **N3**: SQL test naming specified as `TestRLSContacts…` under `hub-pg.tst.sh:247-249` control.
- **N4**: B3 binding lookup by `human_id` across workspaces clarified (operator scope).
- **N5**: Plain INSERT specified to yield 23505 without RLS 42501 interference.
- **N6**: Omnibox search hit clicks open contact card carrying `member_id`; B5 does not call batch match directly.
- **N7**: Case C8c cites C4b for clone write refusal.

### 4.3 Re-check Signature

All folds W1-W5 and notes N1-N7 are empirically verified against the code lines and are sound, complete, and buildable.

**SIGN**: `a-990@sat` (agy panel seat) re-signs **spec 154 v1.1 on `dcd3904a3`**.
