# Spec 154 v1.1: the claude seat's check (c-991@sat)

Spec 154 v1.1 draft plus its People-merge amendment, checked by the claude
review seat. Issue SPL-3201 (seat), spec issue SPL-3192, epic SPL-3036.

- Tree: origin/master `e83f5407c`.
  `git log -1 --format=%h -- csi-spl-doc/specs/154-contacts-section/spec.md`
  -> `13ae1f710`, so the spec is unchanged since the amendment.
- Each row was read on that tree with `sed -n`, `grep -n` or `git grep -n`.
  The line given is what the command printed. Nothing was run against
  Postgres, prd or Google: a claim about what a test would do is read from
  the test's code, and is marked "(read, not run)".

**Verdict: NOT SIGNED. 5 rows are WRONG.** Two of them, W1 and W2, are in
B1: B1 as written would go red in its own test command (W1), or leave a
post-deploy check failing (W2). W3 is in B1's DDL. W4 and W5 are not in B1;
they are B2/B3 and B3/B9. The notes (N) are small and do not block a
signature.

## 1. WRONG: to fold

| # | where | what is wrong | evidence on `e83f5407c` | fold |
|---|---|---|---|---|
| W1 | 6 row B1 (files), 1.2 row 26, C1c | B1 adds `contacts` to `personalTables` (:23), and two `^TestRLS` tests then need a contacts row for each person. Neither test is in B1's file list, and one of them is in a file B1 may not touch. `TestRLSPersonalPolicy` (`personal_catalogue_test.go:382`) loops `for _, tb := range personalTables` (:332) with the case `{"P reads P (control)", ..., true}` (:337) -> "0 rows, want > 0". Its seed `seedRealm` (:256, the inserts :269-288) seeds only the four realm tables. `TestRLSPersonStore` (`personal_rls_test.go:308`) loops the same list (:317) and errors with "0 rows of personal.%s, want > 0". Its seed `realmSeedPG` (:277-301) writes no contact. B1's own command `-run 'TestRLS…'` runs both (read, not run) | `grep -n 'personalTables' store/*.go` -> `personal_catalogue_test.go:23,294,332`, `personal_rls_test.go:264,317`. `grep -c personal_rls_test spec.md` -> 0 | add `store/personal_rls_test.go` to B1's files: one raw `INSERT INTO personal.contacts` per person in `realmSeedPG`, as the migrate login under `set_config('app.person_id', …)`, as its `receipt_due` insert does (:291-297), because B2's store does not exist yet. Also name the `seedRealm` insert, in `personal_catalogue_test.go` (already B1's file) |
| W2 | 6 row B1, 2.6 P11 | the new SECURITY DEFINER door makes `do_spl_db_rls_check` exit 5 with `EXPECT_NOT_LIFTABLE=1` on dev and prd once B1 is deployed. The check lists every definer the runtime can EXECUTE as a lift path, except an allow-list by exact name: `AND NOT (n.nspname = 'personal' AND p.proname IN ('due_receipts', 'delete_my_receipts'))` (`csi-spl-orc/src/bash/run/spl-db-rls-check.func.sh:84`). spec 119 added its two doors there, with test case 8 (`csi-spl-orc/src/bash/tests/spl-db-rls-check.tst.sh:143-…`). `spl-db-owner-split.func.sh:126` tells the operator to run this check with `EXPECT_NOT_LIFTABLE=1` | `sed -n 80,85p spl-db-rls-check.func.sh` | add to B1's files: `purge_deleted_contacts` in the allow-list at :84 and its `@description` (:15-21), plus a case in `spl-db-rls-check.tst.sh` with a red control (an unlisted definer is exit 5, as case 7's `second_definer`, :137-139). Gate: `bash csi-spl-orc/src/bash/tests/spl-db-rls-check.tst.sh` |
| W3 | 3 (the purge door comment), 2.6 | the purger role's grants are written as "column SELECT (…) and DELETE on personal.contacts only". That is too few for the migration to run. The door is created AS the role (`SET LOCAL ROLE`, 0168:167, :181), so the role needs `USAGE, CREATE ON SCHEMA personal`, as 0168 gives its two roles. Without it, the CREATE FUNCTION in `personal` is refused (read, not run). "created and granted as 0168:51-75" points at the role DO block only, not at the schema grant | `sed -n 156p 0168_personal_realm.sql` -> `GRANT USAGE, CREATE ON SCHEMA personal TO spool_realm_sweeper, spool_realm_eraser;` | section 3 and 2.6: add "`USAGE, CREATE ON SCHEMA personal` (0168:156)" to the purger's grants, and drop "only", or say "on tables, only" |
| W4 | 6 rows B2 and B3, 2.6 (the purge) | no row writes the store method that calls `personal.purge_deleted_contacts`, and the spec does not say which scope it runs in. B2's realm files are "the list, `inPerson` only". B3 has "the purge door call on `RunSweeper`'s retention", but B3's files are hub only. The scope matters: a function in a `personal*` file that opens `asOperator` or `inTenant` is "mixed" and fails `TestPersonScopeCallers` ("realm code opening a tenant or operator scope: new …"), and the spec says `realmTenantCallers` stays empty. No precedent exists to copy: `grep -rn due_receipts internal --include=*.go \| grep -v _test` -> nothing, so no Go code calls a realm door yet | `personal_scope_test.go:78` `realmFile := strings.HasPrefix(name, "personal")`; :111-112 `if tenant && (person \|\| realmFile) { sc.mixed[fn] = true }` | B2: name the method (for example `PurgeDeletedContacts(ctx, before)` in `personal_contacts_postgres.go` + memory). It runs the door in a plain pool transaction with no `app.*` setting (the door's own policies need none), never `asOperator`. The `status_detail` write is a separate method in `contacts_sync_postgres.go` under `asOperator`. Add a case: C2d's runtime-level twin, through the store |
| W5 | 2.7 (kill switch), 2.9, C24f, 6 rows B3 and B9 | C24f expects "`GET /v1/me/contacts` not called" in a workspace outside `contacts.workspaces`. But no route or field tells the WUI whether the workspace is inside the switch: 2.9 and section 4 only make every `/v1/me/contacts*` answer 404. So the WUI can learn the switch only by calling the route, which C24f forbids, so B9 cannot build C24f as written. Spec 149's `calendar-google` section is not landed to copy from: `ls csi-spl-wui/src/components/settings/` has no `calendar-google.vue` | `grep -n 'contacts.workspaces' spec.md` -> lines in 2.7, 2.9 and 3, none a field the WUI reads | B3: expose the switch on a response the WUI already loads, for example a `contacts: true\|false` field on the session's workspace view, and name it in section 4. Or change C24f to "called once, 404, panel shows members only" |

## 2. Checked OK

| what the brief asked | result | line on `e83f5407c` |
|---|---|---|
| `personal.contacts` follows the realm rule (row 25) | OK | `0168:16-23` (person_id first, FK humans CASCADE, no tenant_id, ENABLE+FORCE, one policy, no operator_scope); the DDL in section 3 has `person_id` first, which T-C2 needs (`personal_catalogue_test.go:65` `a.attnum = 1 AND a.attname = 'person_id'`) |
| `person_scope` text = `0168:142-148` | OK, identical | the USING and WITH CHECK in section 3 match `0168:143-148` character for character. T-C1 also needs `qual = with_check` (:47), and they are equal |
| `app.person_id` only from `inPerson` (row 20) | OK | `store/rls.go:59` `const pgScopePerson = …`, :82 `func (s *Postgres) inPerson`; `0176:22` names `app.member_id` / `store.inMember` |
| the realm's tests (row 26) | OK as cited; the B1 list is short (W1, N2) | `personal_catalogue_test.go:23` `personalTables`, :30-42 the table and policy lists, :91-97 the runtime grants, :114-121 `HAVING count(*) <> 2`; `personal_scope_test.go:25` `personCallers`, :43 `realmTenantCallers = map[string]string{}`, :78 the `personal` prefix |
| workspace-table RLS tests (row 27) | OK | `rls_test.go:76` `TestRLSCoversEveryTenantTable`, query :78-81 picks `attname = 'tenant_id'` in `current_schema()`; `crosstenant_test.go:563` `tenantTables`, :630 `TestCrossTenantEveryTable`, :640 "seedTenantAll wrote no row". `personal.contacts` (other schema, no tenant_id) is outside both; `contacts_sync` is inside both |
| B1 seed of `contacts_sync`, "that it holds a membership is unchecked" | OK: the seeded human is a member. B1 can drop "unchecked" and "if it does not, B1 seeds one" | `crosstenant_test.go:159-160` `hum, err := pg.Admit(…, s.tenant, AdmitPolicy{BootstrapOwner: true}, now) // tenant_memberships`; :495 `seedGcal(ctx, pg, s.tenant, hum, ev.ID)` (the func is at :504, not :503). No `RemoveMember` of `hum` in `seedTenantAll` (grep -> none) |
| the census on `contacts_sync` (:668-718) | OK (read, not run) | `UPDATE … SET tenant_id = tenant_id` leaves the key as it is, so no FK runs. The DELETE reaches A's rows only. The re-stamp to B fails on WITH CHECK. A's DELETE of `gcal_connections` / `tenant_memberships` now cascades into A's `contacts_sync` inside the rolled-back transaction, and FK actions bypass RLS |
| `contacts_sync` FKs (row 30, 31; section 3) | OK | target `UNIQUE (tenant_id, human_id)` `0217:40`; `tenant_memberships` `PRIMARY KEY (tenant_id, human_id)` `0006:52`, unchanged since (`grep -l 'ALTER TABLE tenant_memberships' rdb/*.sql` -> 0021, 0044, 0073, 0074, 0078, 0113; none touches the PK). `gcal_connections` has no membership FK: `0217:19-20` |
| 409 `contacts_sync_elsewhere` from the PK | OK, with N5 | a unique check is not filtered by RLS, so a plain INSERT of a second `human_id` from W2 fails 23505 even though W1's row is invisible |
| the four membership-delete paths and leave (2.6) | OK | `git grep -ln 'DELETE FROM tenant_memberships' -- csi-spl-api ':!*_test.go'` -> `clones.go`, `demo_stay.go`, `embed_visitor_messages.go`, `humans_rbac_postgres.go` (4). Postgres `BanMember` calls `removeMemberTx` (`demo_bans.go:104-107`). Memory: `humans_rbac.go:186` comment "(BanMember shares it)", :197 `delete(s.hum.members, k)` |
| who deletes a human (row 29) | OK | `git grep -n 'DELETE FROM humans' -- csi-spl-api ':!*_test.go'` -> `demo_stay.go:227` (no membership left, :228), `embed_visitor_messages.go:128` (`kind = 'channel_guest'`) |
| clones (row 29, P10) | OK | `clones.go:132` channel_humans, :135 `DELETE FROM tenant_memberships`, :138 `UPDATE humans SET disabled_at` |
| the person gate (row 28) | OK | `hub/realm.go:108` `func (s *Server) realmRefuses`: ProviderActAs / not `^HUM-[0-9]+$`, `readerIsActAsClone` when `sess.Tenant != ""`, `realmSeatsNotPerson`; `realmCaller` :62, the tenant-header refusal :65-67 (contacts routes must NOT use `realmCaller`, and the spec says so) |
| the purge door's shape (P11) | OK apart from W3, N1 | precedent `0168:168-176` `due_receipts`, owner role, `SET search_path = pg_catalog, pg_temp`, EXECUTE revoked from PUBLIC, WITH GRANT OPTION to the migrator (:177-178); `receipt_due` already carries a second policy `TO` a realm role (`realm_sweeper_read`, :213-215), so a table with extra `TO <role>` policies is the precedent |
| grants (section 3 key choices) | OK | `roles/runtime-grants.sql:16` ON ALL TABLES IN SCHEMA public, :1-4 run after every migrate, :10-13 the default privileges, :45-51 the `personal` grants by name, :51 the doors' EXECUTE |
| next migration (row 24) | OK | `ls rdb/ \| tail -3` -> `0220…`, `0221_fleet_lanes_issue_key.sql`, `0222_hours_v2_terminals.sql`: `<next>` = 0223 |
| sweeper (row 21) | OK | `hub/server.go:586` `func (s *Server) RunSweeper`; its retention sweep logs at :617-621 |
| People merge rows 32-35 | OK | `ChannelSidebar.vue:506` the People comment, :512 `id="sidebar-panel-people"`, :531 `/people/` link, :540-541 the you/owner tags, :931-933 `memberRows`; `roster.ts:12` `online`, :38 `peopleRows`, :46 `applyPresence`, :62 `mergeSnapshotOnline`, :79 in `isOnline`; `live-follow.mjs:203` `applyPresence`, :284 `lit.has(label)`, :296 `rows.sort((a, b) => a.label.localeCompare(b.label))`; `channel-feed.mjs:50-53` `${id}@${box}`; `hub/channels.go:349-351` `presenceFrame` |
| People cards and help (row 35) | OK | `pages/people/[id].vue:1-4`, :48 the Message button (its `message()` :140-141 opens `/dm/<HUM>@box-wui`); `pages/people/index.vue:12` `people.empty`; `public/help-md/people.md:3-5`; `csi-spl-doc/doc/help/people.md` exists |
| 2.7 A-Z by shown name | OK | `components/HumanName.vue` exists and renders each People row (`ChannelSidebar.vue:536`) |
| palette, rail, omnibox (rows 10, 12, 13) | OK | `usePaletteItems.ts:40` six groups, :88-89 `personRows` -> `/dm/<label>`; `rail-order.ts:20` `RAIL_TABS`, :45 `people`; `TopBar.vue:1-4`; `omnibox.ts:5-7` |
| O3 match key (2.4, C13b) | OK | `0006:23-24` `humans.email` "informational, not unique"; `0006:34-35` `human_identities.email`, `email_verified` |
| O4 invite (2.4, C24) | OK | `hub/rbac.go:552` the route, :324 handler, :325 `rbac.MembersInvite`, body :329-336 |
| O1 conflict table (2.5) | OK: the five rows agree with the Out bullet, the delete bullets and C18, C23e, C23f; unchecked Google behaviour is marked | - |
| 149's client (rows 15, 17, 18; 2.2) | OK | `gcal/oauth.go:58` `Scopes … cnf gcal.scopes`, :167 `AuthorizeURL(state string)`, :172 scope, :174 `include_granted_scopes`, :175 `prompt consent`, :204-206 no-refresh refusal, :210 `ErrInvalidGrant` comment, :235 / :247 `Scope`; `auth/idp.go:146` `access_type online`; `cnf/all.env.yaml:704`; `marketing/seal.go:87, :115, :139` |
| 149 hub side absent (row 16) | OK | `git ls-tree --name-only HEAD csi-spl-api/src/go/spool-hub-api/internal/hub/ \| grep -c gcal` -> 0 |
| rows 1-11, 14, 19, 22, 23 | OK | `0006:19-27`, `:30-39`, `:45`; `0193:19`, :21-23; `member_directory.go:20`; `store/search.go:87`; `view.go:38`; `server.go:416`; `wui.go:368, :571, :859-860`; `hub/search.go:50, :111, :484-485`; `search/grammar.go:30-45`; `0217:17-41`, :42; `0187:107-114`; `hours_team.go:348`; `embed_visitor.go:52`; `rbac.go:556`, :473; `settings-nav.mjs:6-14` (7 ids) |
| B1-B12 disjoint files, order | OK apart from W1/W2 (B1 needs two more files) and W4 (one method without an owner) | the shared files are each named with a "rebases onto": `hub/server.go` (B3, B8), `gcal/oauth.go` (B7, B8), `hub/contacts.go` (B3, B6). B4 calls B2's hook and does not edit it |
| B1 red controls can fail | OK | C1: `\d personal.contacts` errors on master (no such table: `git grep -l 'personal.contacts' -- csi-spl-rdb` -> none). C1b: :640 fires for an unseeded tenant table. C1c: T-C1's exact list (:33, :42) and `count(*) <> 2` (:119) go red on a third table or door. C2, C2b, C2c, C2d each have a twin that is in reach |

## 3. Notes (no block)

| # | where | note |
|---|---|---|
| N1 | 3, C1c | the purger's two policies have no names, and T-C1 pins the exact `table.policy` list (`personal_catalogue_test.go:41-42`). Name them in section 3, for example `realm_contacts_purger_read` and `realm_contacts_purger_delete`, so B1 and the test agree |
| N2 | 6 row B1 | besides :114-121, three checks name the realm roles or doors as a literal list: the EXECUTE check (:103-108), the NOLOGIN check (:109-113) and "no login holds a realm role's privileges" (:122-126). Add the third role or door to each, or it goes unchecked. That is a coverage gap, not a red |
| N3 | 6 row B1 | name the new SQL tests `TestRLSContacts…` (not `TestContactsRLS…`): `hub-pg.tst.sh:247-249` requires every `^TestRLS` test to run and PASS (the RLS control). The precedent says so at `personal_catalogue_test.go:20-21`. Keep B1's `-run` pattern in step with the name |
| N4 | 2.6 (erase one), section 4 | from a W2 session, "is the binding enabled" for a soft or hard delete needs the person's `contacts_sync` row, which may be in W1 and is invisible in W2's scope. Say how B3 reads it: the operator scope by `human_id` (the table has `operator_scope`), or the membership loop of "erase all" |
| N5 | 2.2 step 3, 3 key choices | the 409 holds for a plain INSERT only. `INSERT … ON CONFLICT (human_id) DO UPDATE` against W1's row, which is invisible from W2, raises an RLS error (42501), not 23505. B3 should use a plain INSERT, or map both codes |
| N6 | 2.3, B5 | "A hit shows … its actions (2.4)", but B5 does not call B6's match, and B6 edits only the list and card handlers. Either the hit opens the card (which carries `member_id`) or B5 calls the batch match. Say which |
| N7 | C8c | the store does not gate a clone (the gate is B3's hub check), so "the clone holds 0 contacts before and after" passes trivially at store level. C4b is the real control; C8c can cite it |
| N8 | 2.3 | in `search/grammar.go:38-45`, `tenant`, `event` and `issue` are opt-in, not searched by default. Searching `contact` by default is a deliberate choice: keep the sentence |

## 4. Next

Send W1-W5 to the editor c-988@sat to fold. After the fold, this seat
re-checks only W1-W5 (N1-N8 if they are folded) on the new tree and signs in
its own message.

<!-- version: seat-claude v1.1 check 1 · tree e83f5407c · updated: 2026-10-24 -->
