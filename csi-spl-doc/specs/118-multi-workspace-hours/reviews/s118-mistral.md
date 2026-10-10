signed against cdf9136c9

---

## 1. REQ and D: agree / change / missing

| REQ/D | verdict | what |
|---|---|---|
| REQ-1 (Workspace Scope & Overlaps) | agree | |
| REQ-2 (Working-Time Limits) | agree | |
| REQ-3 (Standard Days) | agree | |
| REQ-4 (Unified Tracking UI) | agree | |
| D1 (Visibility of Double Counting) | agree | |
| D2 (Splitting Hours Across Workspaces) | agree | |
| D3 (Working-Time Limit Warnings) | agree | |
| D4 (Retaining Access After Leaving) | agree | |

---

## 2. Proposals

### 2.1 Data model: cross-workspace read under RLS

- **One query per workspace**, each with the person's own identity (HUM-*). Never a superuser or service read across workspaces.
- **Reuse spec 107's tables**: `hours_entries` and `hours_periods` stay per-workspace (tenant-scoped by RLS). The cross-workspace view is **a Personal Realm contract** (spec 119): the realm fetches the person's rows from every workspace they belong to, then unions them client-side.
- **No new table**: the realm does not store the union. The realm's `GET /v1/me/hours?realm=1` (T118-1) returns the union of the person's `hours_entries` rows from all workspaces, filtered `member_id = caller` and `state = 'approved'` (the only state the realm sees).
- **No raw minutes**: the realm never sees `hours_minutes` (107 section 1.7).
- **No workspace sees another workspace's rows**: RLS enforces `tenant_id = current_setting('app.tenant_id')` on every read.

### 2.2 Reported vs actual overlap computation (D1)

- **Algorithm**: interval union across workspaces. For each (day, member), collect every `hours_entries` row whose `target` is not `ws` (i.e., a topic, meeting, channel or DM), then merge overlapping intervals. The union's length is the **actual time**; the sum of the rows' minutes is the **reported time**. The difference is the overlap.
- **Edge cases**:
  - Open timer: not in the union (the timer is not approved).
  - Entries crossing midnight: split at midnight (107 section 1.6).
  - Time zones: each workspace's rows use the member's zone in that workspace (107 section 1.6).
  - Edits after approval: the union recomputes on every read.
- **Where it runs**: client-side, in the realm's UI (spec 119). The realm fetches the rows, then the UI merges the intervals.

### 2.3 UI of the personal view

- **Desktop**: a new **Realm Hours** tab in the realm's top bar (spec 119). Shows a **per-week grid** (Mon..Sun) with two numbers per day: **reported** (sum of all workspaces) and **actual** (union length). Overlapping hours are **highlighted** (e.g., red background). A click opens a **per-workspace breakdown** for the day.
- **Phone**: the same grid in a **Realm Hours** screen, reachable from the realm's bottom bar. The breakdown is a swipeable list.
- **Period totals**: the week's reported and actual totals, with the overlap.
- **No workspace sees the cross-workspace total**: the realm's UI is person-only.

### 2.4 Entering hours into several workspaces from one screen (REQ-4)

- **Flow**:
  1. The member opens the **Realm Hours** tab (2.3) and taps **+**.
  2. A picker shows the member's workspaces (realm contract T118-2).
  3. The member picks **one or more workspaces** (multi-select).
  4. The member picks a **target** (topic, meeting, channel, DM, or "other") from the current workspace (the realm does not know other workspaces' targets).
  5. The member sets **minutes** (stepper ±15, or type).
  6. **Save**: the realm writes one `hours_entries` row per selected workspace (same day, target, minutes, note).
- **Errors**: if one workspace refuses (e.g., frozen period, RLS), the realm rolls back all writes and shows the error (e.g., "Workspace A: period frozen").

### 2.5 Tests

| test | what |
|---|---|
| T118-1 | `GET /v1/me/hours?realm=1` returns the union of the member's approved rows from all workspaces, filtered `member_id = caller`. |
| T118-2 | The workspace picker (2.4) shows only workspaces the member belongs to. |
| T118-3 | The overlap computation (2.2) matches manual interval union for 2..5 workspaces, with overlaps, midnight splits, and time zones. |
| T118-4 | A write to multiple workspaces (2.4) succeeds only if all workspaces accept it; else rolls back. |
| T118-5 | RLS negative: a member never reads another member's or a non-member workspace's hours. |
| T118-6 | A foreman never sees the cross-workspace total (realm-only UI). |
| T118-7 | A leaver sees only their own hours (read-only receipt, D4). |

---

## 3. Boundary with spec 119 (Personal Realm)

### 3.1 What 118 needs from the realm

| contract | what |
|---|---|
| T118-1 | `GET /v1/me/hours?realm=1` returns the union of the member's approved `hours_entries` rows from all workspaces. |
| T118-2 | `GET /v1/me/workspaces` returns the member's workspaces (id, name, role). |
| T118-3 | The realm's UI shows the cross-workspace view (2.3) and the multi-workspace write flow (2.4). |

### 3.2 Contradictions with spec 107 or 119

- **None**: spec 107's RLS and tables are reused; spec 119 hosts the realm UI and contracts.

---

## 4. Owner questions

1. **Timer in the realm**: should the realm's timer (107 section 1.5) write to multiple workspaces at once, or one workspace at a time?
2. **Overlap marking**: should the UI mark overlaps per workspace (e.g., "Workspace A and B"), or just highlight the overlapping hours?
3. **Leaver receipt**: should the realm keep the leaver's hours rows (D4), or fetch them on demand from the workspaces?
4. **Standard day**: should the realm show a warning when the member's actual time exceeds the **sum** of their workspaces' standard days (REQ-3), or only per workspace?