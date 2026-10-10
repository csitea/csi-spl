signed against 7f6da1a7f

# Spec 119 review: seat s119-claude-2

**Reviewed**: `csi-spl-doc/specs/119-personal-realm/spec.md` v0.1 at `7f6da1a7f` (`git log origin/master -- csi-spl-doc/specs/119-personal-realm` -> that one commit).
**Read beside it**: c-783's s118 review (`6f2b324f8`, `csi-spl-doc/specs/118-multi-workspace-hours/reviews/s118-claude-2.md`, its contract C1..C5), rdb `0006_users_and_memberships.sql`, `0010_human_avatar.sql`, `0014_tenant_rls.sql`, `0021_rls_fail_closed.sql`, `0113_membership_access_until.sql`, `0143_messages_search_index.sql`, `0151_hours.sql`, `spool-hub-roles/runtime-grants.sql`, `spool-hub-roles/runtime-role.sql`, and the hub store: `rls.go` (`inTenant`, `asOperator`), `memberships.go` (`Memberships`), `humans_rbac_postgres.go` (`removeMemberTx`), `access_until.go`.
**Settled by the owner, not reopened here**: the realm above workspaces; ONE schema `personal` with person-scoped FORCE RLS; workspaces stay on RLS; hard isolation = the person's own DB (byo-gcp); receipts = hours only, as copies, no FKs into workspaces.

## 0. Four facts from the code that shape the proposals

1. **Identity already lives above workspaces.** `humans` (rdb 0006) is hub-wide, keyed `HUM-*`, with no `tenant_id` and no RLS. Later migrations put the avatar (0010), locale (0017), theme (0057) and view prefs (0070) on it, next to `display_name` and `email`. Sign-in reads it before any scope exists. So REQ-1 needs no new identity table: it must say "`humans` is the realm's identity".
2. **Every tenant table has an operator bypass.** 0014 gives each one an `operator_scope` policy (`app.rls_scope = 'operator'` reads all rows), and `asOperator` (`rls.go:159`) sets it. If `personal` copies that shape, any of the store files that call `asOperator` (`grep -ln asOperator internal/store/*.go | grep -v _test | wc -l` -> 24) could read every realm. The realm must NOT get an `operator_scope` policy.
3. **The runtime grants cover `public` only.** `runtime-grants.sql` grants `ON ALL TABLES IN SCHEMA public` and sets default privileges `IN SCHEMA public`. A `personal` schema gets nothing by default. Good: its grants are written by hand, which is what "its own grants" in 119 section 5 needs.
4. **Leaving keeps the hours in the workspace.** `removeMemberTx` (`humans_rbac_postgres.go:168`) deletes only the `tenant_memberships` row. `hours_entries.member_id` has no FK to `humans` or to the membership (0151), so the leaver's rows stay in the workspace. A lapsed `access_until` (0113) is not an event: nothing runs at that instant. Deleting a whole workspace cascades its hours away (`REFERENCES tenants ON DELETE CASCADE`, 0151). So the receipt has three triggers, not one (proposal c).

## 1. The four contradictions from s118-claude-2

| # | contradiction | how 119 should resolve it |
|---|---|---|
| 1 | Q3 leaves out 118 D4's **approval state and approver** | Take D4's list as given (D4 is settled). Q3 option B becomes: date, minutes, workspace display name, target label, **approval state, approver display name and decided-at**. Q3 stays open only for what D4 does not settle: whether times of day (spans) are kept (118 OQ-3). |
| 2 | Q3 says the job/site label is "as defined in Spec 118" | Cite **spec 107 FR-18**: the job `name` plus `site`; for a v1 target (`t:`, `ch:`, `dm:`, `cal:`, `ws`) the target's display name at copy time. A `dm:` target is copied as "Direct message" with no peer name: who the work was with is content. |
| 3 | REQ-6 read literally forbids 118 REQ-4 (entering hours from the realm screen) | Reword REQ-6: "No realm data is copied, joined or pushed into a workspace. The person's own hours entered from a realm screen are written through that workspace's existing routes (`PUT /v1/me/hours` with its `X-Spool-Tenant`), in that workspace's scope, exactly as from inside it. The realm screen is a client of the workspace, never a writer to it." The personal limit (C2) and the overlap numbers are realm data and are never sent. |
| 4 | `person_id` has no stated link to the hub's identity | `person_id = humans.human_id` (`HUM-*`), the same value as `hours_entries.member_id`. Every realm table carries `person_id text NOT NULL REFERENCES public.humans (human_id) ON DELETE CASCADE`. That FK points up to the identity, never down into a workspace, so it keeps the "no FK into workspaces" rule. No mapping table. Agents (`AGT-*`) have no realm: `CHECK (person_id ~ '^HUM-[0-9]+$')`. |

## 2. Per requirement and question

| item | verdict | one line |
|---|---|---|
| REQ-1 | **change** | "Identity is `public.humans` (hub-wide, already above workspaces); the realm adds only `personal.profile` for fields no workspace needs." Not a second identity, not a copy of `humans`. |
| REQ-2 | **agree** | Add: it reads each workspace in its own `inTenant` transaction as the person (118 proposal 1.2); the realm adds no operator-scoped read; the view is computed on read and stored nowhere. |
| REQ-3 | **agree** | Add the table (proposal a, `personal.settings`) and that a setting is never copied into, sent to or shown in a workspace (118 D3, its T16). |
| REQ-4 | **change** | "On leaving" must name its three triggers: removal or ban, `access_until` lapse, workspace deletion (fact 4). Add the refresh of a last period that was still open (118 C3). |
| REQ-5 | **agree** | Make it a closed list of columns (proposal c), so "no content" is checkable by a catalogue test, not by reading prose. A note field, a topic title and a `dm:` peer are content. |
| REQ-6 | **change** | Contradiction 3 above. Also: "RLS-safe" must say who is refused: another person, every workspace scope, the operator scope. |
| Q1 | **change** | Not A, B or C. Name, email and avatar are already on `humans`; the realm stores none of them again. `personal.profile` holds the zone (118 C4), comm prefs, and nothing a workspace reads. **Missing**: the avatar's bytes live in a tenant blob store (`t/<tenant>/files/<sha>`, rdb 0010), so a person who leaves that workspace may lose their own picture: OQ-4. |
| Q2 | **agree B** | Add: a person-only CSV or PDF **export** of the receipts on demand (118 OQ-4), generated from the rows, never stored. |
| Q3 | **change** | Contradictions 1 and 2. |
| Q4 | **agree** | Settled. Note the side effect of a non-`public` schema: grants and default privileges are written by hand (fact 3). |
| section 5, schema | **agree** | Add: ONE schema means ONE set of grants, kept in `spool-hub-roles/personal-grants.sql` next to `runtime-grants.sql`. |
| section 5, RLS | **change** | "similar to the tenant NULLIF policies" is right for the `NULLIF` guard and wrong for the `operator_scope` policy, which must not be copied (fact 2). |
| section 5, scope separation | **change: make it a database rule** | The realm policy refuses a row when `app.tenant_id` or `app.rls_scope` is set (proposal a). Then "never set together" holds even if the store gets it wrong. |
| section 5, cross-workspace reads | **agree** | As 118 proposal 1.2: `Memberships(humanID)` (the existing allow-listed operator read of membership rows only), then one `inTenant` per workspace. |
| section 5, receipts | **agree** | Proposal c gives when, what and how it stays fixed. |
| section 5, access | **change** | "Operator access is strictly logged" contradicts fact 2 unless there is a path that refuses by default and logs. v1: no operator read at all. A logged break-glass path is OQ-1. |
| section 5, tests | **missing** | Proposal e. |
| section 5, phase 2 encryption | **agree** | Out of scope for v1. |

## 3. Proposals

### (a) The `personal` schema and its FORCE RLS policy

**Migration `0164_personal_realm.sql`** (next free number at this sha: `ls csi-spl-rdb/src/sql/postgres/spool-hub | tail -1` -> `0163_tenant_agent_split_kind.sql`).

```sql
CREATE SCHEMA personal;

-- The one scope test for every realm table. A realm row is visible only when
-- app.person_id is set, matches, and NO workspace or operator scope is set in
-- the same transaction (119 section 5 "never set together", as a DB rule).
CREATE FUNCTION personal.scope_ok(p text) RETURNS boolean
    LANGUAGE sql STABLE AS $$
  SELECT p = NULLIF(current_setting('app.person_id', true), '')
     AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL
     AND coalesce(current_setting('app.rls_scope', true), '') = ''
$$;
```

Tables (all with `person_id text NOT NULL REFERENCES public.humans (human_id) ON DELETE CASCADE CHECK (person_id ~ '^HUM-[0-9]+$')`):

| table | columns beyond `person_id` | key |
|---|---|---|
| `personal.profile` | `time_zone text NULL` (IANA, length 1..64), `week_start smallint NULL` (1..7), `comm_prefs jsonb NOT NULL DEFAULT '{}'` (size-capped by a CHECK), `updated_at` | PK `person_id` |
| `personal.settings` | `weekly_limit_minutes int NOT NULL DEFAULT 0` (0 = off, else 60..10080), `daily_limit_minutes int NOT NULL DEFAULT 0` (0 = off, else 60..1440), `effective_from date NOT NULL`, `updated_at` | PK `(person_id, effective_from)`: a limit change keeps its history, so a past week is judged by the limit it had (118 C2) |
| `personal.receipts` | proposal c | proposal c |
| `personal.receipt_due` | `tenant_id text NOT NULL` (a copied id, no FK), `due_at timestamptz NOT NULL`, `reason text CHECK (reason IN ('removed','access_until','tenant_delete'))`, `done_at timestamptz NULL` | PK `(person_id, tenant_id)` |

Each table:

```sql
ALTER TABLE personal.<t> ENABLE ROW LEVEL SECURITY;
ALTER TABLE personal.<t> FORCE ROW LEVEL SECURITY;
CREATE POLICY person_scope ON personal.<t>
    USING (personal.scope_ok(person_id))
    WITH CHECK (personal.scope_ok(person_id));
-- deliberately NO operator_scope policy (fact 2)
```

**Store side.** A new `inPerson(ctx, humanID, fn)` in `rls.go`, the twin of `inTenant`: `checkPerson` refuses an empty or non-`HUM-*` id (`ErrNoPerson`), then `set_config('app.person_id', $1, true)`, transaction-local. The `humanID` comes **only from the authenticated session**, never from a path, query or body. Every realm store function takes the caller's id as its only scope; there is no "read person X" signature.

**Grants**, `spool-hub-roles/personal-grants.sql`, run as the schema owner after `spool migrate`, like `runtime-grants.sql`:
- `GRANT USAGE ON SCHEMA personal` to the runtime login; `SELECT, INSERT, UPDATE` on `profile`, `settings`, `receipt_due`; `SELECT, INSERT` only on `receipts` (proposal c, immutability).
- `DELETE` only on `profile`, `settings` (the person clears their own) and `receipt_due`.
- No default privileges in `personal`: a later realm table is granted on purpose, and a catalogue test (e, T11) fails when a `personal` table has no policy.
- The runtime login has no `BYPASSRLS` (`runtime-role.sql`) and owns nothing, so it can neither drop the policy nor turn FORCE off, as for `public`.

"As the person, never a service or superuser read" then holds at three layers: the policy needs `app.person_id`; there is no operator policy; the hub's runtime login cannot bypass RLS. With FORCE on, even the schema owner's ad-hoc `SELECT` reads 0 rows without the setting.

### (b) The realm reading and writing workspace hours as the person (the 118 contract)

118's C1..C5, answered from the realm side.

| 118 needs | 119 provides |
|---|---|
| **C1** unified view | `GET /v1/me/time?from=&to=&tz=`, a realm route. It **refuses an `X-Spool-Tenant` header with 400**, so it never runs under a workspace context. It runs: (1) `Memberships(caller)`, the existing allow-listed read of membership rows; (2) per live membership, one `inTenant` transaction with `member_id = caller` running the existing `HoursEntries`, `HoursPeriods`, `HoursMinutes` (no new SQL on hours tables, so 107 section 1.7's grep test stays green); (3) one `inPerson` transaction for the limit and the zone; (4) one `inPerson` read of receipts for the workspaces the person has left. Never two scopes in one transaction, and the policy of (a) refuses it anyway. At most 2 workspace reads at a time (hub pool 8, `max_connections` 25). A failed workspace is `{"state":"unavailable"}`, never retried under a broader scope. |
| **C2** the limit | `personal.settings`, read and written only in `inPerson`: `GET` and `PUT /v1/me/realm/settings`. The warning is computed on read from `actual` (118 D3), never stored, never sent to a workspace, never in a push or a log line. |
| **C3** leaver receipts | Proposal c. The personal view shows a left workspace from `personal.receipts`, labelled "left on <date>, read-only". |
| **C4** zone | `personal.profile.time_zone`; absent, the WUI sends its zone. |
| **C5** identity | Contradiction 4: `person_id = humans.human_id`. |
| **writes** | Contradiction 3: the realm screen sends one `PUT /v1/me/hours` per workspace with that workspace's `X-Spool-Tenant` and an operation id (107 FR-35). The realm has no route that writes a workspace table, and no realm store function opens `inTenant` for a write. |

The only realm code that opens a workspace scope at all is the C1 read and the receipt copy (c). A test (e, T14) lists both callers, the way `TestOperatorScopeCallers` lists the operator ones.

### (c) The receipt copy: when, what, how it stays fixed

**When** (fact 4 gives three triggers):

| trigger | what happens |
|---|---|
| **removal or ban** (`removeMemberTx`, which `BanMember` shares) | In the same request, **before** the membership delete: write `personal.receipt_due(leaver, tenant, reason = 'removed')` in `inPerson(leaver)`, commit; read the leaver's rows in `inTenant(tenant)`, commit; write them in `inPerson(leaver)`, commit; then run the removal. If the removal then fails, the receipt is an early copy, harmless and refreshed later. If the copy fails, the removal still runs and the open `receipt_due` row makes the sweep retry it. The leaver's hours stay in the workspace (fact 4), so a late retry still finds them. |
| **`access_until` lapse** (0113) | `SetMemberAccessUntil` writes `personal.receipt_due(leaver, tenant, due_at = until)`. A sweep (a named action plus a scheduled job, per the repo's "nothing ad hoc" rule) copies due rows as above, one `inPerson(person)` per row. To find them it needs to list due rows across persons: one `SECURITY DEFINER` function `personal.due_receipts(now)` returning only `(person_id, tenant_id)`, owned by a NOLOGIN NOBYPASSRLS role `spool_realm_sweeper` (precedent: `spool_search_reader`, rdb 0143) that has `SELECT (person_id, tenant_id, due_at, done_at)` on `receipt_due` alone and one extra policy `FOR SELECT TO spool_realm_sweeper USING (true)` on that one table. It can never read a profile, a setting or a receipt. |
| **workspace deletion** | Before the `DELETE FROM tenants`, the delete action copies receipts for every member, as for removal. A deletion that cannot copy is refused with a named error, never carried out with receipts lost. Whether a deleting owner may skip this is OQ-2. |

**What** (`personal.receipts`, one row per `(person_id, tenant_id, day, target_label, rev)`, the closed list REQ-5 needs):

| column | from |
|---|---|
| `tenant_id text` | the id, as a value, no FK |
| `workspace_name text` | the workspace display name at copy time |
| `day date`, `minutes int` (0..1440) | `hours_entries` |
| `target_label text` (<= 200) | 107 FR-18 job name + site, else the target's display name; `dm:` -> "Direct message" |
| `approval_state text` | `approved`, `frozen`, `returned`, `open` (period state from `hours_periods`, else `open`) |
| `approver_name text NULL`, `decided_at timestamptz NULL` | `hours_periods.decided_by` resolved to a display name at copy time (OQ-3 for how long) |
| `rev smallint NOT NULL` | 1, or 2 after the one refresh |
| `copied_at timestamptz NOT NULL DEFAULT now()` | |
| `final boolean NOT NULL` | true when the period was approved or frozen at copy time |

Not copied, by construction: `hours_entries.note`, `updated_by`, the raw target id (`t:<topic>` names a topic), `hours_minutes`, any message, topic title or file. Spans (times of day) only if 118 OQ-3 says yes.

**Immutable**:
- The runtime login has `SELECT, INSERT` on `personal.receipts` only: no `UPDATE`, no `DELETE` (proposal a). An `UPDATE` from the hub fails on privilege, not on code.
- The one refresh (118 C3: the last period was still open at leave time) is an **insert of `rev = 2`**, never an update. `CHECK (rev IN (1, 2))`, and a trigger refuses a `rev = 2` when the `rev = 1` row is `final`. Reads take the highest `rev`. So at most one refresh, and the history shows it.
- The refresh is driven by the same `receipt_due` row, kept open (`done_at NULL`) while any copied row is not `final`, and closed once all are, or at 107's retention limit at the latest.
- Deleting one's own receipts (data minimisation) would go through one `SECURITY DEFINER` function `personal.forget_receipts(tenant_id)` that checks `scope_ok` itself. Whether it exists is OQ-5.

### (d) byo-gcp hard isolation: what moves, what stays

byo-gcp today (`csi-spl-doc/doc/md/SPEC-spool-byo-gcp.md`) is a whole hub in the customer's project: its own Cloud Run and Cloud SQL. For a **person** it means the realm in the person's own database.

| moves to the person's own DB | stays on the hub where they sign in |
|---|---|
| the whole `personal` schema: profile, settings, receipts, receipt_due | `public.humans`, `human_identities`, `human_keys`: sign-in must work before any realm DB is reachable |
| the same migration and the same policy, run by the same `spool migrate` against a second DSN | every workspace table, the person's hours in them included: they belong to the workspace, not to the person |
| | the C1 route itself; it opens its realm transaction on the person's DSN instead of the shared one |

Rules:
- The realm DSN is chosen per person by one hub-wide row `public.person_realm(person_id, secret_ref)`: a reference to a Secret Manager entry, never a DSN in a table or a log. No row = the shared `personal` schema.
- The FK `person_id -> public.humans` cannot cross databases. In the own DB it becomes a `CHECK` on the id shape, plus a test that the hub refuses a realm row whose person has no `humans` row.
- Moving in and out are named actions (`do_spl_realm_move`): copy, verify row counts, then delete the source, under the person's own scope on both sides.
- A person whose workspace runs on a **customer's own hub** and who signs in there has a realm on that hub. Cross-hub views, and receipts carried between hubs, are not in v1: OQ-6.

### (e) Tests

Store tests on Postgres (`PRE_PUSH_TIER=full`), each with a red control that turns it red.

**RLS negatives**
- **T1** person P writes profile, settings, a receipt; `inPerson(Q)` reads 0 rows from each realm table. Red control: drop `person_scope` on one table, T1 fails for that table.
- **T2** a workspace scope never reads the realm: in `inTenant(A)` with P a member of A, every `personal.*` table reads 0 rows and an `INSERT` fails `WITH CHECK`.
- **T3** both set: a transaction with `app.person_id = P` **and** `app.tenant_id = A` reads 0 realm rows (the database half of "never set together").
- **T4** `asOperator` reads 0 rows from every `personal.*` table. Red control: add an `operator_scope` policy, T4 fails.
- **T5** no setting at all, and `app.person_id = ''`, read 0 rows (the `NULLIF` guard).
- **T6** the schema owner role without the setting reads 0 rows (FORCE is on).
- **T7** the runtime login: `UPDATE` and `DELETE` on `personal.receipts` fail with `42501` (insufficient privilege), even inside `inPerson(P)`.
- **T8** `inPerson` refuses `''`, `AGT-1` and `HUM-1; --` with `ErrNoPerson` before any SQL.
- **T9** the realm routes ignore a person id in the path, query or body: a request as P naming Q returns P's rows.
- **T10** route level: another person, a foreman of P's former workspace, its admin and its owner get 404 on P's receipts.

**Catalogue and code gates**
- **T11** every table in schema `personal` has RLS enabled, FORCE on, a `person_scope` policy and no other policy except the one sweeper policy on `receipt_due` (a catalogue query over `pg_class` and `pg_policy`).
- **T12** no FK from `personal` to any table carrying `tenant_id` (a `pg_constraint` query); the only allowed target is `public.humans`.
- **T13** the receipt columns are exactly the list in (c): a new column fails the test until REQ-5's list names it.
- **T14** `inTenant` callers in realm code are exactly the C1 read and the receipt copy (an allow-list test in the shape of `TestOperatorScopeCallers`); realm code calls no `asOperator`.
- **T15** 107's 1.7 grep test stays green: no new SQL on `hours_minutes` or `hours_entries` outside the hours store.

**Receipts**
- **T16** remove P from A: one receipt row per (day, target) with exactly the (c) columns, no note, no `t:` id, `dm:` as "Direct message"; A still holds P's hours rows.
- **T17** the copy fails (stub): the removal still runs and `receipt_due` stays open; the sweep copies it on its next run.
- **T18** `access_until` set to yesterday: the sweep takes the receipt; before that instant, nothing is copied.
- **T19** delete workspace A with members P and Q: both have receipts afterwards; a stubbed copy failure refuses the delete.
- **T20** P leaves with the last period open: `rev = 1`, `final = false`; the approver approves it later: `rev = 2`, `final = true`; a third change writes nothing.
- **T21** `personal.due_receipts` returns only `(person_id, tenant_id)`; `spool_realm_sweeper` reads 0 rows from `profile`, `settings` and `receipts`.

**Contract with 118**
- **T22** `GET /v1/me/time` with an `X-Spool-Tenant` header returns 400.
- **T23** P is in A and B and left C: the view shows A and B live and C from receipts, labelled read-only; nothing from a workspace P never joined.
- **T24** the limit is never in a workspace response, a push payload or a log line (118 T16, owned there, run against the realm table here).
- **T25** writes from the realm screen arrive as one `PUT /v1/me/hours` per workspace with its own tenant header; no realm route writes a workspace table (a route-table test).

**byo-gcp**
- **T26** a person with a `person_realm` row: the C1 read opens its realm transaction on that DSN and none on the shared schema; T1..T7 rerun against the second DB.

## 4. Owner questions (not decided here)

- **OQ-1: operator access to a realm.** A: none in v1 (this seat's reading of "no admin can read another person's realm"). B: a break-glass `SECURITY DEFINER` function that first writes an access-log row the person can see, then returns.
- **OQ-2: deleting a workspace that has members.** Receipts are always copied first (this seat), or a deleting owner may opt out for everyone.
- **OQ-3: approver names in receipts.** How long the realm keeps another person's name: as long as the receipt, or 107 FR-34's retention years, then blanked.
- **OQ-4: the avatar.** Its bytes sit in one workspace's blob store (rdb 0010). Move personal avatars to a realm blob prefix, or accept that a leaver may lose their picture.
- **OQ-5: may a person delete their own receipts?** Yes, through the one function in (c), or receipts are kept for the retention period whatever the person wants.
- **OQ-6: byo-gcp across hubs.** A receipt from a workspace on a customer's own hub: kept on that hub (the leaver signs in there with no membership and reads it), exported to the person's home realm as a signed copy, or not in v1.
- **118 OQ-3 (open, shared with 118)**: do receipts keep times of day?

<!-- version: 0.1.0 · updated: 2026-10-10 · seat s119-claude-2 · last-edit: 2026-10-10 -->
