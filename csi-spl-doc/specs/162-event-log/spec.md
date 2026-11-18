# 162 The event log: complete rows, workspace and system events, select and delete

Version v1.0 (2026-10-28): the panel's pass folded (section 8). The
panel's second seat is a mistral reviewer, read-only (owner 10-27); it
signs section 9 in its own commit.

v1.1-draft (2026-11-18): section 10 added, backend errors into the System
log (SPL-5882, owner t1 topic `bfd5af01`). Sections 1-9 are unchanged.
Section 10 waits for its own review; its build rows start after it signs.

v1.2 (2026-11-18): section 10 takes the owner's four answers to
poll `00d28227` (t1 topic `bfd5af01`, msg `4dda13ce`): Q1 B, a read-only
service account for the box reader, granted by a terraform step on the
owner's go (new row T7a); Q2 A, the post-deploy step turns red and prd
still deploys; Q3 A, every error group gets an issue; Q4 B, a backend
error of a signed-in person's request also lands in that person's Mine
log, and the group row carries the person id. Sections 1-9 are unchanged.

Source: owner HUM-10, t1 topic `cfaa3dce`. Issue SPL-4024 (this spec),
epic SPL-2403. The Monitoring tab row it lives in is spec 153. Each build
row in section 5 gets its own issue when it is placed. The build rows
follow v1.0 without a further go (owner msg `dff87755`).

Paths used below:

- `wui/` = `csi-spl-wui/src/`
- `api/` = `csi-spl-api/src/go/spool-hub-api/`
- `hub/` = `api/internal/hub/`
- `store/` = `api/internal/store/`
- `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`
- `orc/` = `csi-spl-orc/src/bash/`

Every `file:line` was read on origin/master `dd3b55565` (2026-10-28) and
read again for v1.0 on `d21788721` (section 8). No
prd count was read for this draft: the size of today's log per human is
unmeasured (section 7, R1).

## 1. The owner's asks, verbatim

Owner HUM-10, t1 topic `cfaa3dce`:

| msg | text |
|---|---|
| `ae1a43f8` / `f9632889` (10-20) | "Analyse thd Event Logs" / "What is stuff which could be improved" |
| `c7769644` | "the admins should also see events which are not personal but concerning the whole whole workspace or the whole system" |
| `6a68cb83` | "aka we need to improve the things to be logged ( ak athe events ) for example the fail over on orchestrators should be logged , even the normal rotations of dispatehrs and orchestrrators should be logged" |
| `68b3d6d2` | "there should be also an interface to filter and select the log event entries - the same way the issues can be \"mass selected\" and delete only the selected entries .." |
| `f4e43cc4` | "whenever possible an even logger should log also the orgin of the log entry - a msg , a topic , an issue , a component in the system , the time should be presented in a sortable iso-8601 format" |
| `dff87755` | "for each one of those requirements create the specs , the issues and start working , but probably first a panel of experts to evalaute the order and the scope of the implemtnation and the actual correct specs and than go to work" |

## 2. What exists on master

### 2.1 Live

- **The store.** `rdb/0045_human_events.sql`: one table, `human_events`,
  hub-wide (no `tenant_id`, outside RLS), keyed by `human_id`, `kind`
  CHECK `IN ('error')` only. Columns `error_id, occurred_at, received_at,
  source, method, origin, path, status, code, message, name, route`. The
  hub keeps the newest 500 rows per human (`store/human_events.go:18`
  `HumanEventsKeep`), trimmed on insert.
- **The routes** (`hub/events.go:82-87`): `GET /api/v1/auth/events`
  (`?limit` <= 200, `?before`), `POST /api/v1/auth/events` (<= 20 rows,
  240 writes per human per hour, `:30`), `POST /api/v1/auth/events/clear`
  (`:216-232`). Every route reads only the session's own `HUM-*`
  (`eventsHuman`, `:90-108`), so Clear deletes only the caller's rows
  (`ClearHumanEvents`, since commit `7169955fd`).
- **The page.** `wui/pages/monitoring/events/index.vue`, the Events tab
  of Monitoring (`wui/utils/monitoring-tabs.mjs:22`, commit `eb7514787`),
  for every signed-in member. Six columns (`wui/utils/event-sheet.mjs:7-14`):
  when, id, source, status, message, route. Per-column sort and filter of
  the rows the page holds (`4fe55ff33`, `d29b9feaa`). Pages of 30
  (`index.vue:206`) and Load more.

### 2.2 Not built (the seven open items)

| item | owner msg | what is missing, on master |
|---|---|---|
| E1 complete row | `ae1a43f8` | the hub answers `method, origin, path, code, name` (`hub/events.go:39-54`), but `eventRowsOf` drops them (the `EventRow` typedef, `wui/utils/event-rows.mjs:7-16`, has none of them) and the table shows none |
| E2 ask before Clear | `ae1a43f8` | `onClear` (`index.vue:326-338`) POSTs at once: one tap wipes up to 500 rows. `wui/components/UiConfirm.vue` exists and is not used here |
| E3 workspace and system events | `c7769644` | no store: `human_events` is per human and holds only `kind = 'error'` |
| E4 failover and rotation events | `6a68cb83` | a lease handover is a log line on the box (`orc/run/spl-dispatch-lease.func.sh:2165-2172`, `spl_lease_log`) and a hub log line (`hub/box_lease.go:103-106`); neither is a row anyone can read in the WUI |
| E5 select and delete selected | `68b3d6d2` | no checkbox, no per-row delete; the hub has only Clear |
| E6 origin of each entry | `f4e43cc4` | `route` holds the page the error showed on (for example `/t/<uuid>`) as text; nothing links it to the topic, message, issue or component |
| E7 sortable ISO 8601 time | `f4e43cc4` | partly: the cell shows `YYYY-MM-DD HH:MM` in the viewer's zone (`whenOf`, `index.vue:247-250`; `isoDateTime`, `wui/utils/date-iso.mjs:111-116`): no seconds, no zone. The exact UTC instant is only on hover (`utcOf`, `index.vue:251-254`) |

### 2.3 What the new events can hang on

- **The lease write.** `hub/box_lease.go:75-91`: `lease_op cas` with the
  holder the loop wants and the gen it read
  (`store/fleet_lease_postgres.go:64` `CASFleetLease`, memory twin
  `store/fleet_lease.go:80`). A won CAS whose holder differs from the
  row's previous holder is a handover. The loop knows why it moves the row
  (`orc/run/spl-dispatch-lease.func.sh:2134-2156`): no row yet (`FG == 0`),
  a same-box seat move (`spl_fleet_seat_move`, `:2219-2235`), a stale
  holder (`:2138-2144`), a handback (`:2146-2156`), a vendor switch
  (`ct != ht`, `:2167-2168`). A rotation names the id it replaces in
  `<lease dir>/rotate.hold` (`:747-767`). The far-off-limit handover
  (SPL-2892, from `:2237`) is one more.
- **The lease mirror.** The holder box copies the row into every served
  tenant (`spl_fleet_mirror_out`, from `:1158`, called at `:2181`). A
  mirror write is not a new handover.
- **The frame.** `api/internal/wire/wire.go:364-370`: the lease fields of
  the frame (`lease_op`, `fleet`, `lease_role`, ...). The CLI verb is
  `api/cmd/spool/lease.go`, its action `api/internal/action/lease.go`
  (`LeaseArgs`, `:16-22`).
- **Who is an admin.** Workspace owner or admin:
  `a.TenantOwner || a.Has(rbac.Admin)` (`hub/workspace_lanes_view.go:46`,
  the spec 153 B6 rule; its WUI twin is `monitoringStaff` in
  `wui/utils/monitoring-tabs.mjs`). System admin: an admin of the operator
  workspace, `operatorActor` (`hub/operator_workspaces.go:83`, spec 074).
  The WUI shows operator-only tabs from `useOperatorPane().visible`
  (`wui/pages/monitoring.vue:54`).
- **The Gmail-style selection.** `wui/utils/issues-bulk.ts` (pure:
  `toggleKey`, shift-click ranges) and `wui/components/IssuesBulkBar.vue`.
- **Workspace changes with a handler today**: member invite, invite
  revoke, role, roles, remove (routes `hub/rbac.go:586-590`); channel delete
  (`hub/channel_members.go:41`, handler `:542`); join token mint and
  revoke, box pin revoke (`hub/join_tokens.go:67-70`). Issue changes
  already have their own history (`rdb/0181_issue_events.sql`) and are
  not copied (3.4).

## 3. The design

### 3.1 Three logs, one page (E3)

| log | holds | stored in | who reads and deletes | kept |
|---|---|---|---|---|
| **Mine** | the errors the WUI showed me (today's rows) | `human_events` (table unchanged) | the human, own rows only | newest 500 per human (unchanged) |
| **Workspace** | what changed in this workspace: members, channels, boxes, join tokens | new `workspace_events` (tenant table, RLS) | the workspace's owner and admins | newest 5000 per tenant, trimmed on insert |
| **System** | what the hub and the fleet did: lease handovers, hub start | new `system_events` (hub-wide, no tenant) | admins of the operator workspace | newest 10000, trimmed on insert |

Two new tables, not one with a nullable tenant: a tenant table follows the
fail-closed RLS rule (`TestRLSCoversEveryTenantTable`), and a hub-wide one
sits outside RLS beside `human_events` (the 0014 list of hub-wide tables,
named in `rdb/0045_human_events.sql`). One mixed table would put the
`tenant_id IS NULL` rows behind a tenant policy that never reads them.

Both new tables share one column set:

```sql
id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
-- workspace_events only:
tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
at          timestamptz NOT NULL DEFAULT now(),        -- the hub's clock
kind        text        NOT NULL CHECK (kind ~ '^[a-z]+(\.[a-z_]+)+$' AND length(kind) <= 48),
level       text        NOT NULL DEFAULT 'info' CHECK (level IN ('info', 'warn', 'error')),
actor       text        NOT NULL DEFAULT '' CHECK (length(actor) <= 64),   -- HUM-*, <agent id>@<box>, or 'hub'
message     text        NOT NULL DEFAULT '' CHECK (length(message) <= 800),
origin_kind text        NOT NULL DEFAULT '' CHECK (origin_kind IN ('', 'msg', 'topic', 'issue', 'component')),
origin_ref  text        NOT NULL DEFAULT '' CHECK (length(origin_ref) <= 120),
CHECK ((origin_kind = '') = (origin_ref = ''))
```

Indexes: `(tenant_id, id DESC)` and `(id DESC)`. `kind` is a dotted name
checked by pattern, not a closed list, so a new producer needs no
migration; the hub's Go holds the kinds it writes (`store/log_events.go`,
one const each) and a unit test pins that list.

`message` is English text the hub builds from fixed templates plus ids. It
never carries a message body, an email address or a secret. The WUI shows
it as is (these rows replace box log lines) and translates `kind` into a
label (`events.kind.<kind>`, one key per const).

Deleting leaves a trace: a delete in the Workspace or System log writes
one new row there, `log.deleted`, actor the deleter, message "<n> rows
deleted"; that row may itself be deleted later. These are operational
logs, not an audit trail: `operator_audit` and the issue history keep
their own tables and are not deletable from this page.

### 3.2 The routes

| route | log | who | answer |
|---|---|---|---|
| `GET /api/v1/auth/events` | Mine | unchanged | unchanged |
| `POST /api/v1/auth/events/delete`, body `{"ids":[..]}` (1..200) | Mine | the session's human | `{"deleted": n}`; deletes only `human_id = caller AND event_id = ANY(ids)`. Another human's id counts 0, never 403 (no probe of whose ids exist) |
| `POST /api/v1/auth/events/clear` | Mine | unchanged | unchanged |
| `GET /v1/view/events?limit=&before=` | Workspace | owner or admin of the session's workspace, else 403 `workspace.events` | `{"events":[..], "next_before": id}`: `id, at, kind, level, actor, message, origin_kind, origin_ref` |
| `POST /v1/view/events/delete`, body `{"ids":[..]}` | Workspace | the same | `{"deleted": n}`, plus the `log.deleted` row |
| `GET /v1/operator/events?limit=&before=` | System | `operatorActor`, else 403 `operator.workspaces` | as Workspace |
| `POST /v1/operator/events/delete`, body `{"ids":[..]}` | System | `operatorActor` | as Workspace |

No delete-all route for Workspace and System: Clear stays a Mine-only
verb. Selecting a whole page and deleting it takes two clicks (3.5).

### 3.3 Failover and rotation are system events (E4)

The hub writes one `system_events` row on a won `lease_op cas` that
changes the holder, when the frame names a reason. The loop names it; the
hub never guesses the reason from ages.

- **Wire.** One new optional frame field, `lease_reason`, one of `claim,
  rotation, seat_move, failover, handback, vendor, limit`. The hub's
  strict frame parser accepts it once B4 is served; an old CLI that sends
  none still works and logs nothing.
- **CLI.** `spool lease ... --reason <r>` sends it (`LeaseArgs.Reason`).
- **Hub.** In `boxLease` (`hub/box_lease.go:75-106`): when `won`,
  `lease_reason != ""` and the previous holder differs from the new one,
  one row: `kind = lease.<reason>`; `level = warn` for `failover` and
  `limit`, else `info`; `actor` = the new holder; `message = "<role>: <old
  holder> -> <new holder> (<reason>, silent <age>s)"`; `origin_kind =
  component`, `origin_ref = lease/<fleet>/<role>`. `CASFleetLease` must
  answer the previous holder and its age (today it answers the new row
  only).
- **Mirror.** `spl_fleet_mirror_out` sends no reason, so its copies into
  served tenants log nothing: one handover, one row.
- **Loop** (`orc/run/spl-dispatch-lease.func.sh`, the write at `:2163`):
  the reason is the branch that set `want`: `FG == 0` -> `claim`; the
  previous holder's id named in a live `rotate.hold` -> `rotation`;
  `spl_fleet_seat_move` on the same box and tier -> `seat_move`; the stale
  branch -> `failover`; `handback=true` -> `handback`; `ct != ht` ->
  `vendor`; the SPL-2892 far-off-limit write -> `limit`. One helper,
  `spl_fleet_reason`, with a table test.
- **Hub start.** `hub.started`, actor `hub`, message
  `<version> rev <revision> instance <id8>` (SPL-5764): the version (the
  same source `/version` reads), Cloud Run's `$K_REVISION` (else a
  per-process id) and 8 hex new on every process start. Written once per
  process start: each deploy roll shows in the System log, its rows share
  the rev and differ in the instance (Cloud Run starts a second one), and a
  start whose rev did not change (a crash restart) stands out.

The owner DM on an orchestrator failover (`:2169-2172`) stays as it is.

### 3.4 Workspace producers (E3, first set)

One `AddWorkspaceEvent` call in each handler, after its store write
succeeded. The write is best effort: a failed log write is logged and the
action stands, as `opAudit` does (`hub/operator_workspaces.go:115-116`).

| kind | handler | origin |
|---|---|---|
| `member.invited`, `member.invite_revoked` | `handleMemberInvite` (`hub/rbac.go`), `handleInviteRevoke` (`hub/members_admin.go`); routes `hub/rbac.go:586-587` | component `members` |
| `member.role_changed` | `handleMemberRole`, `handleMemberRoles` (routes `:588-589`) | component `members` |
| `member.removed` | `handleMemberRemove` (route `:590`) | component `members` |
| `channel.deleted` | `handleDeleteChannel` (`hub/channel_members.go:542`) | component `channels/<name>` |
| `box.join_token_minted`, `box.join_token_revoked`, `box.pin_revoked` | `hub/join_tokens.go:67-70` | component `boxes` |

Not copied: issue changes (their History tab, rdb 0181) and messages
(they are the topics). More producers are later rows, one call plus its
test each; this spec adds none beyond this set.

### 3.5 The page (E1, E2, E5, E6, E7)

- **Scope switch.** A segmented control above the table: Mine |
  Workspace | System. Workspace shows for `monitoringStaff(me)`, System for
  `useOperatorPane().visible`; with neither, no switch (today's page). The
  choice is in the URL (`?log=workspace|system`, default Mine), so a link
  opens the same log; a reader not allowed that log falls back to Mine.
  The hub's 403 is the real gate.
- **Columns** (E1, E6, E7). Mine: when, id, source, status, request
  (`METHOD path`), code (code, then name on a second line), message,
  origin. Workspace and System: when, kind, level, actor, message, origin.
- **When** shows `YYYY-MM-DD HH:MM:SS±HH:MM` in the viewer's zone (a new
  `isoDateTimeOffset` in `wui/utils/date-iso.mjs`): ISO 8601 with seconds
  and the offset, so it sorts as text for one viewer and is never
  ambiguous. The hover keeps the UTC instant with `Z`. This keeps the
  owner's earlier rule "stored UTC, shown in the person's own zone"
  (CLE-77908, `index.vue:244-246`).
- **Origin** (E6). A link when it resolves: `topic` -> `/t/<uuid>`;
  `issue` -> `/issues/<KEY>`; `msg` -> its topic with the message
  focused, only when the topic is known, else plain text; `component` ->
  plain text. For Mine the origin is derived in the WUI from `route`
  (`/t/<uuid>` -> topic, `/issues/<KEY>` -> issue, else component =
  `source`); `human_events` gets no new column.
- **Select** (E5). A checkbox per row and a page checkbox, Gmail-style,
  importing `toggleKey` and the shift-click range from
  `wui/utils/issues-bulk.ts` (not copying them). With one row or more
  checked, a bar takes the place of the head actions: the count, Delete
  selected, Clear selection. The selection holds row ids, survives sort
  and filter, and drops ids the table no longer holds after a refresh.
- **Delete selected** asks first (UiConfirm): "Delete <n> entries? This
  cannot be undone." One call per 200 ids; the rows leave on the answer;
  a failure is a sentence and the rows stay.
- **Clear log** (E2, Mine only) asks first too: "Delete all entries of
  your log?", naming the count shown and, when `next_before` says older
  rows exist, that those go too.
- **A transport drop says why** (F5, SPL-5745; topic 955ab0bd). A request
  that got no answer (`TypeError`, no status) is recorded with the
  browser's `navigator.onLine`, `document.visibilityState` and the ms
  since the tab last woke or came online, and a code:
  `net.offline` (no network), `net.resumed` (the tab was hidden, or woke
  or came online <= 10 s before) or `net.unreachable` (online and awake:
  the hub did not answer). A drop of another class is its own record.
  Mine marks a `net.offline` / `net.resumed` row **Network** and reads it
  muted: the network went away, the screen did not fail. A
  `net.unreachable` row stays an error row. Only the code reaches the hub
  (`human_events.code`); the three readings stay in the tab's journal.
- Every new string is a translation key in every locale; the last step of
  each WUI row is an agy review of its text (the language rule).

## 4. Cases

Each case names the test that holds it. Each build row's red control is
planted as written and seen RED, then GREEN, both outputs in the commit
body.

| case | expect | test |
|---|---|---|
| C1 | a row with method `POST`, path `/v1/x`, code `bad_request`, name `TypeError` shows all four (desktop columns, phone card labels) | `csi-spl-wui/tests/unit/event-rows.test.mjs` (fields kept); `tests/e2e/events-monitoring-tab.test.mjs` |
| C2 | red control for C1: `eventRowsOf` without `method` fails the unit case | same unit test |
| C3 | When reads `2026-07-28 12:14:03+03:00` for `2026-07-28T09:14:03Z` and `2026-10-28 11:14:03+02:00` for `2026-10-28T09:14:03Z` in Europe/Helsinki; the hover reads the `Z` instant | `tests/unit/date-iso.test.mjs` (new cases), the e2e above |
| C4 | sorting When by cell text equals sorting by instant for 20 random rows of one viewer | `tests/unit/event-sheet.test.mjs` |
| C5 | Clear log opens the confirm; Cancel keeps every row and sends no POST; OK clears | `tests/e2e/events-clear-log-mobile.test.mjs` and the desktop e2e |
| C6 | red control for C5: an `onClear` that skips the confirm fails C5 (a POST is seen before OK) | same |
| C7 | `POST /api/v1/auth/events/delete` with 3 own ids and 2 of another human answers `deleted: 3`; the other human's rows stay | `hub/events_test.go`; `store/human_events_test.go` on memory and Postgres |
| C8 | red control for C7: a store delete without the `human_id` clause deletes the other human's 2 rows | same |
| C9 | 0 or 201 ids -> 400; a non-integer id -> 400; signed out -> 401 | `hub/events_test.go` |
| C10 | a `workspace_events` row of tenant A is not read in tenant B's scope, nor with no tenant set | `store/rls_test.go` (the table list) and a new Postgres case in `store/log_events_test.go` |
| C11 | red control for C10: the policy without `NULLIF` reads rows with no tenant set | the `rls_failclosed_test.go` pattern |
| C12 | `GET /v1/view/events`: owner 200, admin 200, member 403 `workspace.events`; another workspace's admin sees none of A's rows | `hub/log_events_test.go` |
| C13 | `GET /v1/operator/events`: operator workspace admin 200; its biz_owner 403; an admin of another workspace 403 | same |
| C14 | delete selected on Workspace removes the named rows and writes one `log.deleted` row, actor the caller, message "2 rows deleted" | same |
| C15 | the 5001st workspace row trims the oldest of that tenant only; the 10001st system row the same | `store/log_events_test.go` |
| C16 | a won CAS with `lease_reason: failover` and a new holder writes one `lease.failover` row, level warn, the message naming old and new holder and the age | `hub/box_lease_test.go` |
| C17 | red control for C16: the same CAS lost (gen moved) writes no row; a renew by the same holder writes none; a CAS with no reason (the mirror) writes none | same |
| C18 | a frame without `lease_reason` is still accepted (no 400) | same |
| C19 | `spool lease --reason bogus` exits non-zero naming the list; `--reason rotation` puts `lease_reason` in the frame | new `api/internal/action/lease_test.go`; `api/cmd/spool/cli_verbs_test.go` |
| C20 | `spl_fleet_reason` returns each of the seven reasons for its branch inputs; `rotation` only while `rotate.hold` names the previous holder and is younger than `ROTATE_HOLD_MAX` | new `orc/tests/spl-fleet-reason.tst.sh` |
| C21 | red control for C20: a `rotate.hold` naming another id gives `seat_move`, not `rotation` | same |
| C22 | each producer of 3.4 writes its one row after a successful call, none after a refused one (403, 404) | one case per handler in its `_test.go` |
| C23 | a failed log write does not fail the member, channel or box action (the store stub errs; the action answers its usual 2xx) | same |
| C24 | Mine: check 3 rows, shift-click a row 5 below the third -> 8 checked; Delete selected -> confirm -> those 8 leave, the rest stay | new cases in `tests/e2e/events-monitoring-tab.test.mjs` |
| C25 | red control for C24: a Delete selected that sends the page's ids instead of the selection removes unchecked rows | same |
| C26 | the scope switch shows Workspace to an owner or admin only, System to an operator workspace admin only, neither to a plain member; `?log=system` for a plain member falls back to Mine | new `tests/unit/event-log-scope.test.mjs`, the e2e |
| C27 | origin: route `/t/<uuid>` -> topic link; `/issues/SPL-12` -> issue link; `/settings` -> plain component text | new `tests/unit/event-origin.test.mjs` |

## 5. Build rows

One small lane each; rows that may run at once have disjoint files.
`<next>` migration numbers are taken at build time, after the last rebase
(whoever lands first keeps the number).

| row | items | area | files (only these) | after | cases |
|---|---|---|---|---|---|
| B1 complete row, time, ask before Clear; Implemented `69dec558e`, `e2ea3ea44`, `237efd555` (SPL-4165) | E1, E2, E7 | wui | `wui/utils/event-rows.mjs`; `wui/utils/event-sheet.mjs` (columns request, code); `wui/utils/date-iso.mjs` (new `isoDateTimeOffset` only); `wui/pages/monitoring/events/index.vue`; `csi-spl-wui/i18n/locales/*.json` (new keys only, agy review last); `tests/unit/event-rows.test.mjs`, `event-sheet.test.mjs`, `date-iso.test.mjs`; `tests/e2e/events-monitoring-tab.test.mjs`, `events-clear-log-mobile.test.mjs` | - | C1-C6 (red C2, C6) |
| B2 personal delete selected (hub) | E5 | api | `hub/events.go` (the new route only), `hub/events_test.go`; `store/human_events.go` (new `DeleteHumanEvents` on the interface), `human_events_memory.go`, `human_events_postgres.go`, `human_events_test.go`; `hub/openapi.json` (the path) | - | C7-C9 (red C8); `PRE_PUSH_TIER=full`; **landed `addced4d5`** (2026-10-29, dev + prd v6.5.0-c3) |
| B3 workspace and system store, routes | E3 | rdb, api | new `rdb/<next>_workspace_system_events.sql` (both tables; RLS for the tenant one); new `store/log_events.go`, `log_events_memory.go`, `log_events_postgres.go`, `log_events_test.go`; `store/rls_test.go` (the table list only); new `hub/log_events.go` + `_test.go`; one route line in `hub/server.go`; `hub/openapi.json` (the four paths) | - | C10-C15 (red C11); `PRE_PUSH_TIER=full`; **landed `3820b482c`** (2026-10-29, dev + prd v6.5.1-c3, rdb `0240_workspace_system_events.sql`) |
| B4 lease reason on the wire; the hub writes it | E4 | api | `api/internal/wire/wire.go` (the frame field); `api/internal/action/lease.go` + new `lease_test.go`; `api/cmd/spool/lease.go` (the flag) + `cli_verbs_test.go`; `hub/box_lease.go` + `box_lease_test.go`; `store/fleet_lease.go`, `fleet_lease_postgres.go`, `fleet_lease_test.go` (CAS answers the previous holder and age); the `hub.started` write in the hub's start path | B3 on master | C16-C19 (red C17); `PRE_PUSH_TIER=full`; **landed `6e799033c`** (2026-10-30, dev + prd v6.6.7-c3; a claim on an empty lease reads `<role>: none -> <new> (claim)`) |
| B5 the loop names the reason | E4 | orc | `orc/run/spl-dispatch-lease.func.sh` (new `spl_fleet_reason`; `--reason` on the write at `:2163` and on the SPL-2892 write; nothing on `spl_fleet_mirror_out`); new `orc/tests/spl-fleet-reason.tst.sh` | B4 served on dev and prd AND the `spool` binary on every box carries `--reason` (R2) | C20-C21 (red C21) |
| B6 workspace producers | E3 | api | `hub/rbac.go` (the five handlers of 3.4, one call each; `handleInviteRevoke` lives in `hub/members_admin.go`, its route line in `rbac.go`), `hub/channel_members.go` (`handleDeleteChannel`), `hub/join_tokens.go` (three handlers), and their `_test.go` cases | B3 on master | C22-C23 (red: C22's refused-call case with the write moved before the check); **landed `8b36185cb`** (2026-10-30, dev + prd v6.7.0-c3) |
| B7 select and delete selected (page, Mine); Implemented `0eab294c8`, `ccbe3dfd4` (SPL-4216) | E5 | wui | `wui/pages/monitoring/events/index.vue`; new `wui/components/EventsBulkBar.vue`; the events client's `delete` in `wui/utils/event-log.mjs`; locale keys (new only, agy review last); `tests/unit/event-log.test.mjs`; the C24 e2e cases | B1 and B2 on master | C24-C25 (red C25) |
| B8 scope switch and origin | E3, E6 | wui | `wui/pages/monitoring/events/index.vue`; new `wui/utils/event-log-scope.mjs`, new `wui/utils/event-origin.mjs` + their unit tests; the two view-log calls in `wui/utils/spool-client-lazy.mjs`; locale keys (new only, `events.kind.*` included, agy review last); the C26 e2e | B3, B6 and B7 on master | C26-C27 (red: an origin parser that links `/settings`) |

Order:

1. B1, B2 and B3 at once (the page; `hub/events.go` + `store/human_events*`;
   new files plus one `server.go` line: disjoint).
2. After B3: B4 and B6 (`box_lease.go` + the store's fleet lease vs
   `rbac.go`, `channel_members.go`, `join_tokens.go`: disjoint). After B1
   and B2: B7.
3. B5 after B4 is served and the CLI is on every box; B8 last.

B1, B7 and B8 all edit `index.vue` and the locale files: they land one
after the other, never at once.

## 6. Panel decisions

Settled at v1.0: the reviewer accepted all six, none overturned.

- D1 Two tables (workspace, system), not one with a nullable tenant (3.1).
- D2 No delete-all for Workspace and System; a `log.deleted` trace row.
- D3 The loop names the lease reason; the hub never infers it from ages.
- D4 When shows the viewer's zone with its offset, not UTC (keeps
  CLE-77908 and meets "sortable ISO 8601").
- D5 Mine's origin is derived from `route` in the WUI, no new column.
- D6 Retention by count (500 / 5000 / 10000), trimmed on insert, no time
  sweep.

## 7. Risks and open checks

- R1 The size of today's `human_events` on prd is unmeasured; the B2 lane
  reads `count(*)` and the largest per-human count before it lands (an
  observation, not a gate).
- R2 B5 depends on the box CLI rollout: an old `spool` refuses the unknown
  `--reason` flag and every CAS of the loop would fail. The B5 lane runs
  `spool lease --help 2>&1 | grep -c -- --reason` on every box before it
  pushes; any 0 and it waits.
- R3 `system_events` grows with every hub start: at tens of rolls a day,
  the 10000 cap holds months of starts alongside the handovers.

## 8. Panel record

The reviewer: m-513 (mistral, read-only). Findings on topic
`dispatch-cfaa3dce`. The first pass (msg `443a2526`) had no commands and
contradicted itself. The dispatch holder c-002@sat sent it back for
evidence (msg `93ccd775`). The second pass, msg `b3280c6b`, is the one
weighed below.

| finding | the reviewer said | the editor's check | folded |
|---|---|---|---|
| file:line claims | 16 checked: 7 MATCH, 9 WRONG | Every WRONG row's "correction" restates the spec's own claim; none names a different line or behaviour. The editor read each one again on `d21788721`, for example `git show origin/master:<api>/internal/hub/events.go \| sed -n 82,87p` -> the three `HandleFunc` lines with `eventsPrefix`; `RoutePrefix = "/api/v1/auth/"` (`internal/auth/handler.go:26`). | no change |
| `event-rows.mjs` typedef | MATCH at `:7-17` | `grep -n typedef\|EventRow` -> `:7` and `:16`; line 17 is the comment's close | `:7-16` (2.2, E1) |
| the loop, `spl-dispatch-lease.func.sh:2130-2235` | MATCH; output "`spl_fleet_reason` logic" | `git grep -c spl_fleet_reason origin/master -- csi-spl-orc` -> 0 hits: that helper is new in B5, so the quoted output is not from the tree. The editor checked the lines: the branches `:2134-2156`, the write `:2163`, the log lines `:2165-2172`, `spl_fleet_seat_move` `:2219`, SPL-2892 `:2237`, `spl_fleet_mirror_out` `:1158`, its call `:2181`: all as the spec says | no change |
| the tree named | `dd3b55565c8d8f5e5a5a5a…` | `git rev-parse dd3b55565` -> `dd3b55565222d8615faed5cc21099e554a036c2f`: the long sha quoted is not a real object; the short one is the spec's | none |
| B1..B8 order | buildable as B1, B2, B3, B4, B6, B5, B7, B8; no row needs a later one | agrees with section 5's order | no change |
| overlap | B1, B7, B8 share `index.vue` and the locale files: land one after the other | section 5 already says so | no change |
| D1..D6 | all ACCEPT; D6 "may need revisiting if storage growth becomes a concern" | R3 already tracks it | section 6 |

What the pass did not do: it checked 16 of the spec's references, not
every one, and quoted no full command output. The editor's own re-read
on `d21788721` covered the ones the spec builds on (2.1, 2.2, 2.3 lease
and loop lines). No row of section 5 changed.

## 9. Signatures

- Editor: c-390 (claude), the v1.0 commit.
- Reviewer: m-513 (mistral, read-only): signed v1.0 (1da9cb478).
- Section 10 v1.2: editor c-818 (claude), landed e7ff0e347; reviewer
  m-566 (mistral, read-only), PASS on fd25054cb with no defect (seat
  file 1ffd9abb9).

## 10. Backend errors into the System log (v1.2, SPL-5882)

### 10.1 The owner's asks, and why this spec holds them

Owner HUM-10, t1 topic `bfd5af01` (#spool-hub-ops), 2026-11-18:

| msg | text |
|---|---|
| `0b7c9534` | "we need a mechanism how-to trap errors from the backend, collect and report them. Now the events are trapping errors from the wui mostly : https://spool-hub.ai/monitoring/events , we need a system how-to get them from the STDERR of the container or from the CloudRun and put them into the same EventLog" |
| `58c65b39` | "so that the bug fix lanes could be used to scan those entries ,create issues and start work on them ..." |
| `f6b251db` | "the goal will be to have as errorless and bugless e2e implmentation as posible" |
| `d0e0085f` | "we should be much more like google and much less like microsoft in this regard" |
| `e05d9c00` | "for the hub owns panics / cloud run crashes - the component must be running on the sat box , but should bedone so that it could be running in the [main] box as well" (the second box name replaced: distribution hygiene) |
| `6ddfaa91` | "I guess it could be cron scheduled and run every hour or something ..." |
| `4dda13ce` | the answers to poll `00d28227` (14:52Z): "Answer 1: B — A new read-only service account, granted by a terraform step on your go, plus one more key per env / Answer 2: A — The step turns red and says so; prd still deploys / Answer 3: A — Every error group / Answer 4: B — Also in the Mine log of the person whose request failed" |

The dispatcher's plan in the topic, msg `a6609004` (c-002, 10:35Z): a new
section of spec 162; the hub writes its own 5xx and panics as system events;
a reader takes what the hub cannot see from Cloud Logging; one row per
fingerprint with a count; the bug round planner reads new groups as one more
source. This section follows that plan. It differs in one place: the plan
says the reader "needs a terraform step (a log sink and its permission)".
It needs no sink (10.4.3): the reader queries the bucket the hub's lines
already reach. It does need its permission: the owner chose Q1 B, a new
read-only service account granted by a terraform step on the owner's go
(row T7a, 10.10), not the per-env project service account v1.1 proposed.

Why a section of 162 and not a new spec: the rows go into 162's
`system_events` table (3.1), they are read and deleted through 162's routes
(3.2) and shown on 162's page (3.5, the System scope); a person's copy goes
into 162's Mine log (`human_events`, Q4 B). The new parts are a producer, a
reader, a service account and new columns; none of them is a new log.

Every `file:line` below was read on origin/master `04ca1d897`
(2026-11-18); for v1.2 the ones in `hub/server.go`, `hub/events.go`,
`store/human_events.go`, `auth/handler.go` and `gcp-account-pin.func.sh`
were read again on `bc559b2f6`. Nothing was measured on dev or prd for this draft: today's
5xx rate, panic rate and the exact Cloud Run log strings are unread
(10.11, R5 and R6). Paths use the aliases at the top of this spec.

### 10.2 What exists on master

- **The 5xx and panic path.** `hub/server.go:888-911` (`middleware`):
  every request runs under a `recover()`; a panic before any header is
  answered 500 `internal` through `writeErrCause`. A status >= 500 or a
  panic calls `logServerError` (`:917-935`): one ERROR line with
  `request_id`, `method`, `route` (the mux pattern, `r.Pattern`), `path`,
  `status`, and the cause `writeErr` noted (`token`, `detail`, `site` =
  the handler's file:line, `err`), message `http 5xx` or `handler panic`.
  The cause is put on the `statusWriter` (`:871-879`) by `noteCause`
  (`:834`), from `writeErr` (`:815`) and `writeErrCause` (`:824`). No body,
  query string or header is logged (Constitution VII, the comment at
  `:913-916`).
- **The loop panics.** `hub/supervise.go:39-64`: each background loop
  (`cmd/spool/hub.go:144-149`, `:156-159`, `:355`) runs under
  `runOnce`'s `recover()` (`:68-76`); a panic writes one ERROR line
  `hub loop panicked; restarting` (`LoopPanicMsg`, `:25`) with the loop
  name, panic value and stack (`:52-53`), and the loop restarts.
- **Other ERROR lines.** `s.o.Log.Error()` is called at 493 sites in
  `hub/*.go` outside the tests (`grep -n "Log.Error()" internal/hub/*.go |
  grep -v _test | wc -l` -> 493).
- **Where the lines go.** `internal/logging/logging.go:31-42`: JSON to
  stderr when deployed; `severityWriter` (`:48-79`) puts Cloud Logging's
  `severity` on each line (SPL-4473), so an ERROR line is
  `severity=ERROR` in Cloud Logging. cnf `hub.log_bucket: _Default`
  (`csi-spl-cnf/csi-spl/all.env.yaml:401`); spec 169 T13c read the hub's
  `requests` and `stderr` lines in that bucket on dev (30 days kept,
  2026-11-07; prd not read).
- **None of it is a row.** Of the System log's kinds
  (`store/log_events.go:32-54`) the hub writes `hub.started`
  (`hub/box_lease.go:169-180`, called at `cmd/spool/hub.go:142`) and
  `lease.*` (`logLeaseHandover`, `hub/box_lease.go:144`). No error kind.
  A crash, an out-of-memory kill, a failed start and a Cloud Run answer
  that never reached the hub are only in Cloud Logging, and nothing reads
  them back.
- **The System log has no page yet.** The routes are live
  (`hub/log_events.go:49-53`, row B3), the WUI scope switch is row B8,
  not built (`git grep -n "operator/events" origin/master --
  csi-spl-wui/src` -> 0 lines).
- **Box frames.** A box talks to the hub in frames; `hub/ws.go:183`
  dispatches `wire.TLease` to `onLease` (`hub/box_lease.go:49-67`), which
  pairs the reply by `msg_id` and reads the tenant from the session, never
  from the frame. The new reader frame (10.4.4) has that shape.
- **The read permission.** The per-env project service account has
  `roles/owner` on its project (gcp-003,
  `csi-spl-iac/src/bash/run/gcp-003-configure-proj-sa-permissions.func.sh:34`),
  which holds `logging.logEntries.list`; the owner chose not to use it for
  the reader (Q1 B): a reader that runs hourly on a box holds a key that can
  only read logs. No such service account exists today: no terraform step
  numbered `071` or named for logs reading (`git ls-tree --name-only
  origin/master csi-spl-iac/src/terraform/` lists `070-gcp-monitoring`,
  then `120-github-general-secrets`). The hub's runtime SA
  (`csi-spl-iac/src/terraform/030-cloud-run-hub/03-runtime-sa.tf`) has no
  logging read, and needs none: the hub never reads its own logs.
- **The key helpers.** `do_gcp_sa_key_file` honours `GCP_SA_KEY_FILE`
  (`csi-spl-orc/lib/bash/funcs/gcp-account-pin.func.sh:106-111`), and
  `do_gcp_pin_account` (`:251`) activates that key's `client_email` in a
  throwaway `CLOUDSDK_CONFIG`. `do_gcp_sa_key_rotate`
  (`csi-spl-iac/src/bash/run/gcp-sa-key-rotate.func.sh`) mints, proves and
  retires the per-env project SA key, out of band of terraform, written
  only to `$HOME/.gcp/.<org>/` (mode 600).
- **The Mine log.** `human_events` (`rdb/0045_human_events.sql`): one row
  per error a person saw, `human_id` NOT NULL, `kind` `error`, `source`
  <= 80, `origin` <= 120, `code` <= 120, `message` <= 800; newest 500 per
  person (`store/human_events.go:18`). Rows come only from the WUI today
  (`POST /api/v1/auth/events`); the WUI's journal already records a failed
  API call it made as `source: 'api'` with its status
  (`wui/composables/errorJournal.mjs:340-391`), without the hub's cause.
  The hub writes no row there itself.
- **Who made the request.** `auth.Handler.SessionFromRequest`
  (`auth/handler.go:1614-1631`) opens the signed session cookie, then asks
  `revoked.dead`, which may read the store. `eventsHuman`
  (`hub/events.go:93-100`) reads the person that way. The middleware
  (`hub/server.go:888-911`) reads no session.

### 10.3 Error classes and their two sources

| kind | class | source | written by |
|---|---|---|---|
| `error.http_server` | the hub answered a 5xx (a handler's `writeErr` / `writeErrCause` with status >= 500) | (a) in-process | `logServerError` |
| `error.panic` | a request handler panicked; the middleware recovered it | (a) | `logServerError` (`rec != nil`) |
| `error.loop_panic` | a supervised loop panicked and restarted | (a) | `supervise` |
| `error.log` | any other ERROR-level line of the hub | (a) | a zerolog hook (10.4.2) |
| `error.go_fatal` | an unrecovered panic or `fatal error:` (a goroutine outside any `recover()`): the process died | (b) out-of-process | the box reader |
| `error.cloudrun_oom` | Cloud Run killed the container over its memory limit | (b) | the box reader |
| `error.cloudrun_crash` | the container exited or was killed on a signal (not a scale-down) | (b) | the box reader |
| `error.cloudrun_start` | a revision failed its startup probe or never became ready | (b) | the box reader |
| `error.cloudrun_request` | Cloud Run answered 5xx for a request the hub never logged (no instance, timeout, overload) | (b) | the box reader |
| `error.cloudlog_other` | any other line at `severity>=ERROR` of the hub's service that no rule above takes | (b) | the box reader |
| `evlog.overflow` | more groups in one flush or one read than the cap (10.4.5); the row counts the groups dropped | (a), (b) | either |

Every kind matches rdb 0240's `kind` CHECK (`^[a-z]+(\.[a-z_]+)+$`; a
digit is not allowed, hence `error.http_server`, not `http_5xx`) and is one
const in `store/log_events.go` (`LogEventKinds`, pinned by
`TestLogEventKinds`). Level: `error` for every `error.*` kind, `warn` for
`evlog.overflow`. Actor: `hub` for (a); `cloud-logging` for (b).

Source (a) is what the hub sees itself: it writes those rows at the moment
they happen. Source (b) is what dies with the process or never reaches it:
only Cloud Logging has it, and the box reader takes it from there.

### 10.4 The design

#### 10.4.1 One pure package for both sources

New `api/internal/evlog/` (pure Go, no store, no HTTP), used by the hub and
by the `spool` CLI, so the box and the hub group and redact in one way:

- `Redact(s string) string`: the redaction rule of 10.6.
- `Normalize(s string) string`: after `Redact`, replaces each UUID with
  `<uuid>`, `HUM-<digits>` with `HUM-<n>`, `<agent letter>-<3 digits>` with
  `<agent>`, each run of 8+ hex digits with `<hex>`, each other number with
  `<n>`, each double- or single-quoted string with `<s>`; collapses blanks;
  cuts to 800 runes (rdb 0240's `message` cap).
- `TopFrame(stack string) string`: the first function of this module
  (`github.com/csitea/csi-spl/`) in a Go stack, without file or line, so a
  release that moves lines does not split one error into two groups.
- `Fingerprint(kind, msg, anchor string) string`: the first 16 hex of
  sha256(`kind` NUL `Normalize(msg)` NUL `anchor`). The anchor is the mux
  pattern for `error.http_server` (plus the `token`), `TopFrame` for a
  panic, the loop name for `error.loop_panic`, the calling function for
  `error.log`, and the class's fixed name for the Cloud Run kinds.
- `Classify(entry) (Group, bool)`: one Cloud Logging entry (the JSON of
  `gcloud logging read --format=json`) to a group, by the rules of 10.4.4;
  `false` = not an error, or written by the hub itself.
- `Group{Kind, Level, Message, Fingerprint, FirstAt, LastAt, N}` and
  `Groups`, a bounded map that adds a sighting (`N++`, `LastAt`) or opens a
  group, with the cap of 10.4.5.

#### 10.4.2 Source (a): the hub writes its own errors

- **5xx and handler panics.** In `logServerError` (`hub/server.go:917`),
  after the ERROR line: one sighting into the server's `Groups`. 5xx:
  kind `error.http_server`, message
  `<status> <token> at <site>: <err>` (the `err` text through `Normalize`),
  anchor `<route> <token>`. Panic: kind `error.panic`, message
  `panic: <value>` (`Normalize`), anchor `TopFrame` of
  `debug.Stack()` taken in the middleware's deferred func (`:897`), before
  the stack unwinds further.
- **Loop panics.** `supervise` (`hub/supervise.go:52`) has the panic value
  and stack: one sighting, kind `error.loop_panic`, anchor the loop name.
  How `supervise` reaches the server's `Groups` (a parameter of
  `Supervise`, or a field the server sets) is the build lane's choice; C31
  holds the behaviour.
- **Every other ERROR line.** A zerolog hook on the hub's logger
  (`Logger.Hook`, added where `cmd/spool/hub.go` builds `log`) takes every
  line at level >= error whose message is not one of the messages written
  above (`http 5xx`, `handler panic`, `LoopPanicMsg`, `EvlogUnwrittenMsg`):
  kind `error.log`, message the line's message (a hook sees the message,
  not the fields), anchor the calling function (`runtime.Caller` at the
  depth the test pins, C32).
- **The write is batched.** A sighting is an in-memory add under a mutex,
  never a database call on the request path. A supervised loop,
  `evlog-flush`, writes every group touched since the last flush every 30 s
  (cnf `hub.evlog.flush_s`, default 30) and at shutdown: one upsert per
  group (10.5), `N` = the sightings since the last flush. A storm of 10 000
  identical 5xx in 30 s is one upsert.
- **When the write fails** (the database is down, which is when 5xx storm):
  one ERROR line per group, message `EvlogUnwrittenMsg` =
  `event log write failed`, fields `fp`, `kind`, `n`, `first_at`,
  `last_at`, `message`. The groups are then dropped from memory. The box
  reader takes those lines (10.4.4 rule 1), so the counts reach the table
  an hour later instead of being lost. The hook skips this message, so it
  never loops.
- **Trace on the lines.** The middleware adds Cloud Logging's
  `logging.googleapis.com/trace` field (from the `X-Cloud-Trace-Context`
  header and the project id) to its `http` access line (`:906-907`) and to
  `logServerError`'s line. The reader uses it to tell a Cloud Run 5xx from
  the hub's own (rule 4).
- **Lost on a crash.** Sightings not yet flushed die with the process: up to
  30 s of counts. The crash itself is still a row, from source (b).
- **The person (Q4 B).** On a 5xx or a handler panic, `logServerError`
  takes the person from the request's session cookie through a new
  `auth.Handler.HumanFromCookie(r) string`: the signature and expiry check
  of `SessionFromRequest` without the revocation read, so the error path
  never reads the store (a 5xx storm is often a database storm). A request
  with no cookie, a bad one, or a session with no `HUM-*` (a box, a public
  route, the CLI with a box token) has no person. A revoked session's
  person still made the request, so it is still named. Only the request
  kinds have a person (`error.http_server`, `error.panic`); a loop panic,
  an `error.log` line and every source (b) kind have none: Cloud Logging
  lines carry no person, and the reader never reads a header (10.6).
- **The person's group row.** The sighting carries the person; the
  group keeps the last one (`human_id`, 10.5) and the flush writes it.
- **The Mine copy (Q4 B).** The flush also writes, per (person,
  fingerprint) touched since the last flush, one row into that person's
  Mine log through `AddHumanEvents` (`store/human_events.go`): `source`
  `hub`, `method`, `route` (the mux pattern), `status`, `code` = the
  token (or `panic`), `message` = the group's message (already through
  `Redact` and `Normalize`), plus ` (x<n>)` when the person hit it more
  than once in that flush, `origin` = `evlog:<fingerprint>`, `error_id`
  empty, `occurred_at` = the person's first sighting in that flush. A
  person who hits one broken route 100 times in 30 s gets one Mine row,
  not 100. Cap: at most 1000 (person, fingerprint) pairs between two
  flushes, past that counted into the same `evlog.overflow` row; at most
  20 Mine rows per person per flush, the rest folded into the 20th as
  ` (+<k> more)`. The Mine log keeps its 500-row trim. A failed Mine
  write is one ERROR line `EvlogUnwrittenMsg` with `human_id` dropped (the
  reader's rule 1 rebuilds the group, not the Mine row: a Mine row lost in
  a database outage stays lost, R8). The WUI's own `source: 'api'` row for
  the same request stays: the WUI row says what the page saw, the hub row
  says why (R8).

#### 10.4.3 Source (b): the box reader, an hourly cron

Per `e05d9c00` and `6ddfaa91`: a box component, not a Cloud Run job.

- **The action.** `cd csi-spl-orc && ENV=<dev|prd> ./run -a
  do_spl_evlog_read` (new `orc/run/spl-evlog-read.func.sh`). `ENV`
  required; `DRY_RUN` default 1 (prints the groups it would send, sends
  nothing); `EVLOG_MAX_WINDOW_H` default 24.
- **The cron.** One row of `csi-spl-orc/cnf/box-crons/box-crons.manifest`,
  `evlog-read`, installed by `do_install_box_crons` like every box cron
  (each run under its own lock, `cron-no-stack.sh`: a slow run never
  stacks). It runs on the boxes the cnf names,
  `env.box.evlog_reader.boxes` (today the satellite box, per `e05d9c00`),
  every `env.box.evlog_reader.interval_min` minutes (60, per `6ddfaa91`),
  for each env in `env.box.evlog_reader.envs` (`[dev, prd]`). Nothing in
  the action names a box, user, host or path: the box name comes from the
  cnf and `hostname -s`, the paths from `spl_run_paths`. Listing a second
  box in the cnf is the whole move to it (C40).
- **The identity (Q1 B).** The env's read-only reader service account,
  `<cnf env.gcp.evlog_reader_sa_id>@csi-spl-<env>.iam.gserviceaccount.com`
  (cnf `env.gcp.evlog_reader_sa_id: spl-evlog-reader` in `all.env.yaml`),
  made by terraform step `071-gcp-evlog-reader-sa` (row T7a) with one role
  on its project, `roles/logging.viewer`, and nothing else. Its key is
  `$HOME/.gcp/.csi/key-csi-spl-<env>-evlog-reader.json` (mode 600),
  minted out of band by `do_gcp_evlog_reader_key` (row T7a; terraform
  never makes a key, repo CLAUDE.md), one per env on each reader box. The
  action sets `GCP_SA_KEY_FILE` to it and calls the existing
  `do_gcp_pin_account` (`csi-spl-orc/lib/bash/funcs/gcp-account-pin.func.sh:251`):
  its `client_email` in a throwaway `CLOUDSDK_CONFIG`, `--account` on the
  call. No owner account, no write to the shared gcloud config, and **no
  fallback to the per-env project service account**: a box without the
  reader key exits 3 with one line naming the missing key and sends
  nothing (C39, C45). The key reads Cloud Logging and nothing else, so a
  stolen reader key reads logs (already redacted of what the hub never
  logs, 10.6) and cannot change the project.
- **The read.** `gcloud logging read` on project `csi-spl-<env>`, JSON,
  ascending, filter:
  `resource.type="cloud_run_revision" AND
  resource.labels.service_name="<cnf hub.service_name>" AND
  timestamp>="<from>" AND timestamp<"<to>" AND (severity>=ERROR OR
  log_id("run.googleapis.com/varlog/system") OR httpRequest.status>=500)`.
  No sink: the lines are in the `_Default` bucket (cnf `hub.log_bucket`).
- **The window.** From the hub's cursor (10.4.4) to now minus 2 min (Cloud
  Logging's ingest lag), at most `EVLOG_MAX_WINDOW_H` hours; a first run
  starts one hour back. A box that was off for a day catches up in
  24-hour steps, one per run.

#### 10.4.4 The write to the hub: one frame, a cursor, no double write

- **CLI.** `spool evlog cursor --env <env>` prints the hub's cursor
  (`read_until`, `gen`); `spool evlog put --from <ts> --to <ts> --gen <n>`
  reads the gcloud JSON on stdin, runs `evlog.Classify` on each entry,
  groups with `evlog.Groups`, and sends one frame. Raw lines never leave the
  box: only grouped, redacted, normalized rows do.
- **Frame.** New `wire.TEvlog` (`"evlog"`), `evlog_op` `cursor` or `put`,
  `msg_id` paired like the lease frame, the groups (at most 500) and the
  window. The hub takes it only from a box session of the operator
  workspace (`x.tenant` = `operatorTenant`), else 403
  `operator.workspaces`; the strict frame parser accepts the new fields
  once the row is served.
- **No double write, two boxes.** The hub keeps one cursor per env
  (`system_events_cursor`, 10.5). A `put` is a compare-and-set: in one
  transaction the hub checks `gen` = the stored gen and `from` = the stored
  `read_until`, moves the cursor to `to` with `gen + 1`, and upserts the
  groups. A stale gen answers 409 `cursor_moved` and writes nothing; the
  losing box prints one `SKIP` line and exits 0. Two boxes reading the same
  hour therefore count it once, and a box that takes over continues where
  the other stopped. No lease is needed, and the fingerprint upsert alone
  would not be enough (it would add both boxes' counts).
- **Classify rules**, in order (the exact Cloud Run strings are read on
  dev by row T7 before the rules are fixed, R5):
  1. a JSON line of the hub with message `event log write failed`: the
     group it names (its `fp`, `kind`, `n`, ...), as the hub would have
     written it;
  2. any other JSON line of the hub (it carries `service: spool`) at
     ERROR: skipped, the hub wrote it itself (10.4.2);
  3. a `varlog/system` line: memory limit exceeded -> `error.cloudrun_oom`;
     container exit or terminated on a signal, not a scale-down ->
     `error.cloudrun_crash`; startup probe failed or revision not ready ->
     `error.cloudrun_start`;
  4. a request-log entry with `httpRequest.status >= 500` whose `trace` has
     no hub `http` access line in the window -> `error.cloudrun_request`,
     anchor the status; one with a hub line is the hub's own 5xx, skipped;
  5. a non-JSON stderr line starting `panic:`, `fatal error:` or a
     `goroutine N [` block -> `error.go_fatal`, anchor `TopFrame` of the
     lines that follow it in the same second (Cloud Logging may split one
     dump into many entries: R5);
  6. anything else at `severity>=ERROR` -> `error.cloudlog_other`.

#### 10.4.5 Caps

- In-process: at most 1000 open groups between two flushes; a new
  fingerprint past that is counted, not kept, and the flush writes one
  `evlog.overflow` row, message `<n> error groups not kept (cap 1000)`.
- Reader: at most 500 groups per frame; past that, the same overflow row.
- A group's row is one row for life (10.5), so the table grows with the
  number of distinct errors, not with their rate.

### 10.5 Grouping: one row per fingerprint (table change)

One forward-only migration, `rdb/<next>_system_events_error_groups.sql`
(named here, not written; the number is taken with `do_rdb_migration_next`
at build time):

- `system_events` gains `fingerprint text NOT NULL DEFAULT ''` (CHECK
  `^([0-9a-f]{16})?$`), `first_at timestamptz` (NULL for a non-error row),
  `n integer NOT NULL DEFAULT 1` (CHECK `n >= 1`), `issue_key text NOT NULL
  DEFAULT ''` (CHECK `^([A-Z][A-Z0-9]*-[0-9]+)?$`) and `issue_n integer NOT
  NULL DEFAULT 0` (the count when the issue was filed), and `human_id text
  NOT NULL DEFAULT ''` (CHECK `^(HUM-[0-9]+)?$`; Q4 B): the person of the
  group's last sighting that had one, `''` for none. No foreign key to
  `humans`: a group outlives a deleted person, and the trim keeps the table
  small. Existing rows keep `fingerprint = ''` and are not grouped.
- `CREATE UNIQUE INDEX ux_system_events_fingerprint ON system_events
  (fingerprint) WHERE fingerprint <> ''`.
- New `system_events_cursor (env text PRIMARY KEY CHECK (env IN ('dev',
  'prd')), read_until timestamptz NOT NULL, gen bigint NOT NULL DEFAULT 0,
  by_actor text NOT NULL DEFAULT '')`: hub-wide, outside RLS, like
  `system_events`. The hub of an env writes its own env's row only.

The upsert (`store.UpsertSystemErrorGroup`, memory and Postgres):
`INSERT ... ON CONFLICT (fingerprint) WHERE fingerprint <> '' DO UPDATE SET
id = DEFAULT, at = GREATEST(system_events.at, EXCLUDED.at), first_at =
LEAST(system_events.first_at, EXCLUDED.first_at), n = system_events.n +
EXCLUDED.n, message = EXCLUDED.message, human_id = CASE WHEN
EXCLUDED.human_id <> '' THEN EXCLUDED.human_id ELSE system_events.human_id
END` (a sighting with no person keeps the last named one), then the existing trim
(`pgSystemEventTrim`). `id = DEFAULT` gives a repeating group a new id, so
the newest-first page (ordered by id, `hub/log_events.go:182-203`) shows it
on top by its last sighting, and the keep-by-id trim never drops a group
that is still firing. Whether PostgreSQL 16 takes `SET id = DEFAULT` on a
`GENERATED ALWAYS` identity in `ON CONFLICT DO UPDATE` is checked by C34 on
Postgres before anything else in T2; if it refuses, the fallback is a
delete and re-insert in the same transaction, carrying `first_at`, `n` and
the issue columns. Links and the bug lane key on `fingerprint`, never on
`id`.

A group the trim drops (silent for longer than 10 000 newer rows) and that
fires again opens a new row with `n = 1`: a regression is new again, and
the bug lane finds its old issue by the fingerprint line in the issue
(10.7).

### 10.6 What a row shows, and what never reaches one

- **On Monitoring > Events, System scope** (row B8, then T5): when (the
  last sighting, `at`), kind, level, message, origin, and for an error
  group: count `n`, first seen `first_at`, the fingerprint (8 hex shown,
  16 on hover), the person (`human_id`, as `HUM-<n>`, empty for none) and
  the issue as a link (`/issues/<KEY>`) when `issue_key` is set. `origin_kind = component`, `origin_ref` = the route
  pattern for `error.http_server`, the loop name for `error.loop_panic`,
  `cloud-run/<revision>` for the Cloud Run kinds. Admins of the operator
  workspace only (3.2); Delete selected works as on every log.
- **Redaction**, applied by `evlog.Redact` before `Normalize`, on every
  text that reaches a row (message, origin_ref) and on the `put` frame
  before it leaves the box:
  - an email address -> `<email>`;
  - `Bearer <x>`, and the value after `token`, `key`, `secret`,
    `password`, `pwd`, `sig`, `signature`, `authorization`, `cookie`,
    `dsn` (`=`, `:` or a JSON key) -> `<redacted>`;
  - a JWT (`eyJ...` with two dots) -> `<jwt>`; a PEM block -> `<pem>`;
  - a URL's query string -> `?<q>`; userinfo in a URL (`//u:p@`) ->
    `//<redacted>@`;
  - a postgres DSN -> `<dsn>`;
  - any run of 24 or more characters of `[A-Za-z0-9+/_=-]` -> `<blob>`.
- **Never read**: the request body, any header but `X-Cloud-Trace-Context`
  and the session cookie (read only for the person's `HUM-*` id, 10.4.2,
  never stored or logged),
  the query string, the URL path (the mux pattern stands for it), a message
  body. These are not redacted, they are never taken.
- **On the person's Mine log** (Q4 B): the hub's row of 10.4.2 shows in
  the Mine scope like any Mine row (when, source `hub`, status, code,
  route, message), and the person sees and deletes it as their own (3.2).
  It never shows another person, the fingerprint's issue or the System
  row: a person sees that their request failed and the hub's reason in
  one redacted line, nothing of the operator's log.
- **Personal data**: in a message a person shows only as `HUM-<n>`, an
  agent as `<agent>` (10.4.1). The person id of Q4 B is a column
  (`human_id`), never text in the message; it is a `HUM-*` id, never a
  name or an email, and it reaches only operator admins (System) and that
  person (Mine).
- **The test** (C29, C30): a table of 14 planted strings, one per rule
  plus a mixed line, through `Redact`; each must be gone from the output.
  A hub case: a handler that panics with a value holding a planted bearer
  token, an email and a DSN; the stored row holds none of the three. Red
  control: `Redact` as the identity function; the table case and the hub
  case fail, naming the leaked string.

### 10.7 The bug-lane hook

- **The read.** New `cd csi-spl-orc && ENV=<env> ./run -a
  do_spl_evlog_groups` (new `orc/run/spl-evlog-groups.func.sh`): through
  `GET /v1/operator/events?kind=error.` (a kind-prefix filter, new in T4),
  it prints one line per group that is **new** (`issue_key = ''`) or
  **growing** (`n > 2 * issue_n` and `n - issue_n >= 10`, or its issue is
  done and it fired after the issue closed), with fingerprint, kind, n,
  first and last seen, message. Read only.
- **One more source.** The bug round plan's section 2 gets a sixth source
  row, `6. Backend error groups (spec 162 section 10)`, its command
  `ENV=prd ./run -a do_spl_evlog_groups` and `ENV=dev ...`, read on the
  plan's sha like the other five. The rounds rulebook (3.1) names it.
- **One issue per group.** The planner (or the row lane) files one issue
  per new group: class `bug`, priority 2 (rulebook, bugs at priority 2),
  title `<kind>: <message, 80 runes>`, and a body line
  `evlog-fp: <fingerprint>`. Before it files, it searches the open and done
  issues for that line; a hit is reused (reopened when done), never a
  second issue. Dedup is by fingerprint, so a trimmed and re-opened group
  (10.5) finds its old issue.
- **The link, both ways.** New `POST /v1/operator/events/link`, body
  `{"fingerprint": "<16 hex>", "issue_key": "SPL-n"}`, operator admins only:
  sets `issue_key` and `issue_n = n` on the group. The issue holds the
  fingerprint line; the row holds the key. A new action wraps it,
  `do_spl_evlog_link` (FP, ISSUE_KEY, DRY_RUN).
- **Done.** A fix lands, the issue closes (the closer, as for every
  issue). If the group fires again after the close, the next read lists it
  as growing, and the planner reopens the issue.

### 10.8 The owner's goal as targets

`f6b251db` "as errorless and bugless ... as posible", `d0e0085f` "much more
like google": every error is counted, owned and driven down, and a new
one is caught on dev before prd. Proposed, each read by a command:

| target | reads | how |
|---|---|---|
| M1 open groups falls every week; 0 prd groups older than 7 days without an issue | groups with `last_at` in 7 days and no done issue, per env | `ENV=<env> ./run -a do_spl_evlog_groups`, its summary line `open=<n> unissued_7d=<n>`; the weekly fleet report quotes both |
| M2 time to issue: p50 <= 24 h, max <= 72 h | issue created minus `first_at`, per group linked in 7 days | the same action, `EVLOG_REPORT=tti` |
| M3 no new error group on dev after a deploy | groups with `first_at` after the dev deploy's time, level error | a step in `20_hub-build-deploy.yml` after the dev roll: wait 10 min, read `do_spl_evlog_groups` for dev with `EVLOG_SINCE=<deploy time>`; any line -> the step is red and its summary names each group. It never holds prd (Q2 A): its own job, which no prd job `needs` |
| M4 0 crashes and 0 out-of-memory kills a week, per env | groups of kind `error.cloudrun_crash`, `error.cloudrun_oom`, `error.go_fatal` | the same action, `EVLOG_KIND=error.cloudrun_` |

M3 depends on the reader having run: the step runs
`do_spl_evlog_read` for dev itself (not a write race: the cursor CAS of
10.4.4 makes it safe beside the cron), with the dev reader key, never the
project SA key (Q1 B). The key reaches CI as the repo secret
`GCP_KEY_CSI_SPL_DEV_EVLOG_READER`, put by `do_gh_secret_put_gcp_key`
(`csi-spl-iac/src/bash/run/gh-secret-put-gcp-key.func.sh`). Today that
action accepts only the project SA's key (its step 1: the key's
`client_email` must be `<project>@<project>.iam...`) and derives the name
`GCP_KEY_<PROJECT>`; row T9 adds `GCP_SA_KEY_KIND=evlog-reader`, which
expects the reader SA's email instead and appends `_EVLOG_READER` to the
name. Nothing else of that action changes.

Q3 A: every error group gets an issue (10.7), whatever its count or env.

### 10.9 Cases

| case | expect | test |
|---|---|---|
| C28 | `Fingerprint` is equal for two 5xx that differ only in a UUID, a number and a quoted value; different for another route or another token | new `api/internal/evlog/evlog_test.go` |
| C29 | each of the 14 planted secrets and personal strings (10.6) is gone after `Redact`; red: `Redact` as identity fails, naming the string | same |
| C30 | a handler panic whose value holds a bearer token, an email and a DSN stores a row with none of them | `hub/evlog_test.go` (new), memory store |
| C31 | a handler 5xx, a handler panic and a loop panic each add one sighting of their kind; 100 identical 5xx then one flush write one row with `n = 100`; red: a flush that inserts per sighting writes 100 rows | same |
| C32 | an `Error()` line from a hub function adds one `error.log` sighting anchored on that function; an `http 5xx` line and an `event log write failed` line add none (no double, no loop) | same |
| C33 | a flush with the store failing writes one `event log write failed` line per group with its `fp` and `n`, and the action that caused the error still answers as before | same |
| C34 | on Postgres: the upsert of an existing fingerprint keeps one row, adds `n`, keeps `first_at`, moves `at`, and gives the row a new `id` higher than every other | `store/log_events_test.go` (new cases, memory and Postgres) |
| C35 | `put` with a stale `gen` answers 409 `cursor_moved` and changes no row and not the cursor; red: a `put` without the gen check, run twice for one window, doubles `n` | `store/` and `hub/evlog_frame_test.go` (new) |
| C36 | an `evlog` frame from a box of a workspace that is not the operator workspace answers 403 and writes nothing | `hub/evlog_frame_test.go` |
| C37 | `Classify` on recorded dev entries (fixtures read in T7, redacted): one of each rule 1-6 maps to its kind; a hub ERROR line (rule 2) and a request 5xx with a hub trace (rule 4) are skipped | `api/internal/evlog/classify_test.go` |
| C38 | `spool evlog put` sends no field that holds a raw log line: the frame of a fixture with a planted token carries `<redacted>` | `api/cmd/spool/cli_verbs_test.go` |
| C39 | `do_spl_evlog_read` with `DRY_RUN=1` and a stub gcloud prints the groups and sends no frame; with no key exits 3 naming it; its gcloud call carries `--account` | new `orc/tests/spl-evlog-read.tst.sh`; `gcloud-account-pinned.tst.sh` passes |
| C40 | two runs of the reader for one window, as two box names with one stub hub, write the groups once; the second prints `SKIP cursor_moved` and exits 0 | same |
| C41 | `do_spl_evlog_groups` lists a group with no issue as new, one with `n` past the growth rule as growing, one linked and quiet not at all; `do_spl_evlog_link` sets `issue_key` and `issue_n` | new `orc/tests/spl-evlog-groups.tst.sh`; `hub/log_events_test.go` (the link route) |
| C42 | the System scope shows `n`, first seen, the person and the issue link of a group row; a non-error row shows none of them | the B8 e2e, new cases |
| C43 | Q4 B: a 5xx on a request with a signed-in person's cookie, then one flush, writes one `source = hub` row in that person's Mine log (route, status, token, `origin = evlog:<fp>`) and sets `human_id` on the group; 100 identical 5xx of that person in one flush write one Mine row ending ` (x100)`; a 5xx with no cookie, a box request and a loop panic write no Mine row and leave `human_id` as it was; red: a flush that writes one Mine row per sighting writes 100 | `hub/evlog_test.go`, memory store |
| C44 | Q4 B: the person is read without the store: with a store whose every call fails, a 5xx with a valid cookie still names the person on the sighting; a forged or expired cookie names none | `auth/handler_test.go` (`HumanFromCookie`), `hub/evlog_test.go` |
| C45 | Q1 B: `do_spl_evlog_read` calls gcloud with `--account` = the reader SA's email from the reader key; with only the project SA key on the box it exits 3 naming the reader key and never calls gcloud; red: a reader that falls back to `do_gcp_sa_key_file`'s default key calls gcloud as the project SA | `orc/tests/spl-evlog-read.tst.sh` |
| C46 | Q1 B: step `071-gcp-evlog-reader-sa` declares one `google_service_account` and one `google_project_iam_member` with role `roles/logging.viewer`, and no `google_service_account_key` and no other role; `checkov` passes with no new baseline row | new `csi-spl-iac/src/bash/tests/tf-071-evlog-reader-sa.tst.sh`; `do_check_pre_push_lint` |
| C47 | Q1 B: `do_gcp_evlog_reader_key` with `DRY_RUN=1` mints nothing and prints the key path and the SA; with `DRY_RUN=0` and a stub gcloud writes the key only to `$HOME/.gcp/.<org>/key-csi-spl-<env>-evlog-reader.json`, mode 600, never to stdout or a log; every gcloud call carries `--account` | new `csi-spl-iac/src/bash/tests/gcp-evlog-reader-key.tst.sh`; `gcloud-account-pinned.tst.sh` passes |

### 10.10 Build rows

Smallest first; the in-process half needs no infra and comes first. Each
row: its cases with the red control seen RED then GREEN in the commit body
(rulebook C2), `PRE_PUSH_TIER=full` where it touches the store.

| row | what | area | files (only these) | after | cases |
|---|---|---|---|---|---|
| T1 | the pure package: redact, normalize, top frame, fingerprint, groups (no classify yet) | api | new `api/internal/evlog/evlog.go`, `evlog_test.go` | - | C28, C29 (red C29) |
| T2 | the migration, the upsert, the cursor CAS, the link | rdb, api | new `rdb/<next>_system_events_error_groups.sql`; `store/log_events.go` (the new methods, the error kinds of 10.3), `log_events_memory.go`, `log_events_postgres.go`, `log_events_test.go` | T1 | C34, C35 store half (red C35); `PRE_PUSH_TIER=full` |
| T3 | source (a): the sightings, the person, the Mine copy, the hook, the flush loop, the unwritten line, the trace field | api | `hub/server.go` (`middleware`, `logServerError` only); `hub/supervise.go`; new `hub/evlog.go` + `evlog_test.go`; `auth/handler.go` (`HumanFromCookie` only) + `handler_test.go`; `cmd/spool/hub.go` (the hook and the `evlog-flush` loop); cnf `hub.evlog.flush_s` + the tpl-gen render | T2 on master | C30-C33, C43, C44 (red C31, red C43) |
| T4 | the routes: group fields on `GET /v1/operator/events`, `?kind=` prefix filter, `POST /v1/operator/events/link` | api | `hub/log_events.go`, `log_events_test.go`; `hub/openapi.json` | T2 on master | C41 hub half |
| T5 | the page: group columns on the System scope | wui | `wui/pages/monitoring/events/index.vue`; `wui/utils/event-sheet.mjs`; locale keys (new only, agy review last); the C42 e2e | T4 served, B8 on master | C42 |
| T6 | the frame and the CLI: `evlog cursor`, `evlog put`, classify | api | `api/internal/wire/wire.go` (`TEvlog` and its fields); `hub/ws.go` (one case line); new `hub/evlog_frame.go` + `_test.go`; new `api/internal/evlog/classify.go` + `classify_test.go` (fixtures from T7's dry read); new `api/cmd/spool/evlog.go`, `cli_verbs_test.go` | T2, T3 on master | C35 hub half, C36-C38 (red C36) |
| T7a | Q1 B: the reader service account and its key. Terraform step `071-gcp-evlog-reader-sa` (one SA, `roles/logging.viewer` on its own project, no key); the key action `do_gcp_evlog_reader_key` (`ENV`, `DRY_RUN` default 1, run as the env's project SA through `do_gcp_pin_account`); cnf `env.gcp.evlog_reader_sa_id`. Plan in the tf-runner (`ENV=<env> STEP=071-gcp-evlog-reader-sa make do-tf-plan`); **apply only on the owner's go, dev first, then prd** (dev leads prd); the key minted on each reader box only on the owner's go too (a key is a GCP change) | iac, cnf | new `csi-spl-iac/src/terraform/071-gcp-evlog-reader-sa/` (`01-providers.tf`, `02-variables.tf`, `03-sa.tf`, `04-outputs.tf`, the step's tfvars template); new `csi-spl-iac/src/bash/run/gcp-evlog-reader-key.func.sh`; new `csi-spl-iac/src/bash/tests/tf-071-evlog-reader-sa.tst.sh`, `gcp-evlog-reader-key.tst.sh`; cnf `all.env.yaml` (one key) + the rendered tfvars | - (in parallel with T1-T6) | C46, C47 (red C46: a planted `google_service_account_key` resource fails it) |
| T7 | the box reader: the action, the cron row, the cnf; first a read-only dry run on dev that records the Cloud Run strings and the fixtures | orc, cnf | new `orc/run/spl-evlog-read.func.sh`, `orc/tests/spl-evlog-read.tst.sh`; `csi-spl-orc/cnf/box-crons/box-crons.manifest` (one row); cnf `env.box.evlog_reader` in `all.env.yaml` | T6 served on dev and prd AND the `spool` binary on the reader's boxes carries `evlog` (the R2 rule) AND T7a applied on dev and prd with the reader key on each reader box | C39, C40, C45 (red C40, red C45) |
| T8 | the bug lane: the read and link actions, source 6, the rulebook line | orc, doc | new `orc/run/spl-evlog-groups.func.sh`, `spl-evlog-link.func.sh`, `orc/tests/spl-evlog-groups.tst.sh`; `csi-spl-doc/doc/md/rounds-rulebook.md` (3.1, one line) | T4 served | C41 (red: a growth rule without the `issue_n` check lists every linked group) |
| T9 | M3: the post-deploy job (Q2 A: red, never holds prd); the reader key's CI secret | ci, iac | `.github/workflows/20_hub-build-deploy.yml` (one job, no prd job `needs` it); `csi-spl-iac/src/bash/run/gh-secret-put-gcp-key.func.sh` (`GCP_SA_KEY_KIND=evlog-reader` only) and its test | T7 live on dev | a planted dev error group turns the job red on a throwaway branch while the prd deploy job still runs (rulebook: a red control never on master) |

Order: T1, T2, then T3 and T4 at once (`hub/server.go` + `supervise.go`
+ `auth/handler.go` + `cmd/spool/hub.go` vs `hub/log_events.go`:
disjoint), then T6, T8 and T5 (T5 waits for B8), then T7, then T9. T2, T3
and T6 all touch the store's or the hub's start path: one after the other.
T7a shares no file with T1-T6 and runs beside them; it must be applied
before T7 starts.

Only T7a changes GCP: one service account, one role, one key per env and
reader box, each on the owner's go (repo CLAUDE.md, "Nothing mutates GCP
without the owner"). The lane plans and runs the tests; the apply and the
mint are sent to the owner as the exact commands and wait for the go.

Status, row T7a (SPL-5937): landed on master in `386b38058` (step
`071-gcp-evlog-reader-sa`, cnf `env.gcp.evlog_reader_sa_id`, the dev and
prd renders, `do_gcp_evlog_reader_key`, the C46 / C47 tests; checkov
passes with no baseline row); the rotation proves the new key before the
swap (R7 notes N1-N3). Not applied: the apply and the mint wait on the
owner's go, dev first.

### 10.11 The owner's answers, and risks

Poll `00d28227`, answered by HUM-10 in msg `4dda13ce` (2026-11-18 14:52Z).
No question is open.

| Q | question | answer | where in this section |
|---|---|---|---|
| Q1 | who reads Cloud Logging | **B:** a new read-only service account (`roles/logging.viewer`), granted by a terraform step on the owner's go, plus one more key per env on the reader's box | 10.4.3 the identity; row T7a; C45-C47 |
| Q2 | a new error group on dev after a deploy (M3) | **A:** the step turns red and says so; prd still deploys | 10.8 M3; row T9 |
| Q3 | which groups get an issue | **A:** every error group | 10.7, 10.8 |
| Q4 | where backend errors show | **B:** also in the Mine log of the person whose request failed, a person id on the row | 10.4.2 the person and the Mine copy; 10.5 `human_id`; 10.6; C43, C44 |

- R4 Up to 30 s of sightings die with a crashed process (10.4.2). The
  crash row says it happened; the count of the errors just before it is
  short.
- R5 The Cloud Run strings of rules 3 and 5 (out of memory, exit, probe,
  panic dumps split over entries) are from Cloud Run's documented
  behaviour, not read on this tree. T7 reads them on dev first (read-only)
  and records the fixtures C37 uses; a rule that matches nothing on dev is
  dropped from the first build, not guessed.
- R6 Today's 5xx and panic rates on dev and prd are unmeasured. T3's lane
  reads one day of `severity>=ERROR` counts per env (read-only) before it
  lands, as R1 did for B2: an observation, not a gate.
- R7 Rule 4 needs Cloud Run's request log `trace` and the hub's own trace
  field to match. If they do not on dev (T7), rule 4 counts every request
  5xx with status 502, 503 or 504 that has no hub line within 1 s, and says
  so in the spec.
- R8 (Q4 B) A person can see two Mine rows for one failed request: the
  WUI's (`source: 'api'`, what the page saw) and the hub's (`source: hub`,
  why). They are kept apart on purpose; joining them needs a request id in
  the WUI's journal, which it does not record today, and is out of this
  section. A Mine row the flush could not write (database down) is lost;
  the group's count is not (rule 1).
- R9 (Q1 B) The reader key is a second long-lived key per env per reader
  box. It is rotated with the per-env SA key's cadence
  (`SA_KEY_MAX_AGE_DAYS`, `gcp-sa-key-rotate.func.sh`); how
  `do_gcp_sa_key_rotate` takes a second SA is left to T7a's lane, which
  either extends it or states in its commit why the reader key action
  carries its own rotate.
  Decided by T7a: the key action carries its own rotate
  (`EVLOG_KEY_ROTATE=1 DRY_RUN=0`: mint, prove the new key reads the logs,
  delete the old key id). Each reader box holds its own reader key, never a
  copy, so the other-box proof and the CI run that `do_gcp_sa_key_rotate`
  needs for the one shared project SA key do not apply; `DRY_RUN=1` warns
  past `SA_KEY_MAX_AGE_DAYS` (30).
