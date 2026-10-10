signed against 7f6da1a7f

# Spec 119 review: seat s119-claude (also the panel editor)

**Reviewed**: `csi-spl-doc/specs/119-personal-realm/spec.md` v0.1 at `7f6da1a7f` (64 lines). `git log origin/master --oneline -- csi-spl-doc/specs/119-personal-realm/spec.md` -> one commit, `7f6da1a7f`.
**Read beside it**: spec 118 at `cdf9136c9` (D1..D4, section 4), the s118 review `s118-claude-2.md` (`6f2b324f8`, contradictions 2.2..2.5 and contract C1..C5), `csi-spl-doc/doc/md/SPEC-spool-byo-gcp.md`, and the code: `internal/store/rls.go` (`inTenant`, `asOperator`), `internal/store/memberships.go:111` (`Memberships`), rdb `0006` (`humans`), `0151_hours.sql` (the `tenant_scope` / `operator_scope` pair), `spool-hub-roles/runtime-grants.sql`, `csi-spl-orc/src/bash/run/spl-db-rls-check.func.sh`.
**Settled by the owner, not reopened here**: a personal realm above workspaces; ONE schema `personal` with person-scoped FORCE RLS; workspaces stay on RLS; hard isolation = a dedicated DB (byo-gcp); receipts are hours only, taken as copies, with no FK into workspaces.

## 0. Three facts from the code that shape the proposals

1. **The runtime login is the same for workspace and realm.** `runtime-grants.sql` grants DML on schema `public` to one runtime role (cnf `hub.db_user`). So "a workspace role never reads the realm" cannot rest on a separate login. It has to rest on the **policy**: a realm row is visible only when `app.person_id` is set **and** `app.tenant_id` is not (proposal a.2). `grep -c "SCHEMA public" csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql` -> 7; `grep -c personal` on the same file -> 0, so the schema needs its own grant block.
2. **Every tenant table carries a generic `operator_scope` policy** (`current_setting('app.rls_scope') = 'operator'`, e.g. `0151_hours.sql:82`). If the realm tables copied that shape, any `asOperator` caller (today's allow-listed ones, `TestOperatorScopeCallers`) would read every person's realm. 119's "operator access is strictly logged" therefore needs a **different** door, not that policy (proposal a.3).
3. **The person already has a hub-wide id**: `humans.human_id` (`HUM-[0-9]+`, rdb 0006), with no `tenant_id` and no RLS. The hours rows key `member_id` on that same id (107 section 3.2). The realm key is that id; a second id would mean a mapping table and one more place to leak (c-783 contradiction 4).

## 1. Per item of the draft

| item | verdict | one line |
|---|---|---|
| REQ-1 identity, profile | **change** | The realm profile **extends** `humans` (name, email stay there, one source); the realm adds only avatar, zone, language and contact preferences. Say "separate from workspace-specific profiles" means a workspace never reads it. |
| REQ-2 personal views | **agree, missing contract** | Name what 118 gets: the route, its scope rule and its shape (proposal b, contract C1). |
| REQ-3 personal settings | **agree** | Name the first setting: the working-time limit (118 D3), its range and that it is never sent anywhere (C2). |
| REQ-4 receipts | **change** | Define "leaving": membership removed **or** `access_until` passed (rdb 0113). Add the refresh of the last open period (proposal c.3). |
| REQ-5 hours only | **agree** | Make it a field list, not a description: D4's list exactly (proposal c.2), and a test that greps the copy for content fields. |
| REQ-6 isolation | **change** | Read literally it forbids 118 REQ-4 (writing hours into workspaces from the realm screen). New wording in section 2, point 3. |
| Q1 profile | **agree with B** | Name and email stay in `humans`; avatar is a URL to the person's own upload, never a workspace file. Owner's call: whether "communication preferences" includes a personal email for receipts (OQ-4). |
| Q2 receipt presentation | **agree with B** | Add: a person-only CSV/PDF download of their own receipt is a later option (OQ-3), never a share to a workspace. |
| Q3 receipt detail | **change** | Option B misses D4's **approval state and approver**, and cites the label to the wrong spec. Fix in section 2, points 1 and 2. |
| Q4 schema name | **agree** | `personal`, settled. Tables are always schema-qualified (`personal.x`); `personal` is never on the runtime `search_path`, so an unqualified name cannot hit it. |
| 5 schema architecture | **agree** | Add: `personal` gets its own grant block in `runtime-grants.sql` and is covered by `do_spl_db_rls_check` (proposal a.4). |
| 5 RLS isolation | **change** | "Similar to the tenant NULLIF policies" is not enough: the policy must also refuse when `app.tenant_id` is set, and there is **no** `operator_scope` on realm tables (proposal a.2, a.3). |
| 5 scope separation | **agree, make it enforced** | Today it is a sentence. Enforce it twice: in the policy (a.2) and in the store (`inPerson` and `inTenant` never nest, a.1). |
| 5 cross-workspace reads | **agree** | One workspace per transaction, as the person, through the existing store reads; no new operator read (proposal b.1). |
| 5 receipt isolation | **agree** | Add how a copy crosses scopes: read in the workspace's transaction, write in the realm's, never one transaction (proposal c.1). |
| 5 access restrictions | **agree, missing mechanism** | Proposal a.3: one named, logged operator function, not the generic policy. |
| 5 testing | **missing detail** | "Per-table isolation tests + red control" becomes the list in proposal e. |
| 5 phase 2 encryption | **agree** | Out of scope for v1; nothing in v1 blocks adding it later (a column type change is a migration). |

## 2. c-783's four contradictions (s118-claude-2, `6f2b324f8`): how 119 resolves each

1. **Q3 omits D4's approval state and approver.** D4 is an owner decision, so 119 takes D4's list as given. The receipt line holds: day, minutes, workspace display name, target label, **approval state** (`open`, `approved`, `frozen`, `final`, `returned`) and **approver display name** at copy time. 119 Q3 is replaced by that list; nothing more, nothing less (proposal c.2).
2. **Q3's job/site label is defined in 107 FR-18, not 118.** 119 cites 107 FR-18: the label is the job `name` plus `site`; for a v1 target with no job (`t:`, `ch:`, `cal:`, `ws`) it is the target's display name at copy time. The label is a copied string, never the target id.
3. **REQ-6 forbids 118 REQ-4's writes into workspaces.** New REQ-6: *"No realm data is copied, read or joined into a workspace. The person's own hour entries made from a realm screen are written through that workspace's own routes, in that workspace's scope and under its rules (freeze, day cap, membership), exactly as if made from inside the workspace. A workspace sees the entry, never that it came from the realm screen."* So the only thing that "flows down" is the person's own action, not realm data.
4. **`person_id` must equal the HUM-\* id.** 119 states: `person_id = humans.human_id`, checked `^HUM-[0-9]+$`. `app.person_id` is set only by the hub, only from the authenticated session's human id, never from a header, path or body. Agents (`AGT-*`) have no realm.

## 3. Proposals

### (a) The `personal` schema and its FORCE RLS

**a.1 Store scope.** One new helper in `rls.go`, the twin of `inTenant`:

- `pgScopePerson = SELECT set_config('app.person_id', $1, true)`
- `inPerson(ctx, humanID, fn)`: refuses `""` (`ErrNoPerson`) and anything not `^HUM-[0-9]+$`, then runs `fn` in one transaction with the person scope set.

Rules:
- Transaction-local, like `app.tenant_id`, so it ends at COMMIT and never reaches the next pool user.
- `inPerson` and `inTenant` are separate transactions by construction. A store test (e5) greps that `pgScopePerson` appears only in `inPerson`, and that no `inTenant` call sits inside an `inPerson` callback, or the reverse.
- No single-statement batch shortcut in v1: the realm is low traffic, so clarity beats one round trip.

**a.2 Tables** (migration `01xx_personal_realm.sql`). Every table has `person_id text NOT NULL CHECK (person_id ~ '^HUM-[0-9]+$')` first, `ENABLE` + `FORCE ROW LEVEL SECURITY`, and **no FK to any `public` table**, `humans` included, so a byo move or a workspace purge never cascades into the realm.

| table | PK | columns |
|---|---|---|
| `personal.profile` | `person_id` | `avatar_url`, `time_zone` (IANA, NULL = the browser's), `locale`, `contact_prefs jsonb` (CHECK object, size <= 4 KB), `updated_at` |
| `personal.settings` | `(person_id, key)` | `key` CHECK in an allow-list (`hours.limit.weekly_minutes`, `hours.limit.daily_minutes`), `value int` with a per-key CHECK (weekly 0 or 60..10080, daily 0 or 60..1440; 0 = off), `effective_from date NULL`, `updated_at` |
| `personal.receipts` | `(person_id, receipt_id)` | `receipt_id uuid`, `source_hub` (cnf host id of the issuing hub), `workspace_id` (copied text, not an FK), `workspace_name`, `left_at`, `reason` (`removed`, `access_ended`, `left`), `state` (`pending`, `taken`, `final`), `taken_at` |
| `personal.receipt_lines` | `(person_id, receipt_id, day, target_label, rev)` | `day date`, `minutes int CHECK 0..1440`, `target_label text <= 200`, `approval_state`, `approver_name text NULL <= 200`, `rev smallint` (0 = at leave, 1 = the one refresh, c.3), `copied_at` |
| `personal.access_log` | `(person_id, at, id)` | `actor` (operator id), `reason text NOT NULL`, `ticket text`; written only by the operator door (a.3); the person reads their own |

The policy, the same on every table:

- `CREATE POLICY person_scope ON personal.<t>`
- `USING (person_id = NULLIF(current_setting('app.person_id', true), '') AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL)`
- `WITH CHECK` the same expression.

Why each part:
- The `NULLIF` guard (the CLE-3416 shape) makes an unset or empty `app.person_id` match nothing.
- The second clause is the database half of "workspace scope and realm scope are never set together": inside a workspace transaction the realm reads 0 rows and refuses writes, even if the store is wrong.
- **No `operator_scope` policy** on any `personal.*` table (fact 0.2). `asOperator` reads 0 realm rows.

**a.3 The operator door.** One `SECURITY DEFINER` function `personal.operator_read(person_id, reason, ticket)`:
- owned by a dedicated NOLOGIN role; EXECUTE revoked from PUBLIC and granted to nobody by default;
- it writes the `access_log` row in the same statement it reads, and the person sees that row in their realm;
- used only through a named owner-run action (`do_spl_personal_operator_read`, owner's go per call);
- on no hub route, so no foreman, admin or workspace owner ever reaches it.

Whether it exists at all in v1 is the owner's call (OQ-1).

**a.4 Grants and checks.**
- `runtime-grants.sql` gets a `personal` block: `USAGE` on the schema; `SELECT, INSERT, UPDATE, DELETE` on `profile` and `settings`; `SELECT, INSERT` on `receipts` and `receipt_lines`, plus a column grant `UPDATE (state, taken_at)` on `receipts` only; `SELECT` on `access_log`.
- No default privileges in `personal`, so a new realm table is invisible to the hub until it is named in that block on purpose.
- `do_spl_db_rls_check` today walks `tenant_id` tables. Extend it to every `personal.*` table: `relrowsecurity` and `relforcerowsecurity` true, a policy named `person_scope`, no policy named `operator_scope`. Exit non-zero otherwise.

### (b) Reading and writing workspace hours as the person (the contract 118 needs)

**b.1 Unified view (118 C1).** `GET /v1/me/time?from=&to=&tz=`, hub session only.
- It **refuses** an `X-Spool-Tenant` header with 400, so no workspace context can carry it.
- Workspace list: `Memberships(ctx, humanID)` (`memberships.go:111`), the one existing operator-scoped read of membership rows (never hours). 119 adds no new operator read.
- Per workspace: one `inTenant` transaction calling the existing hours reads with `member = caller` (s118-claude-2 proposal 1.2). Sequential, or at most 2 at a time (pool 8, `max_connections` 25).
- The realm reads (limit, zone, receipts) are a separate `inPerson` transaction.
- A workspace that fails returns `{"state":"unavailable"}`; it is never retried under a broader scope.
- Past workspaces come from `personal.receipt_lines` (highest `rev` per key), marked "receipt".
- The overlap arithmetic is 118's (s118-claude-2 proposal 2); 119 only hosts the route and supplies its inputs.

**b.2 The limit setting (118 C2).** `GET` and `PUT /v1/me/realm/settings`, `inPerson` only. The value never leaves the realm: no workspace table, no push and no log line carries it. The warning is computed on read (118 D3).

**b.3 Writes (118 REQ-4).** The realm screen writes nothing itself. It calls, per workspace, the existing `PUT /v1/me/hours` with that workspace's `X-Spool-Tenant` and an operation id (107 FR-35). There is no cross-workspace atomicity, and the UI says so. The realm stores nothing about the write.

**b.4 Zone (118 C4).** `personal.profile.time_zone`; NULL means the WUI sends its own.

**b.5 Identity (118 C5).** Section 2, point 4.

### (c) Receipt copy

**c.1 When, and across scopes.** "Leaving" = the membership is removed, or `access_until` passes (rdb 0113). Each step is its own transaction:

1. `inPerson(leaver)`: insert `personal.receipts` with `state = pending`.
2. `inTenant(workspace)`: read the leaver's entries and period states through the existing store reads (no new SQL on hours tables, so 107's grep test stays green), plus the target labels and approver names as strings.
3. `inPerson(leaver)`: insert the `receipt_lines` at `rev = 0`, set `state = taken`.
4. Only then does the membership removal commit (for an explicit removal). For `access_until`, a sweep job runs steps 1..3 for each newly expired membership; the expiry itself already stops access.

A crash between steps leaves a `pending` receipt. The sweep retries it while the workspace rows still exist (107 FR-34 retention). The leaver never regains access because of a pending receipt.

**c.2 What it holds.** Exactly D4's list: day, minutes, workspace name, target label (107 FR-18 job name + site, else the target's display name), approval state, approver name.
**Not**: notes, message text, topic or channel content beyond the label, member lists, the workspace's standard day or overtime flags, spans (unless the owner picks OQ-2). A test greps the copied rows for the seeded content (e13).

**c.3 Immutable, with one refresh.** 107 Q8 is open, so the leaver's last period may still be open at leave time.
- Lines are append-only (`INSERT` only, a.4).
- When that last period later freezes or is approved, the sweep appends `rev = 1` lines for that period only and sets `state = final`.
- After `final` nothing is appended.
- A workspace deleted before the refresh leaves the receipt at `rev = 0`, marked "last period not final".
- The view reads the highest `rev` per (day, label).

**c.4 Retention.** The receipt belongs to the person and outlives the workspace. Its retention and the person's own delete are owner questions (OQ-5).

### (d) byo-gcp: what moves, what stays

A dedicated customer runs its own hub and DB (SPEC-spool-byo-gcp section 3: "not shared `tenant_id` rows on your hub"). So:

- **Moves to the customer's DB**: that workspace's tables (`public.*` with its `tenant_id`), its hours, its memberships. Nothing of the realm.
- **Stays on the shared hub**: every person's `personal.*` rows. One person, one realm, wherever their workspaces are. The dedicated DB has the same migration, so an empty `personal` schema.
- **Cross-hub reads**: the shared hub's realm cannot open the dedicated DB. In v1 the unified view shows a dedicated workspace as a link "hours on <hub>", not as numbers. Federating its numbers is a later spec.
- **Receipts from a dedicated hub**: that hub takes the copy in its own DB at leave time (its own `personal` schema, same code). Delivering it to the person's realm on the shared hub would be an export the person downloads and imports, signed by the issuing hub (`source_hub`). Whether v1 does this is the owner's call (OQ-6).
- **A person's own DB** (a person, not a customer, wanting hard isolation): out of scope for v1. The realm schema has no FK to `public`, so it can move later as a whole.

### (e) Tests

All on Postgres (`PRE_PUSH_TIER=full`), as the runtime role, never as the owner or a superuser.

**RLS negatives**
- e1: person P with `app.person_id = P` reads every `personal.*` table: only P's rows. Person Q's rows exist in the fixture: 0 of them returned, and an `INSERT` with `person_id = Q` fails the `WITH CHECK`.
- e2: inside `inTenant(A)` (only `app.tenant_id` set), every `personal.*` table reads 0 rows and refuses an insert. **Red control**: drop the `app.tenant_id ... IS NULL` clause in a throwaway schema and the test fails.
- e3: inside `asOperator`, every `personal.*` table reads 0 rows. Red control: add an `operator_scope` policy and the test fails.
- e4: `app.person_id` unset or `''`: 0 rows, insert refused. Red control: remove the `NULLIF`.
- e5: both `app.person_id` and `app.tenant_id` set in one crafted transaction: 0 rows. Plus the grep test of a.1.
- e6: the catalogue: every `personal.*` table has `relforcerowsecurity`, a `person_scope` policy, no `operator_scope` policy, and no FK to a table outside `personal` (a `pg_constraint` query). Wired into `do_spl_db_rls_check`.
- e7: a runtime `UPDATE` or `DELETE` on `personal.receipt_lines` fails with a privilege error.
- e8: the operator door: EXECUTE as the runtime role fails; as the granted role it writes exactly one `access_log` row per call.

**Contract with 118**
- e9: `GET /v1/me/time` with an `X-Spool-Tenant` header: 400.
- e10: a foreman and an admin of workspace A calling any route about person P: no field from `personal.*` in the response (a field-level grep of the JSON for the limit, the zone and receipt ids).
- e11: the limit appears in no workspace table, no push stub call and no log line after a PUT and a read.
- e12: `TestOperatorScopeCallers` unchanged: 119 adds no operator-scoped caller.

**Receipts**
- e13: removing P from A produces one receipt with D4's columns only; no note, message or topic text seeded in the fixture is found in `personal.*` (substring grep).
- e14: an `access_until` expiry produces the receipt through the sweep; a crash injected between steps 2 and 3 leaves `pending`, and the next sweep completes it exactly once.
- e15: the last period open at leave, approved later: one `rev = 1` set appears and `state = final`; a second approval or edit appends nothing.
- e16: after leaving, A's routes answer 403 to P; P still reads the receipt; Q, a foreman and an admin of A get 404 on it.
- e17: on a dedicated (byo) DB fixture, the shared hub's `personal.*` holds no row for the dedicated tenant except receipts the person imported.

## 4. Owner questions (not decided here)

- **OQ-1: the operator door (a.3).** A: a logged `SECURITY DEFINER` read, owner-run per call, visible to the person. B: no operator read of the realm at all in v1.
- **OQ-2: spans in receipts.** Keep the times of day of past entries (118 OQ-3), so a leaver's past overlap stays visible, or hours per day only.
- **OQ-3: a person-only download of receipts** (CSV or PDF) in v1, or later.
- **OQ-4: a personal email in the profile**, separate from the sign-in email in `humans`, for sending receipts to the person.
- **OQ-5: receipt retention and the person's own delete.** Forever while the account lives, or 107 FR-34's years; and may the person delete a receipt (an erasure right) or only hide it.
- **OQ-6: receipts from a dedicated (byo) hub.** In v1: none, a signed export the person imports, or a federation later.
- **OQ-7: the approver's name in a leaver's receipt** is another person's personal data held in the leaver's realm. Keep it for the receipt's life, or only for 107 FR-34's years.

<!-- version: 0.1.0 · updated: 2026-10-10 · seat s119-claude · last-edit: 2026-10-10 -->
