signed against 7f6da1a7f

# Spec 119 review: seat s119-claude-3

**Seat**: s119-claude-3 (c-789) · **Reviewed**: [../spec.md](../spec.md) v0.1 at `7f6da1a7f` (64 lines) · **Editor**: seat s119-claude.
**Read beside it**: [118](../../118-multi-workspace-hours/spec.md) (footer 0.5.0) and its review [s118-claude-2](../../118-multi-workspace-hours/reviews/s118-claude-2.md) (`6f2b324f8`), [107](../../107-hours-tracking/spec.md) FR-18, FR-21, FR-34, rdb `0006_users_and_memberships.sql`, `0014_tenant_rls.sql`, `0074` (member `disabled_at`), `0113_membership_access_until.sql`, `0151_hours.sql`, `spool-hub-roles/runtime-grants.sql`, `internal/store/rls.go`, `rls_test.go`, `crosstenant_test.go`, [SPEC-spool-byo-gcp.md](../../../doc/md/SPEC-spool-byo-gcp.md).

**Settled by the owner, not reopened here**: a personal realm above workspaces; ONE schema `personal` with person-scoped FORCE RLS; workspaces stay on RLS; hard isolation = the person's own DB (byo-gcp); receipts = hours only, as copies, no FKs into workspaces.

## 0. Facts from the code that shape this review

| fact | where | consequence for 119 |
|---|---|---|
| A person is one hub-wide `humans.human_id` (`HUM-[0-9]+`), outside RLS; workspace hours key on it as `member_id` | rdb 0006 lines 19..27, 0151 | `person_id` IS `human_id`; an FK to `humans` is allowed (hub-wide, not a workspace) |
| The scope is transaction-local `set_config(..., true)`; a statement with no scope sees 0 rows | `rls.go` lines 17..20, rdb 0014 | the realm gets a third setting, `app.person_id`, in its own transaction, the same way |
| The RLS gates (`TestRLSCoversEveryTenantTable`, `TestCrossTenantEveryTable`) list tables `WHERE n.nspname = current_schema()` | `rls_test.go:78`, `crosstenant_test.go:358..361` | **a table in schema `personal` is invisible to every existing RLS gate**: 119 needs its own gate (T1), or a realm table without FORCE ships green |
| `runtime-grants.sql` grants and sets default privileges `IN SCHEMA public` only | `spool-hub-roles/runtime-grants.sql` | schema `personal` needs its own `GRANT USAGE` and default privileges for the runtime role, and none for `spool_search_reader` |
| "Leaving" has four shapes today: member removed (`DELETE FROM tenant_memberships`, `humans_rbac_postgres.go:168`), suspended (`disabled_at`, 0074), expired (`access_until`, 0113, which an admin can extend), workspace deleted (`ON DELETE CASCADE` from `tenants`) | rdb 0006, 0074, 0113 | the receipt trigger must cover all four, and two of them are reversible |
| Expiry has no event: the hub reads a past `access_until` as absent | 0113 header | an expired membership needs a sweep to take its receipt |

## 1. Per REQ and Q, one line each

| item | verdict | line |
|---|---|---|
| REQ-1 | **change** | Identity already exists hub-wide (`humans`, `human_identities`, rdb 0006); the realm adds only a **profile** keyed `person_id = humans.human_id`. Say so, and that email stays in `human_identities` (verified at sign-in), never copied into the realm. |
| REQ-2 | **agree** | Cite the contract: the realm hosts 118's view (s118-claude-2 C1), read as section 3 (b) below. |
| REQ-3 | **agree** | Name the first settings: the working-time limit, weekly and daily minutes (118 D3, s118-claude-2 C2), and the person's zone (C4). |
| REQ-4 | **change** | "Upon leaving" is undefined: name the four ways (section 0) and the moment the copy is taken (section 3 (c)). |
| REQ-5 | **change** | "Only the hours" falls short of 118 D4, which also keeps workspace name, job/site label, approval state and approver. Say: "the fields 118 D4 lists, and no content: no topic or channel title, no note, no message". |
| REQ-6 | **change** | Read literally it forbids 118 REQ-4 (entering hours from the realm). Reword: contradiction 3 below. |
| Q1 | **change** | B, minus email (REQ-1 above): `display_name`, `avatar_ref`, `locale`, `time_zone`, communication preferences. Whether the realm name replaces `humans.display_name` is OQ-1. |
| Q2 | **agree** | B. A PDF is an export of B, not a second store (OQ-5). |
| Q3 | **change** | Neither A nor B: take 118 D4's list as given (contradiction 1), with the label from 107 FR-18 (contradiction 2). |
| Q4 | **agree** | Settled: `personal`. |
| section 5 "Scope Separation" | **agree, make it a database rule** | The realm policy also requires `app.tenant_id` unset (section 3 (a)), so the separation holds even if code sets both. |
| section 5 "Cross-Workspace Reads" | **agree** | Add: never under `asOperator`; one workspace per transaction; at most 2 in flight (hub pool 8). |
| section 5 "Operator access is strictly logged" | **change** | There is no logged operator path today. v1: **no** `operator_scope` policy on realm tables, so operators read 0 rows. A logged break-glass path is OQ-3. |
| section 5 "Testing" | **missing** | The existing gates do not see schema `personal` (section 0). Tests T1..T16 below. |
| section 5 "Future phases" | **agree** | Per-person encryption stays phase 2. |

## 2. The four contradictions from s118-claude-2, and how 119 resolves each

1. **Q3 omits 118 D4's approval state and approver.** 118 D4 is an owner decision; 119 takes it whole. The receipt holds: day, minutes, workspace display name, target label, approval state, approver id and approver display name (both copied at take time). Q3 is closed by citing D4, not by a new option. How long the approver's name is kept is OQ-4.
2. **Q3's job/site label is defined in 107 FR-18, not 118.** Cite 107 FR-18. The label per target kind:
   - `job:` -> FR-18's job `name` and `site`;
   - `ws` / "other" -> the fixed word "Workspace" or "Other";
   - `t:`, `ch:`, `cal:`, a DM -> the **target kind only** ("Topic", "Channel", "Meeting", "Direct message"). A topic or channel title is content (REQ-5), so it is never copied.
3. **REQ-6 forbids 118 REQ-4's writes.** New wording: "**No realm row is copied into a workspace and no workspace reads the realm.** When the person enters hours from a realm screen, each entry is written by the hub's existing workspace route, in that workspace's scope, under that workspace's rules, exactly as if entered inside the workspace. The realm stores nothing about the write." The realm is a **screen and a store**, not a channel: it has no write path into a workspace of its own.
4. **`person_id` must equal the `HUM-*` id.** `person_id text NOT NULL REFERENCES humans (human_id) ON DELETE CASCADE CHECK (person_id ~ '^HUM-[0-9]+$')`. One identity, no mapping table. The FK points at the hub-wide `humans`, not at a workspace, so it keeps the "no FKs into workspaces" rule. An agent (`AGT-*`) has no realm.

## 3. Proposals

### (a) The `personal` schema and its FORCE RLS

**Migration** (next free rdb number, run as the schema owner like every other):

```sql
CREATE SCHEMA IF NOT EXISTS personal;

CREATE TABLE personal.profile (
    person_id    text PRIMARY KEY REFERENCES humans (human_id) ON DELETE CASCADE
                 CHECK (person_id ~ '^HUM-[0-9]+$'),
    display_name text NULL CHECK (display_name IS NULL OR length(display_name) <= 200),
    avatar_ref   text NULL CHECK (avatar_ref IS NULL OR length(avatar_ref) <= 512),
    locale       text NULL CHECK (locale IS NULL OR locale ~ '^[a-z]{2}(-[A-Z]{2})?$'),
    time_zone    text NULL CHECK (time_zone IS NULL OR length(time_zone) <= 64),
    prefs        jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(prefs) = 'object'),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE personal.settings (
    person_id  text NOT NULL REFERENCES humans (human_id) ON DELETE CASCADE,
    key        text NOT NULL CHECK (key IN ('hours.limit_weekly_minutes', 'hours.limit_daily_minutes')),
    value      jsonb NOT NULL,
    valid_from date NOT NULL DEFAULT current_date,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (person_id, key, valid_from)
);

CREATE TABLE personal.receipt_sets (
    person_id      text NOT NULL REFERENCES humans (human_id) ON DELETE CASCADE,
    workspace_id   text NOT NULL,          -- a copy of tenant_id, NO FK
    workspace_name text NOT NULL,
    version        int  NOT NULL CHECK (version >= 1),
    reason         text NOT NULL CHECK (reason IN ('removed', 'disabled', 'expired', 'workspace_deleted', 'period_final')),
    taken_at       timestamptz NOT NULL DEFAULT now(),
    last_open_from date NULL,              -- first day not yet final at take time
    source_hash    text NOT NULL,          -- sha256 of the canonical lines
    PRIMARY KEY (person_id, workspace_id, version)
);

CREATE TABLE personal.receipt_lines (
    person_id      text NOT NULL,
    workspace_id   text NOT NULL,
    version        int  NOT NULL,
    day            date NOT NULL,
    target_kind    text NOT NULL CHECK (target_kind IN ('job', 'topic', 'channel', 'meeting', 'dm', 'workspace', 'other', 'absence')),
    target_label   text NOT NULL DEFAULT '' CHECK (length(target_label) <= 300),
    minutes        int  NOT NULL CHECK (minutes BETWEEN 0 AND 1440),
    approval_state text NOT NULL,
    approver_id    text NULL,
    approver_name  text NULL,
    PRIMARY KEY (person_id, workspace_id, version, day, target_kind, target_label),
    FOREIGN KEY (person_id, workspace_id, version)
        REFERENCES personal.receipt_sets (person_id, workspace_id, version) ON DELETE CASCADE
);
```

Notes:
- The workspace key is named `workspace_id`, **never `tenant_id`**: no gate or reader can mistake a realm table for a workspace table, and no workspace policy shape applies to it by accident.
- No FK to `tenants`, `hours_*` or `tenant_memberships`. A deleted workspace leaves the receipt intact (that is the point of a copy).
- The target id (`t:<topic>`) is not copied either: an id is a pointer back into workspace content. Two topic targets on one day merge into one "Topic" line (minutes summed), which is what a receipt needs.

**Policies**, every table in `personal` (same shape, `<t>` each table):

```sql
ALTER TABLE personal.<t> ENABLE ROW LEVEL SECURITY;
ALTER TABLE personal.<t> FORCE ROW LEVEL SECURITY;
CREATE POLICY person_scope ON personal.<t>
    USING (person_id = NULLIF(current_setting('app.person_id', true), '')
           AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL
           AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator')
    WITH CHECK (person_id = NULLIF(current_setting('app.person_id', true), '')
           AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL
           AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator');
```

- The NULLIF guard (CLE-3416, as rdb 0151): an empty `app.person_id` matches nothing.
- **A workspace scope reads 0 realm rows** (the `app.tenant_id` clause): if a bug sets both settings in one transaction, the realm goes dark rather than mixing scopes. This makes section 5's "never set together" a database fact, not a code habit.
- **No `operator_scope` policy.** `asOperator` reads 0 rows here: the third clause keeps the person scope from combining with the operator setting, and T7 (with T1's "exactly one policy") catches a permissive `operator_scope` copied in later, since permissive policies OR together. Operators include the retention sweep and `spool migrate`; neither needs to read a person's realm.
- `receipt_sets` and `receipt_lines` are **insert-only** (proposal (c)): no UPDATE grant. DELETE is the person's erasure only: OQ-2.

**Grants** (`runtime-grants.sql`, a new block):

```sql
GRANT USAGE ON SCHEMA personal TO :"runtime_role";
GRANT SELECT, INSERT, UPDATE, DELETE ON personal.profile, personal.settings TO :"runtime_role";
GRANT SELECT, INSERT, DELETE ON personal.receipt_sets, personal.receipt_lines TO :"runtime_role";
REVOKE UPDATE ON personal.receipt_sets, personal.receipt_lines FROM :"runtime_role";
```

No `ALTER DEFAULT PRIVILEGES` for `personal`: each new realm table is granted by name, so a new receipt-like table cannot inherit UPDATE silently. `spool_search_reader` (rdb 0143) and any later reader role get **no** `USAGE` on `personal`. The hub keeps its `search_path` at `public`; every realm statement names `personal.<table>`.

**"As the person, never a service/superuser read"**: the hub's runtime login is NOSUPERUSER NOBYPASSRLS (rdb 0014 header; the hub logs which it got). The store opens a realm transaction only through one new helper, beside `inTenant`:

```go
const pgScopePerson = `SELECT set_config('app.person_id', $1, true)`

// inPerson runs fn in one transaction scoped to the person. It refuses an
// empty or non-HUM id, and never sets app.tenant_id.
func (s *Postgres) inPerson(ctx context.Context, personID string, fn func(pgx.Tx) error) error
```

`personID` comes **only** from the authenticated human session, never from a request field, a path or a header. The realm routes refuse act-as (054), agent tokens and box tokens (403 `person_only`), and refuse an `X-Spool-Tenant` header (400), as s118-claude-2 C1 asks. The one non-session caller is the receipt writer (c), which only INSERTs and reads `max(version)` for that person and workspace.

### (b) Reading and writing workspace hours as the person (the 118 contract)

| 118 needs | how the realm does it |
|---|---|
| **C1 the unified view** `GET /v1/me/time?from=&to=` | 1) `Memberships(ctx, humanID)` lists the live memberships (the one existing operator-scoped read; it reads membership rows, never hours). 2) Per workspace, one `inTenant(W)` transaction runs the existing `HoursEntries` / `HoursPeriods` (and spans, if 107 takes s118-claude-2 OQ-1) with `member_id = session human`. 3) One `inPerson` transaction reads the limit and the receipts of workspaces with no live membership. 4) The pure overlap function (s118-claude-2 2.2) merges them. Nothing is stored. At most 2 workspace transactions in flight, at most 62 days, at most 20 workspaces. A failed workspace answers `unavailable`, never retried under a wider scope. |
| **C2 the limit setting** | `personal.settings` keys `hours.limit_weekly_minutes` (0 = off, 60..10080) and `hours.limit_daily_minutes` (0 = off, 60..1440), with `valid_from`. `GET` / `PUT /v1/me/realm/settings`, `inPerson` only. The warning is computed on read and never stored, sent or pushed (118 D3). |
| **C3 leaver receipts** | Proposal (c). In the view, a workspace with a live membership comes from live reads; one without comes from its latest receipt version. Never both for the same workspace. |
| **C4 the zone** | `personal.profile.time_zone`; absent, the WUI's zone. |
| **C5 one identity** | Contradiction 4. |
| **writes (118 REQ-4)** | The realm screen calls the **existing** `PUT /v1/me/hours` once per workspace group, each in that workspace's scope with that workspace's checks (freeze, day cap, target belongs to it). The realm route layer adds no write SQL on `hours_*`; a grep test pins that (T12). No cross-workspace atomicity, and the screen says so (s118-claude-2 4.2). |

The workspace side never learns the realm exists: no workspace route, table, export, push or log line carries a realm value.

### (c) Receipt copy: when, what, immutable

**When.** A receipt is taken at the first moment the person's live access to a workspace ends, by any of the four shapes:

| shape | trigger | where |
|---|---|---|
| removed | before the membership DELETE | member removal (`humans_rbac_postgres.go`), and self-leave if it exists |
| disabled | when `disabled_at` is set | the 0074 suspend path |
| expired | a sweep finds `access_until <= now()` with no receipt set taken after it | a new named action on the existing sweep cadence |
| workspace deleted | before the tenant DELETE (the cascade would take the hours) | the workspace delete path, once per member |

Clones and demo members (`clones.go`, `demo_stay.go`) are synthetic and get no receipt.

**How, in order** (copy first, change second):
1. `inTenant(W)`: read the leaver's `hours_entries` and `hours_periods` (every day still kept under FR-34 retention), the label per contradiction 2, the approver's id and display name. Read only.
2. `inPerson(leaver)`: `INSERT` a `receipt_sets` row with `version = max + 1` and its `receipt_lines`.
3. Then the membership change runs (remove, disable, delete; expiry is passive).

If 3 fails after 2, the person has a receipt and still a live membership; the view shows live data while the membership is live, so the extra version is harmless. If 2 fails, 3 is not run and the call answers 503 `receipt_failed`, to be retried: a person never leaves without a receipt. Two transactions, never one: the scopes are never set together.

**What.** Exactly 118 D4: per (day, target): minutes, approval state, approver; per set: workspace name, reason, taken_at. Weeks are derived from `day` on read. Nothing else: no note, no topic title, no message, no target id, and no spans unless the owner says so (s118-claude-2 OQ-3).

**Immutable.**
- No UPDATE grant and no UPDATE path: a line once written never changes.
- A later change is a **new version**, never an edit. Two cases make one:
  - **The last period was not final at leave time** (107 Q8 is open). `last_open_from` marks it. When the workspace later freezes or approves that period, one `period_final` set is taken for those days. After that, no more versions for that leave.
  - **Access comes back and ends again** (an admin extends `access_until`, re-enables, re-invites): the next end takes a new full set.
- The view shows the latest version per workspace; older versions stay readable by the person as history ("taken 2026-10-10, updated 2026-10-24").
- `source_hash` lets a test, and the person, check that a version was not altered.

### (d) byo-gcp: what moves, what stays

byo-gcp is a dedicated hub and database in a GCP project on the customer's bill ([SPEC-spool-byo-gcp.md](../../../doc/md/SPEC-spool-byo-gcp.md), status "later"; spec 047 D2 "not now"). For the realm:

| moves to the person's own DB | stays where it is |
|---|---|
| the whole `personal` schema of that person: profile, settings, every receipt set and line | every workspace's hours, periods and content: the workspace owns them, in its own DB |
| the `humans` row and verified identities needed to sign in there | the shared hub's `humans` row, so the person stays a member of shared workspaces |

- **Same schema, same policies, same tests** in the dedicated DB. A move is an export of the person's rows (`inPerson`, read as the person) and an import there; the shared hub then deletes them (the person's own DELETE, OQ-2), so no copy is left behind.
- **The cross-workspace view across two DBs** is a hub-to-hub read **as the person**: the realm hub calls each workspace hub's existing `/v1/me/hours` with the person's own credential for that hub. No DB link, no service account that reads hours, no FK across.
- **Receipts after a move**: the shared hub's receipt writer cannot reach the person's DB. It writes into a per-person outbox on the shared hub (`personal.receipt_outbox`, same RLS), and the person's hub pulls it as the person and deletes it. Until then the receipt lives in the shared realm under the same policies.
- Phase 2 at the earliest. v1 builds the one shared `personal` schema so that a move is a copy of rows, not a redesign.

### (e) Tests

Store tests run on Postgres (`PRE_PUSH_TIER=full`), as `hours_rls_test.go`. "Red control" = the stated mutation makes the test fail.

**Schema gates**
- **T1 every realm table is guarded**: every table in schema `personal` has `person_id`, `relrowsecurity AND relforcerowsecurity`, and exactly the `person_scope` policy. Red control: a table without FORCE fails. (The `current_schema()` gates do not see it, section 0.)
- **T2 no FK into workspaces**: a catalogue query over `pg_constraint` finds no foreign key from `personal.*` to any table other than `humans` and `personal.*`.
- **T3 no `tenant_id` column** in `personal.*`.
- **T4 grants**: the runtime role has no UPDATE on `receipt_sets` / `receipt_lines`; `spool_search_reader` has no USAGE on `personal`.

**RLS negatives**
- **T5 another person reads 0 rows**: P and Q seeded in every realm table; under `inPerson(P)`, `SELECT count(*) ... WHERE person_id <> P` is 0 in every table, and P's own count is > 0 (control). P's unscoped UPDATE / DELETE and a Q-stamped INSERT change nothing of Q's.
- **T6 a workspace role never reads the realm**: under `inTenant(W)` every realm table reads 0 rows. With **both** `app.tenant_id = W` and `app.person_id = P` set in one transaction, still 0 rows. Red control: drop the `app.tenant_id` clause and it fails.
- **T7 operator reads 0 rows**: under `asOperator` every realm table reads 0. Red control: a test-only `operator_scope` policy makes it fail.
- **T8 no scope, no rows**: a plain pool query reads 0; an empty `app.person_id` reads 0 (NULLIF).
- **T9 `inPerson` refuses** `""`, `AGT-1` and `HUM-x`; a handler test shows a `person_id` in body, path or header is ignored or refused with 400.
- **T10 routes**: act-as, an agent token and a box token get 403 `person_only`; `X-Spool-Tenant` gets 400; a foreman, an owner and an admin of a shared workspace reading P's realm get 404.

**Receipts**
- **T11 each leave shape takes one set**: removed, disabled, expired (sweep) and workspace deleted each produce exactly one new version with D4's fields. The workspace's hours are seeded with a note and a topic title, and a field-level grep of the receipt rows finds neither. Workspace deleted: the receipt is still readable after the tenant cascade.
- **T12 the realm writes no hours**: a grep test over the realm routes and store finds no SQL on `hours_*` outside the existing hours store file (keeps 107 section 1.7's test green).
- **T13 immutable**: an UPDATE on `receipt_lines` as the runtime role fails with a privilege error; a later `period_final` creates version 2 and leaves version 1 identical (`source_hash`).
- **T14 copy first**: a failing receipt insert makes the member removal answer 503 and leaves the membership in place.
- **T15 operator scope callers**: `TestOperatorScopeCallers` gains no realm caller; the expiry sweep's only operator read is the membership list.

**118 contract**
- **T16** the unified view for P in A and B: A's and B's reads ran in separate transactions with one tenant each (a store spy records the settings per transaction), the realm read ran with no tenant set, and no response under a workspace route carries a realm value (limit, actual, overlap).

## 4. Owner questions (not decided here)

- **OQ-1** Does the realm `display_name` replace `humans.display_name` (one name everywhere) or only override it in the person's own views?
- **OQ-2** May the person delete their own receipts (erasure of their own copy), or are receipts kept for a retention period regardless? This seat built "the person may delete, nobody may edit".
- **OQ-3** Operator access to a realm: none at all (v1 as proposed: 0 rows), or a break-glass path that writes an audit row the person can see?
- **OQ-4** The approver's name in a receipt is another person's data: keep it as long as the receipt, or for 107 FR-34's retention years, after which only "approved" remains?
- **OQ-5** A PDF or CSV export of receipts for the person (Q2 A as an export of B): in v1 or later?
- **OQ-6** Do **suspension** (`disabled_at`) and **expiry** (`access_until`) count as leaving for a receipt, or only removal and workspace deletion? This seat takes a receipt on all four, because the person loses live access in all four.
- **OQ-7** Receipts for workspaces left **before** 119 ships: none, or a back-fill from the hours still kept for members already removed?

<!-- version: 0.1.0 · updated: 2026-10-10 · seat s119-claude-3 · last-edit: 2026-10-10 -->
