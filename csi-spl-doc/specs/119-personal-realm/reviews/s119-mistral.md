signed against 7f6da1a7f

# Spec 119 review: seat s119-mistral

**Reviewed**: `csi-spl-doc/specs/119-personal-realm/spec.md` at `7f6da1a7f` (v0.1).
**Read beside it**: spec 118 review (s118-claude-2), spec 107 (origin/master), and the hub code (`internal/store/rls.go`, `internal/store/memberships.go`, `internal/store/hours_postgres.go`).

## 1. Per REQ/Q: agree / change / missing

| Item               | Verdict       | One line                                                                                                                                                                                                                                                                 |
|--------------------|---------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **REQ-1**          | **agree**     | Identity and profile are clearly scoped to the personal realm.                                                                                                                                                                                                         |
| **REQ-2**          | **agree**     | Unified view across workspaces is well-defined, but missing the **contract** with spec 118 (see proposals (b)).                                                                                                                                                         |
| **REQ-3**          | **agree**     | Personal settings (e.g., working-time limit) are explicitly supported.                                                                                                                                                                                                 |
| **REQ-4**          | **change**    | "Read-only receipts" is ambiguous. Clarify: receipts are **immutable copies** of hours at leave time, stored in the realm, and **never updated** after the leave event (except for OQ-3).                                                                               |
| **REQ-5**          | **agree**     | Content redaction is explicit: receipts contain only hours, workspace name, and job/site label.                                                                                                                                                                        |
| **REQ-6**          | **change**    | Wording is too restrictive. Proposed: "Data in the personal realm is **never copied into workspaces**. Writes into workspaces from the realm screen use the workspace's own routes, in that workspace's scope, as if entered inside the workspace." (Contradiction 4). |
| **Q1**             | **agree**     | Recommendation B (name, email, avatar, communication preferences) is appropriate.                                                                                                                                                                                       |
| **Q2**             | **agree**     | Recommendation B (interactive read-only view) is correct.                                                                                                                                                                                                               |
| **Q3**             | **change**    | Contradiction with 118 D4: **approval state and approver must be included** in receipts. Proposed: "Total hours, dates, workspace name, job/site label (as defined in spec 107 FR-18), approval state, and approver." (Contradiction 2).                              |
| **Q4**             | **agree**     | Schema name `personal` is correct.                                                                                                                                                                                                                                      |


## 2. Contradictions and gaps

### Against spec 118 and 107
1. **Q3 vs 118 D4 (Contradiction 2)**
   - 119's Q3 omits **approval state and approver** from receipts, but 118 D4 explicitly requires them.
   - **Resolution**: Include both in receipts. This aligns with 118's requirement for receipts to act as "pay receipts."

2. **Job/site label definition (Contradiction 3)**
   - 119 Q3 cites "job/site label (as defined in Spec 118)," but 118 does not define it. The label is defined in **107 FR-18** (job `name` + `site`).
   - **Resolution**: Cite 107 FR-18 in 119.

3. **REQ-6 vs 118 REQ-4 (Contradiction 4)**
   - 119 REQ-6 forbids data flow from the realm into workspaces, but 118 REQ-4 requires writing hours into workspaces from the realm screen.
   - **Resolution**: Clarify 119 REQ-6 as proposed above.

4. **`person_id` vs `member_id` (Contradiction 5)**
   - 119 uses `app.person_id`, but hours rows key on `member_id = HUM-*` (107 section 3.2).
   - **Resolution**: State `person_id = humans.human_id` in 119 to avoid a mapping table.

5. **Receipt timing (Gap)**
   - 119 does not specify **when receipts are taken** if the last period is still open at leave time.
   - **Resolution**: Take receipts at leave time, then **refresh once** if the last period later freezes or is approved (118 C3).


## 3. Proposals

### (a) Tables and FORCE RLS policy for the `personal` schema
**Tables**:
1. `personal.profiles`
   - `person_id` (text, PK): `HUM-*`, FK to `humans.human_id`.
   - `name` (text)
   - `email` (text)
   - `avatar_url` (text, nullable)
   - `communication_preferences` (jsonb, nullable): e.g., `{"email_notifications": true}`.
   - `time_zone` (text, nullable): e.g., `Europe/Helsinki` (C4).

2. `personal.settings`
   - `person_id` (text, PK): FK to `personal.profiles`.
   - `weekly_minutes_limit` (integer, nullable): 0 = off, 60..10080 (C2).
   - `daily_minutes_limit` (integer, nullable): 0 = off, 60..1440 (C2).
   - `effective_from` (date, nullable): start date for the limit.
   - `effective_until` (date, nullable): end date for the limit.

3. `personal.receipts`
   - `receipt_id` (uuid, PK)
   - `person_id` (text): FK to `personal.profiles`.
   - `workspace_id` (text): workspace display name (not a FK).
   - `day` (date)
   - `target_label` (text): job/site label (107 FR-18) or target display name.
   - `minutes` (integer)
   - `approval_state` (text): `open`, `approved`, `frozen`, `final`, `returned`.
   - `approver_id` (text, nullable): `HUM-*` of the approver (OQ-6).
   - `taken_at` (timestamptz): when the receipt was created.
   - `refreshed_at` (timestamptz, nullable): when the receipt was last refreshed (C3).

**RLS Policy**:
- `FORCE ROW LEVEL SECURITY` on all tables.
- Policy: `person_id = NULLIF(current_setting('app.person_id', true), '')`.
- Grants: `SELECT, INSERT, UPDATE` for the person only. No `DELETE` (immutable receipts).


### (b) Contract with spec 118: how the realm reads/writes workspace hours
**Contract (C1-C5)**:
1. **C1**: Realm route `GET /v1/me/time` (no `X-Spool-Tenant` header) returns:
   - Per workspace: `workspace_id`, `display_name`, `minutes`, `state`, `spans` (if available).
   - Per day: `reported`, `actual`, `overlap`, `unplaced`, and overlap intervals.
   - Realm settings: `weekly_minutes_limit` and `daily_minutes_limit` (C2).

2. **C2**: Realm settings are stored in `personal.settings` and read/written only by the person (RLS).

3. **C3**: Receipts are taken at leave time and refreshed **once** if the last period later freezes or is approved. Fields:
   - `day`, `minutes`, `workspace_id`, `target_label`, `approval_state`, `approver_id`.

4. **C4**: The person's time zone is stored in `personal.profiles.time_zone`. Defaults to the WUI's zone if absent.

5. **C5**: `person_id = humans.human_id` (no mapping table).


### (c) Receipt copy: when, what, immutability
- **When**: At leave time (membership removed or `access_until` passed). Refreshed **once** if the last period later freezes or is approved.
- **What**: One row per `(day, target)` with fields from C3.
- **Immutability**: Receipts are **never updated** after the refresh. No foreign keys into workspace tables.


### (d) BYO-GCP hard isolation: what moves, what stays
- **Moves to the realm DB**:
  - `personal` schema tables (`profiles`, `settings`, `receipts`).
  - RLS policies and grants for `app.person_id`.
- **Stays in the workspace DB**:
  - All workspace tables (`hours_entries`, `hours_minutes`, etc.).
  - Workspace-specific RLS policies (`app.tenant_id`).
- **Cross-DB reads**: The realm route reads workspace data **in the workspace's own scope** (118 1.2), never directly.


### (e) Tests
1. **RLS negatives**:
   - T1: Person P cannot read Person Q's realm data.
   - T2: Person P cannot read workspace data outside their memberships.
   - T3: A foreman in workspace A cannot read P's realm data or overlap numbers.

2. **Receipts**:
   - T4: Receipts are created at leave time and refreshed once if the last period later freezes.
   - T5: Receipts contain exactly the fields from C3 and no workspace FKs.

3. **Realm settings**:
   - T6: The weekly limit is stored only in `personal.settings` and never pushed to workspaces.

4. **Cross-workspace writes**:
   - T7: Entering hours into workspaces A and B sends two separate `PUT /v1/me/hours` requests, each with its own `X-Spool-Tenant`.


## 4. Owner questions (not decided here)
1. **OQ-3**: Do receipts keep times of day (spans)?
   - **A**: Yes (recommended). Keeps past overlap visible.
   - **B**: No. Past workspaces count as unplaced.

2. **OQ-6**: How long to keep the approver's name in receipts?
   - **A**: Forever (recommended). Aligns with 118 D4.
   - **B**: 107 FR-34's retention years.