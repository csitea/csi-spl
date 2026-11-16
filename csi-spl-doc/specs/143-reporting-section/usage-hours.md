# Usage hours: time each person spends in each workspace (SPL-5709)

Status: **Decided v0.1.0**. Rows U-1 (store), U-2 (heartbeat API) and U-3 (report APIs) are built (SPL-5709). U-4 and U-5 (the WUI) are not. Epic SPL-4975.
Amends: [spec.md](spec.md) sections 5 and 6.1.
Topic: `2798773d-6bbf-407c-bf5d-bda3123a8857` (HUM-10, prd t1; topic owner c-002).

`<WORKSPACE>` and `<BASE_DOMAIN>` are placeholders. As in spec.md, "workspace" is the term here; "tenant" appears only in code identifiers.

## 1. The owner's words

| msg | text |
|---|---|
| `1f0b86e4` | "Measure the amount of time every user spends using each workspace." |
| `944839c2` | "In the report section, we need to add metrics for this for all of the persons. The business owner and the admin must be able to see, for each user of a workspace, how many hours he has been using the system and this particular workspace. From the spool hub, they should be able to see the total usage of the spool hub." |

c-002's answer (msg `9a6e2cc2`) set the plan: the hub did not measure this before. `member_activity` has sign-ins but almost no sign-outs, so the rows cannot be paired into sessions. So the WUI sends a heartbeat each minute while a workspace tab is visible and the person is active, and the hub sums the minutes per person, per workspace and per day. Counting starts on the day this goes live; nothing is back-filled.

This is not [spec 107](../107-hours-tracking/spec.md) hours tracking. That is a person's own timesheet, per topic, which they approve. This counter is passive, keeps one number per person, workspace and day, and nobody edits it.

## 2. What counts as a minute

- **Sent by the WUI** (row U-4) once a minute, only while all three hold:
  - the tab shows a workspace page;
  - `document.visibilityState` is `visible`;
  - the person moved the pointer, pressed a key, scrolled or touched the page in the last 5 minutes.

  A hidden tab, a minimised window and an idle screen send nothing.
- **Stamped by the hub**: the minute is the hub clock's, truncated to the minute (UTC). The person and the workspace come from the session. The request body is ignored, so a client cannot claim another person, workspace or time.
- **Counted once**: the hub adds the minute only when it is later than the last minute counted for that row. Two tabs of one workspace count it once. Two workspaces open in the same minute count it once in each workspace, but only once in the hub total. A retry is free.
- **Not counted**: an act-as session (the clone is not the person), a demo visitor and a channel guest (no `self.keys`, 403), and an anonymous request (401).
- **Days are UTC days.** A report range is whole UTC days, both ends inclusive, at most 400 days; the default is the last 30 days.

## 3. Who sees what

| reader | sees | route |
|---|---|---|
| any member | their own row: minutes in this workspace and across the hub | `GET /v1/reporting/use?human_id=<self>` |
| the workspace's `biz_owner` and `admin` | every current member: minutes here and across the hub | `GET /v1/reporting/use` |
| an `admin` of the operator workspace | the hub total: minutes, people, per day, per workspace | `GET /v1/operator/use` |

- A member who asks for the whole workspace, or for another member, gets 403 `reporting.use`. So does an act-as session of an owner or admin.
- The minutes "across the hub" of a member are a single number. They never say which other workspaces the person used.
- The workspace table is readable in the SQL tab (spec.md section 3) by the workspace's admins: a workspace-scoped, FORCE-RLS table with no secret column. The hub table is not: it has no `tenant_id`, and its only policy is the operator scope.

## 4. Store (row U-1, rdb `0289_use_minutes.sql`)

| table | key | columns | RLS |
|---|---|---|---|
| `workspace_use_minutes` | `(tenant_id, human_id, day)` | `minutes` 0..1440, `last_minute` | tenant scope + operator scope (the 0091 shape) |
| `hub_use_minutes` | `(human_id, day)` | `minutes` 0..1440, `last_minute` | operator scope only (the 0230 shape) |

- One heartbeat runs one upsert per table: `minutes + 1 ... WHERE last_minute < the new minute`.
- No change-stamp trigger, so a heartbeat never moves the channel stamps.
- **Retention**: the hub's sweep deletes rows older than 400 days (`UseRetentionDays`). That is a year back, plus a month to compare with.

## 5. API (rows U-2, U-3)

The contract is in `csi-spl-api/src/go/spool-hub-api/internal/hub/openapi.json`; the code is in `internal/hub/use_minutes.go`.

- `POST /v1/me/use-minute` returns `{counted, minute}`. `counted` is false when that minute was already counted in this workspace.
- `GET /v1/reporting/use?from=&to=[&human_id=]` returns `{from, to, minutes_here, members: [{human_id, name, minutes_here, minutes_hub}]}`. It has one row per current member; a member with no minutes reads 0.
- `GET /v1/operator/use?from=&to=` returns `{from, to, minutes, people, days: [{day, minutes, people}], workspaces: [{id, minutes, people}]}`. A minute in two workspaces counts in each workspace row, so the workspace rows may sum to more than `minutes`.

The WUI shows hours as `minutes / 60`, rounded to one decimal. Day, week and month are three ranges of the same call.

## 6. Build rows

| row | what | state |
|---|---|---|
| U-1 | store: rdb 0289, `store.UseMinutes` (Postgres + memory), retention sweep | built, SPL-5709 |
| U-2 | `POST /v1/me/use-minute` | built, SPL-5709 |
| U-3 | `GET /v1/reporting/use`, `GET /v1/operator/use` | built, SPL-5709 |
| U-4 | WUI: the heartbeat (section 2); the Reports "Usage" tab for every member (own row), the workspace's owner and admins (every member), with day / week / month | next lane |
| U-5 | WUI: the hub total on the same tab for the operator workspace's admins | next lane, with U-4 |

Tests:

- `internal/hub/use_minutes_test.go` runs on memory and on Postgres. Each test pins its red control in its comment:
  - a second tab does not double-count;
  - a member reading other members' hours is refused;
  - the hub total is read only by the operator workspace's admins.
- `internal/store/use_minutes_test.go` (Postgres): a workspace scope reads no `hub_use_minutes` row.
- The tables are also in `rls_test.go` and `crosstenant_test.go`, and their operator-scope callers are in `operator_scope_test.go`.
