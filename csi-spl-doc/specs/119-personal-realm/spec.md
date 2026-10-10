# 119 Personal Realm

**Status**: v1.0-rc (panel fold of 4 seats, 2026-10-10; editor s119-claude). Sections 1..5 are the v0.1 draft, kept as written; where section 6 changes a REQ or a Q, section 6 wins.

## 1. Context and Goals
Based on the owner's feedback, there is a need for a "personal realm" — a person-level layer that exists above workspaces. When people leave a workspace, they should retain read-only copies of their own past hours (like pay receipts) without keeping the actual content of the work.

## 2. Scope
The personal realm is a person-level layer ABOVE workspaces, holding:
- Identity and profile.
- Personal views (e.g., 'my time across workspaces', cross-reference Spec 118).
- Personal settings (e.g., the working-time limit).
- Receipts: read-only copies of one's own past hours after leaving a workspace (hours only, NOT content).

Workspaces stay unchanged. Nothing flows from the personal realm down to the workspaces, and everything must be Row-Level Security (RLS) safe.

## 3. Requirements

- **REQ-1 (Identity and Profile)**: The system must maintain a personal identity and profile separate from workspace-specific profiles.
- **REQ-2 (Personal Views)**: The system must provide a unified view across all workspaces a user belongs to (see Spec 118 for 'my time across workspaces' details).
- **REQ-3 (Personal Settings)**: The system must support personal settings that apply across workspaces, such as working-time limits.
- **REQ-4 (Read-Only Receipts)**: Upon leaving a workspace, a person must retain a read-only receipt of their own past hours.
- **REQ-5 (Content Redaction on Departure)**: The read-only receipts must NOT contain the content of what was done, only the hours.
- **REQ-6 (Data Isolation)**: Data must not flow from the personal realm into workspaces, and must be completely RLS-safe.

> **v1.0**: REQ-1, REQ-4, REQ-5 and REQ-6 are reworded in section 6.1. The owner-settled points (realm above workspaces, one schema `personal`, person-scoped FORCE RLS, workspaces on RLS, hard isolation = an own DB, receipts as hour copies with no FK into workspaces) stand as written.

## 4. Open Questions

**Q1: What exactly should be included in the "Identity/Profile" within the personal realm?**
- A) Only name and email.
- B) Name, email, personal avatar, and communication preferences.
- C) Full CV, skills, and portfolio.
- **Recommendation:** B. Name, email, avatar, and basic communication preferences provide a solid foundation for cross-workspace identity without unnecessary complexity.

**Q2: How should receipts be presented after leaving a workspace?**
- A) As a static document (e.g. PDF) generated at the time of leaving.
- B) As an interactive but read-only data view in the personal realm.
- **Recommendation:** B. An interactive data view allows better filtering and consistency with the rest of the personal realm UI.

**Q3: How much detail is retained in the read-only receipts (REQ-5)?**
- A) Only the total hours per day/week.
- B) Total hours, dates, workspace name, and high-level job/site label (as defined in Spec 118).
- **Recommendation:** B. Retaining the workspace name and high-level job label is necessary for the receipt to act like a useful pay receipt, without exposing the actual work content.

**Q4: What should be the NAME of the single database schema used for personal realms?**
- A) `personal` (recommended)
- B) `person`
- C) `own`
- **Recommendation:** A. `personal` is standard and aligns well with the concept of a "personal realm". *(Note: The schema name is decided to be `personal` - the business/UI/doc term is "the personal realm").*

> **v1.0**: Q1..Q4 are settled in section 6.2 (Q3 is replaced by 118 D4's list).

## 5. Security

The personal realm introduces a new data layer requiring strict isolation. The baseline security architecture is:

- **Schema Architecture**: 
  - Workspaces stay on RLS in the shared schema.
  - There is ONE schema (named `personal`) for all personal realms with person-scoped RLS and its own grants (never a schema per person).
  - Hard isolation for a customer requires a dedicated DB (byo-gcp), not schema-per-tenant.
- **RLS Isolation**: Realm tables are keyed by `person_id` with a strict Row-Level Security (RLS) policy based on `app.person_id` (FORCE RLS, similar to the existing tenant NULLIF policies).
- **Scope Separation**: Workspace scope and realm scope are never set together.
- **Cross-Workspace Reads**: The cross-workspace view reads each workspace under its own RLS context as that person.
- **Receipt Isolation**: Receipts are strict COPIES taken at leave time. There are no Foreign Keys (FK) into workspace data to prevent data leakage.
- **Access Restrictions**: No foreman, admin, or owner can read another person's realm. Operator access is strictly logged.
- **Testing**: Per-table isolation tests + red control.
- **Future phases**: Phase 2 option for per-person encryption.

## 6. v1.0: the panel's detail

Folded from the four seat files in [reviews/](reviews/) (section 12). It is the 119 side of the 118/119 contract: 118 v1.0 section 9 (C1..C7) consumes it, and the two editors aligned it on `dispatch-151d85fc` (section 12.4).

### 6.1 Requirements, reworded

- **REQ-1 (Identity and Profile)**: The person's identity is the hub-wide `public.humans` row (`HUM-*`, rdb 0006); its name, email and avatar stay there, one source. The realm adds `personal.profile` only for fields no workspace reads: time zone, locale, communication preferences. No workspace reads the profile.
- **REQ-4 (Read-Only Receipts)**: A person keeps a read-only receipt of their own past hours in a workspace when their live access to it ends: the membership is **removed** (or banned), its **`access_until` passes** (rdb 0113), or the **workspace is deleted** (owner question OQ-6). Whether a **disabled** membership (rdb 0074, reversible) also counts is OQ-5. The copy is taken first and the change made second (section 8.1).
- **REQ-5 (Hours Only)**: A receipt holds exactly 118 D4's fields (section 8.2), a closed list checked by a catalogue test: no note, no topic, channel or meeting title, no message, no target id.
- **REQ-6 (Data Isolation)**: No realm row is copied, joined or pushed into a workspace, and no workspace scope reads the realm. When the person enters hours from a realm screen, each entry is written by the hub through 107's existing entry write, in that workspace's scope and under that workspace's rules (freeze, day cap, membership, target), exactly as if made inside the workspace. A workspace sees the entry, never that it came from the realm screen. The realm stores nothing about the write.

### 6.2 Open questions of v0.1, settled

| Q | settled as | why |
|---|---|---|
| Q1 | **B, without copies**: name, email and avatar are already on `humans` (rdb 0006, 0010); the realm stores none of them again. `personal.profile` holds time zone, locale and communication preferences. | 3 of 4 seats; a second copy of the name is a second source |
| Q2 | **B**: an interactive read-only view. A person-only download of one's own receipts is owner question OQ-8. | all 4 seats |
| Q3 | **Replaced by 118 D4's list** (section 8.2), the label per 107 FR-18. | 118 D4 is an owner decision; all 4 seats |
| Q4 | **`personal`** (owner, already settled). Tables are always schema-qualified; `personal` is never on the runtime `search_path`. | all 4 seats |

### 6.3 The four contradictions with 118 (c-783, `6f2b324f8`)

| # | contradiction | resolved as |
|---|---|---|
| 1 | Q3 leaves out 118 D4's approval state and approver | Q3 takes D4's list whole: approval state, approver name and decided-at (8.2) |
| 2 | Q3 says the job/site label is defined in 118 | 107 FR-18: job `name` + `site` for a `job:` target; for `t:`, `ch:`, `dm:`, `cal:` only the **type** (`topic`, `channel`, `direct message`, `meeting`), never a title; `ws` = `workspace` (8.2) |
| 3 | REQ-6 read literally forbids 118 REQ-4's writes | REQ-6 reworded (6.1) |
| 4 | `person_id` has no stated link to the hub id | `person_id = humans.human_id`, `REFERENCES public.humans (human_id) ON DELETE CASCADE`, `CHECK (person_id ~ '^HUM-[0-9]+$')`. That FK points up to the hub-wide identity, never into a workspace. Agents (`AGT-*`) have no realm. |

## 7. The `personal` schema

### 7.1 Facts from the code

| fact | where | so |
|---|---|---|
| One runtime login serves workspaces and the realm | `spool-hub-roles/runtime-grants.sql` | "a workspace role never reads the realm" rests on the **policy**, not on a separate login |
| Every tenant table has an `operator_scope` policy (`app.rls_scope = 'operator'` reads all rows) | rdb 0014, `0151_hours.sql:82` | a realm table must **not** copy it, or every `asOperator` caller reads every realm |
| Runtime grants and default privileges cover schema `public` only | `runtime-grants.sql` | `personal` gets its own named grants, nothing by default |
| The RLS gates list tables `WHERE nspname = current_schema()` | `rls_test.go:78`, `crosstenant_test.go:358` | no existing gate sees `personal`: 119 brings its own (T-C1) |
| Removal deletes only the membership row; hours stay in the workspace; `access_until` lapse is no event; a workspace delete cascades its hours | `humans_rbac_postgres.go:168`, rdb 0113, 0151 | the receipt has several triggers, and expiry needs a sweep (8.1) |

### 7.2 Store scope

`rls.go` gets the twin of `inTenant`:

- `pgScopePerson = SELECT set_config('app.person_id', $1, true)`, transaction-local like `app.tenant_id`.
- `inPerson(ctx, humanID, fn)` refuses `""` and anything not `^HUM-[0-9]+$` (`ErrNoPerson`) before any SQL, then runs `fn` in one transaction. It never sets `app.tenant_id`.
- `humanID` comes **only from the authenticated human session**, never from a path, query, header or body. No store function takes "read person X".
- `inPerson` and `inTenant` never nest. A test pins `pgScopePerson` to `inPerson` and lists the realm code that calls `inTenant` (the 118 read and the receipt copy only), in the shape of `TestOperatorScopeCallers`.

### 7.3 Tables

Migration: the next free rdb number. Every table: `person_id text NOT NULL REFERENCES public.humans (human_id) ON DELETE CASCADE CHECK (person_id ~ '^HUM-[0-9]+$')` first, `ENABLE` + `FORCE ROW LEVEL SECURITY`, no FK to any table carrying `tenant_id`, and **no column named `tenant_id`** (the workspace key is `workspace_id`, so no gate or copied policy mistakes a realm table for a workspace table).

| table | key | columns beyond `person_id` |
|---|---|---|
| `personal.profile` | `person_id` | `time_zone text NULL` (IANA, <= 64; NULL = the browser's: 118 C4), `locale text NULL`, `comm_prefs jsonb NOT NULL DEFAULT '{}'` (an object, <= 4 KB), `updated_at` |
| `personal.settings` | `(person_id, valid_from)` | `hours_limit_day_minutes int NULL` (NULL = off, 60..1440), `hours_limit_week_minutes int NULL` (NULL = off, 60..10080), `valid_from date NOT NULL`, `updated_at`. A change adds a row, so a past week is judged by the limit it had (118 C3) |
| `personal.hours_receipts` | `(person_id, workspace_id, day, label, rev)` | section 8.2 (the 118 C5 table) |
| `personal.receipt_due` | `(person_id, workspace_id)` | `reason` (`removed`, `access_until`, `workspace_deleted`), `due_at`, `last_open_from date NULL` (first day not final at copy time), `done_at NULL` |

### 7.4 The policy

The same on every table:

- `CREATE POLICY person_scope ON personal.<t>`
- `USING (person_id = NULLIF(current_setting('app.person_id', true), '') AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator')`
- `WITH CHECK` the same expression.

Why each clause:
- The `NULLIF` guard (the CLE-3416 shape of rdb 0151): an unset or empty `app.person_id` matches nothing.
- `app.tenant_id` unset: a workspace scope reads 0 realm rows and writes none. Section 5's "never set together" becomes a database fact, not a code habit.
- Not the operator scope, and **no `operator_scope` policy**: `asOperator` reads 0 realm rows. Permissive policies OR together, so T-C1 asserts exactly one policy per table (plus the one sweeper policy of 8.1).

### 7.5 Grants

A `personal` block in `runtime-grants.sql`, run as the schema owner after `spool migrate`:

- `GRANT USAGE ON SCHEMA personal` to the runtime login.
- `SELECT, INSERT, UPDATE, DELETE` on `profile` and `settings`.
- `SELECT, INSERT` only on `hours_receipts`: no `UPDATE`, no `DELETE` (append-only, the rdb 0157 rev-log shape).
- `SELECT, INSERT, UPDATE` on `receipt_due`.
- **No default privileges** in `personal`: a new realm table is invisible to the hub until it is granted by name.
- `spool_search_reader` (rdb 0143) and any later reader role get no `USAGE` on `personal`.

The runtime login is NOSUPERUSER, NOBYPASSRLS and owns nothing, so it cannot drop the policy or turn FORCE off. With FORCE on, even the schema owner reads 0 rows without the setting.

### 7.6 Operator access

v1 has **no operator read** of a realm: 0 rows under every operator path. A logged break-glass read (a `SECURITY DEFINER` function that first writes an access-log row the person can see, run only by a named owner action) is owner question OQ-1. This replaces section 5's "operator access is strictly logged", which had no mechanism behind it.

## 8. Receipts

### 8.1 When: copy first, change second

Each step is its own transaction; the scopes are never set together.

1. `inTenant(W)`: read the leaver's entries and period states through the existing 107 store reads (no new SQL on `hours_*`, so 107's 1.7 grep test stays green), plus each target's label and the approver's display name, as strings.
2. `inPerson(leaver)`: insert the `hours_receipts` rows at `rev = 0` (`ON CONFLICT DO NOTHING`, so a retry is idempotent) and the `receipt_due` row (`done_at` set unless a day is still open, 8.3).
3. Only then the change: the membership removal or the workspace delete.

| trigger | how |
|---|---|
| removal or ban | steps 1..3 in the request. **A failed copy blocks the removal** (503 `receipt_failed`, retried): never a leaver without a receipt (118 C5) |
| `access_until` passes | a sweep (a named action on the existing sweep cadence) finds memberships past `access_until` through the membership list (its only operator read) and runs steps 1..2 as the person. The expiry itself already stopped access |
| workspace deleted | the delete action runs steps 1..2 for every member before `DELETE FROM tenants`; a delete that cannot copy is refused (OQ-6) |
| the last period becomes final (8.3) | the sweep reads open `receipt_due` rows through `personal.due_receipts(now)`: a `SECURITY DEFINER` function owned by a NOLOGIN NOBYPASSRLS role `spool_realm_sweeper` (the `spool_search_reader` precedent) that returns only `(person_id, workspace_id)` and can read no other realm table |

Synthetic members (clones, demo stays) get no receipt. A rejoin does not merge receipts back; a later leave copies again and the PK keeps the first copy of a day.

### 8.2 What: 118 D4's list, nothing more

`personal.hours_receipts`, one row per (day, label):

| column | from |
|---|---|
| `workspace_id text` | the tenant id as a copied value, no FK |
| `workspace_name text` | the workspace display name at copy time |
| `day date`, `minutes int` (0..1440) | `hours_entries` |
| `label text` (<= 200) | `job:` -> 107 FR-18 job `name` + `site`; `t:`, `ch:`, `dm:`, `cal:` -> `topic`, `channel`, `direct message`, `meeting`; `ws` -> `workspace`. Two entries with one label on one day are summed |
| `kind text` | 107 FR-27 (`work`, `travel`, `wait`, `absence`) |
| `period_start`, `period_end date` | the 107 period the day belongs to |
| `approval_state text` | `open`, `approved`, `frozen`, `final`, `returned` |
| `approver_name text NULL`, `decided_at timestamptz NULL` | the period's decider, resolved to a display name at copy time (how long it is kept: OQ-3 = 118 Q8) |
| `rev smallint NOT NULL DEFAULT 0 CHECK (rev IN (0, 1))` | 0 = at leave, 1 = the one refresh |
| `copied_at timestamptz` | |

Never copied: the entry note, `updated_by`, the target id (`t:<topic>` points into content), `hours_minutes`, any message, title or file. Spans (times of day) only if the owner says so (OQ-2 = 118 Q5).

### 8.3 Immutable, with one refresh

- No `UPDATE` or `DELETE` grant: a row once written never changes, and an attempt fails on privilege, not on code.
- 107 Q8 is open, so the leaver's last period may still be open at leave time (`receipt_due.last_open_from`). When that period freezes or is approved, the sweep appends `rev = 1` rows for those days only and closes `receipt_due`. After that nothing is appended. Under OQ-11 B (= 118 Q6 B) there is no refresh, and `rev` stays 0.
- A workspace deleted before the refresh leaves `rev = 0`, shown as "last period not final".
- The view reads `max(rev)` per (workspace, day, label).
- The person's own delete of a receipt (erasure) is OQ-4; if yes, it goes through one `SECURITY DEFINER` function that checks the person scope itself, never through a `DELETE` grant.

## 9. The contract with 118 (the realm side of 118 C1..C7)

| 118 | 119 provides |
|---|---|
| **C1 identity** | 6.3 point 4 |
| **C2 route home** | The realm route group: `GET /v1/me/realm/hours`, `PUT /v1/me/realm/hours`, `GET /v1/me/realm/targets` (118 5.2, 7), plus `GET`/`PUT /v1/me/realm/settings`, `GET`/`PUT /v1/me/realm/profile`, `GET /v1/me/realm/receipts`. Human session only; 403 `person_only` under act-as (spec 054), for agents, box tokens and a time-accountant-only seat; 400 on an `X-Spool-Tenant` header or a `member=` parameter. The page `/me/hours` is a realm page, one lazy chunk; 119 owns the frame and navigation |
| **C3 settings** | `personal.settings` (7.3), `inPerson` only. The warning is computed on read, never stored, sent, pushed or logged |
| **C4 zone** | `personal.profile.time_zone` |
| **C5 receipts** | `personal.hours_receipts` (8.2), taken as in 8.1 |
| **C6 receipts in the view** | The realm route reads the receipts in its own `inPerson` transaction and shows a workspace with no live membership from them, marked "left on <date>, read-only". Never live and receipt data for the same workspace |
| **C7 nothing flows down** | REQ-6 (6.1) |

The 118 read runs `Memberships(caller)` (the existing allow-listed operator read of membership rows only), then one `inTenant(W)` per workspace with `member = caller`, at most 2 in flight, then one `inPerson` for settings, zone and receipts. 119 adds no operator-scoped read of anything else.

## 10. Hard isolation: the person's own database (byo-gcp)

byo-gcp today ([SPEC-spool-byo-gcp.md](../../doc/md/SPEC-spool-byo-gcp.md)) is a whole hub in a customer's own GCP project, status "later". For a **person** it means their realm in their own database.

| moves to the person's own DB | stays where it is |
|---|---|
| that person's `personal.*` rows: profile, settings, receipts, receipt_due | every workspace's hours, periods and content: they belong to the workspace |
| the same migration, policies and tests, run by `spool migrate` against a second DSN | `public.humans` and the sign-in identities on the hub where the person signs in |

- **v1 builds only the shared `personal` schema.** Because it has no FK into workspaces, a move later is a copy of rows, not a redesign.
- A move is a named action (`do_spl_realm_move`): copy as the person, verify the counts, delete the source as the person. The realm DSN is a Secret Manager reference in one hub-wide row, never a DSN in a table or a log. In the own DB the FK to `humans` becomes a CHECK on the id shape.
- A workspace on a **customer's own hub** is read across hubs only as the person, through that hub's own routes with the person's credential there: no DB link, no service account reading hours. Not in v1 (OQ-7). Until then the personal view shows such a workspace as a link, not as numbers.

## 11. Tests

On Postgres (`PRE_PUSH_TIER=full`), as the runtime role, never as the owner or a superuser. Every RLS test has a red control: the stated mutation, made on a throwaway branch, turns it red.

**Catalogue gates**
- **T-C1** (must-have: `TestRLSCoversEveryTenantTable` and `TestCrossTenantEveryTable` filter on `current_schema()` and cannot see `personal`) every table in `personal`: RLS enabled and FORCE on, exactly the `person_scope` policy (plus the sweeper policy on `receipt_due`), no `operator_scope`. Wired into `do_spl_db_rls_check`. Red control: a table without FORCE.
- **T-C2** no FK from `personal.*` to a table outside `personal` except `public.humans`; no column named `tenant_id` (118 T-D4b asserts the same).
- **T-C3** grants: the runtime role has no `UPDATE`/`DELETE` on `hours_receipts`; no default privileges in `personal`; `spool_search_reader` has no `USAGE` on `personal`.
- **T-C4** the receipt columns are exactly 8.2's list: a new column fails until REQ-5 names it.

**RLS negatives**
- **T-N1** another person: P and Q seeded in every table; under `inPerson(P)` 0 rows of Q in each, P's own rows > 0 (control); an insert stamped Q fails `WITH CHECK`.
- **T-N2** a workspace role never reads the realm: under `inTenant(W)`, with P a member of W, every `personal.*` table reads 0 rows and refuses an insert. Red control: drop the `app.tenant_id` clause.
- **T-N3** both settings in one crafted transaction: 0 rows.
- **T-N4** `asOperator`: 0 rows. Red control: add an `operator_scope` policy.
- **T-N5** no setting, or `app.person_id = ''`: 0 rows. Red control: drop the `NULLIF`.
- **T-N6** the schema owner without the setting reads 0 rows (FORCE).
- **T-N7** `inPerson` refuses `""`, `AGT-1` and `HUM-1; --` before any SQL; a person id in a path, query or body is ignored or 400.
- **T-N8** routes: 403 `person_only` under act-as, for an agent, a box token and a time-accountant-only seat; 400 on `X-Spool-Tenant`; another person, and a foreman, an admin and the owner of a shared workspace, get 404 on P's realm.

**Receipts**
- **T-R1** removal: one row per (day, label) with 8.2's columns; seeded notes and topic titles are found nowhere in `personal.*`; the workspace still holds P's hours.
- **T-R2** a stubbed copy failure: the removal answers 503 `receipt_failed` and the membership stays.
- **T-R3** `access_until` yesterday: the sweep takes the receipt; before that instant nothing is copied.
- **T-R4** workspace deleted with members P and Q: both have receipts after the cascade; a stubbed failure refuses the delete.
- **T-R5** last period open at leave, approved later: `rev = 1` rows for those days, `receipt_due` closed; a second approval appends nothing.
- **T-R6** `UPDATE` and `DELETE` on `hours_receipts` as the runtime role fail with `42501`, also inside `inPerson(P)`.
- **T-R7** `personal.due_receipts` returns only `(person_id, workspace_id)`; `spool_realm_sweeper` reads 0 rows of `profile`, `settings`, `hours_receipts`.

**The 118 contract**
- **T-K1** the 118 read for P in A and B and a left C: A and B ran in separate transactions with one tenant each and the realm read with none (a store spy); C comes only from receipts.
- **T-K2** no workspace route, export, push or log line carries a realm value (limit, zone, receipt id); 118 T-R2a and T-R2b run against these tables.
- **T-K3** `TestOperatorScopeCallers` gains no caller except the expiry sweep's membership list; 107's 1.7 grep test unchanged.

## 12. Panel and consensus

Seats, each signed against `7f6da1a7f`; guard (`git show --stat <sha>`: only its own review file) passed for all four.

| seat | agent | commit |
|---|---|---|
| s119-claude (editor) | c-787 | `5149ee82c` |
| s119-claude-2 | c-788 | `85420c529` |
| s119-claude-3 | c-789 | `f432eef3d` |
| s119-mistral | m-790 | `f6fd3b15f` |

### 12.1 Agreed by all four

- The four contradictions resolve as 6.3: D4's list, 107 FR-18, REQ-6 reworded, `person_id = humans.human_id`.
- FORCE RLS on `app.person_id` with the `NULLIF` guard; receipts are copies with no FK into a workspace; the personal view reads each workspace in its own scope as the person.
- One refresh of a receipt whose last period was open at leave time, if the owner picks OQ-11 A (= 118 Q6).
- Settings: a daily and a weekly limit, each optional, person-only.

### 12.2 Agreed by the three claude seats (mistral silent or differing, 12.3)

- The policy also refuses under a workspace scope and the operator scope; no `operator_scope` policy; v1 has no operator read.
- `personal` gets its own named grants, no default privileges; receipts are insert-only.
- `inPerson`, the session as the only source of the person id; scopes never nest.
- Receipt triggers beyond removal: `access_until` (a sweep) and workspace delete.

### 12.3 Disagreements and how they were settled

| point | seats | settled as | why |
|---|---|---|---|
| Name and email in the realm profile | mistral: copied into `personal.profiles`; claude x3: stay on `humans` | stay on `humans` (6.2 Q1) | one source; rdb 0006/0010 already hold them |
| FK to `humans` | s119-claude: none (easier byo move); -2, -3, mistral: yes | FK to `public.humans`, ON DELETE CASCADE | 3 of 4; it is identity, not a workspace; an own DB turns it into a CHECK (10) |
| Receipt table shape | s119-claude: receipts + lines with rev; -2: one table, rev 1/2 + `receipt_due`; -3: sets + lines, unbounded versions + `source_hash`; mistral: one table, updated on refresh | one table `personal.hours_receipts`, `rev` 0/1 in the PK, plus `receipt_due` | the 118 C5 shape, agreed with the 118 editor; append-only covers immutability without a hash |
| Receipt updated on refresh | mistral: `refreshed_at`, UPDATE granted; claude x3: insert only | insert only, `rev = 1` | 3 of 4; an UPDATE grant is what "immutable" forbids |
| Workspace key column | 118 C5: `tenant_id`; -3: `workspace_id` | `workspace_id` | the RLS gates key on `tenant_id`; agreed with the 118 editor |
| Label for a topic, channel, meeting, DM | s119-claude, -2, mistral: the target's display name; -3 and 118 C5: the type only | the type only | a title is content (D4, REQ-5); 118 C5 already settled it |
| A failed copy on removal | -2: the removal proceeds, the sweep retries; s119-claude, -3, 118 C5: the removal waits | the removal waits (503 `receipt_failed`) | never a leaver without a receipt; 3 of 4 with 118 |
| Write path from the realm screen | all four 119 seats: `PUT /v1/me/hours` with `X-Spool-Tenant` | `PUT /v1/me/realm/hours`, 107's write inside, one `inTenant(W)` per group (118 7.2) | `resolve.go:15..26`: `X-Spool-Tenant` names a box's tenant; a human's is the session's active one (found by the 118 panel) |
| Route names | `/v1/me/time` (three seats) vs `/v1/me/realm/hours` (118 v1.0-rc) | `/v1/me/realm/*` (9) | 118 is the consumer and named them first |
| byo-gcp reading | s119-claude: a customer's dedicated hub; -2, -3, mistral: the person's own DB | the person's own DB (10), not in v1 | the owner's words ("the person's own DB"); 3 of 4 |
| Approver id in the receipt | -3, mistral: id + name; -2: name + decided-at | name + decided-at, no id | an id of another person is a pointer the receipt does not need |
| Spans in receipts | mistral: yes; claude x3: owner's call | owner question OQ-2 (118 Q5) | not settled by the panel |

### 12.4 The 118 alignment

On `dispatch-151d85fc` the 118 editor (c-782) accepted `rev` in the C5 PK (so the Q6-A refresh can land), `workspace_id` instead of `tenant_id`, the FK to `public.humans`, the policy refusing a workspace scope and having no `operator_scope`, and mirroring 118 Q7 as a 119 owner question. All are folded into 118 C5 and 118 T-D4b with 118 v1.0.

### 12.5 Signatures of this fold

Each seat replies on `dispatch-151d85fc`: "s119-<seat> signs <sha>". v1.0 when all four have signed.

| seat | agent | signed sha |
|---|---|---|
| s119-claude | c-787 | (this fold, by the editor) |
| s119-claude-2 | c-788 | pending |
| s119-claude-3 | c-789 | pending |
| s119-mistral | m-790 | pending |

## 13. Questions for the owner (one list, deduplicated; the panel's recommendation first)

A question marked "= 118 Qn" is the same question as in 118 v1.0, in 118's wording: one answer covers both specs.

| # | question | options | from |
|---|---|---|---|
| **OQ-1** | Operator access to a person's realm | **A (recommended)**: none in v1, 0 rows under every operator path. B: a break-glass read, owner-run per call, that writes an access-log row the person sees | claude, -2, -3 |
| **OQ-2** (= 118 Q5) | Do **receipts keep times of day** (spans), so a past overlap stays exact? | **A (recommended)**: no, minutes per day as D4 lists. B: yes | all four; mistral recommends B |
| **OQ-3** (= 118 Q8) | How long the realm keeps the **approver's name** (another person's name) in a receipt | **A (recommended)**: the workspace's `hours.retention_years` at copy time (107 FR-34). B: as long as the receipt | all four; mistral recommends B |
| **OQ-4** | May a person **delete their own receipts** (erasure)? | **A (recommended)**: yes, through one function, never an edit. B: kept for the retention period regardless | claude, -2, -3 |
| **OQ-5** | Does a **disabled** membership (rdb 0074, reversible) count as leaving? | **A (recommended)**: no, only removal, expiry and workspace delete. B: yes, a receipt on every loss of access | -3 |
| **OQ-6** (= 118 Q7) | A **deleted workspace** (the tenant delete cascades every `hours_*` row): do its members get receipts? | **A (recommended)**: yes, the delete copies receipts first. B: no, D4 covers leaving only | -2, -3, 118 |
| **OQ-7** | Workspaces on a **customer's own hub** and a person's own DB (10) | **A (recommended)**: not in v1; the view shows such a workspace as a link. B: a signed receipt export the person imports. C: a cross-hub read as the person | all four |
| **OQ-8** (= 118 Q10) | A **personal download** (CSV of the person's own rows across workspaces, receipts included) | **A (recommended)**: not in the first version. B: yes, person-only | claude, -2, -3, 118 |
| **OQ-9** | Receipts for workspaces **left before 119 ships** | **A (recommended)**: none. B: a back-fill from hours still kept for members already removed | -3 |
| **OQ-10** | Does a realm **display name** override `humans.display_name` in the person's own views? | **A (recommended)**: no realm name in v1 (6.2 Q1). B: an override shown only to the person | -3 |
| **OQ-11** (= 118 Q6) | A receipt whose last period was **still open at leave time** | **A (recommended)**: refreshed once when that period freezes or is approved, then fixed. B: frozen at leave time | all four (8.3 is built for A; under B `rev` stays 0) |

## 14. Version log

| version | date | by | what |
|---|---|---|---|
| 0.1 | 2026-10-10 | draft (a-778) | context, scope, REQ-1..6, Q1..Q4, security baseline |
| 1.0-rc | 2026-10-10 | c-787 (editor) | panel fold of s119-claude, -2, -3 and s119-mistral: REQ-1, 4, 5, 6 reworded (6.1); Q1..Q4 settled (6.2); the 118 contradictions (6.3); schema, policy, grants (7); receipts (8); the 118 contract (9); own-DB isolation (10); tests (11); panel and consensus (12); owner questions OQ-1..11 (13, five of them = 118 Q5, Q6, Q7, Q8, Q10); sections 1..5 kept as written |

<!-- version: 1.0.0-rc · updated: 2026-10-10 · last-edit: 2026-10-10 -->
