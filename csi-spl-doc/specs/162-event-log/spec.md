# 162 The event log: complete rows, workspace and system events, select and delete

Version v0.5 (2026-10-28): the author's draft for the panel. Not reviewed.
The panel's second seat is a mistral reviewer, read-only (owner 10-27);
v1.0 is the reviewer's signing commit (section 9).

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

Every `file:line` was read on origin/master `dd3b55565` (2026-10-28). No
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
| E1 complete row | `ae1a43f8` | the hub answers `method, origin, path, code, name` (`hub/events.go:39-54`), but `eventRowsOf` drops them (the `EventRow` typedef, `wui/utils/event-rows.mjs:7-17`, has none of them) and the table shows none |
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
  revoke, role, roles, remove (`hub/rbac.go:552-556`); channel delete
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
- **Hub start.** `hub.started`, actor `hub`, message the version (the same
  source `/version` reads), written once per process start: each deploy
  roll shows in the System log.

The owner DM on an orchestrator failover (`:2169-2172`) stays as it is.

### 3.4 Workspace producers (E3, first set)

One `AddWorkspaceEvent` call in each handler, after its store write
succeeded. The write is best effort: a failed log write is logged and the
action stands, as `opAudit` does (`hub/operator_workspaces.go:115-116`).

| kind | handler | origin |
|---|---|---|
| `member.invited`, `member.invite_revoked` | `handleMemberInvite`, `handleInviteRevoke` (`hub/rbac.go:552-553`) | component `members` |
| `member.role_changed` | `handleMemberRole`, `handleMemberRoles` (`:554-555`) | component `members` |
| `member.removed` | `handleMemberRemove` (`:556`) | component `members` |
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
| B1 complete row, time, ask before Clear | E1, E2, E7 | wui | `wui/utils/event-rows.mjs`; `wui/utils/event-sheet.mjs` (columns request, code); `wui/utils/date-iso.mjs` (new `isoDateTimeOffset` only); `wui/pages/monitoring/events/index.vue`; `csi-spl-wui/i18n/locales/*.json` (new keys only, agy review last); `tests/unit/event-rows.test.mjs`, `event-sheet.test.mjs`, `date-iso.test.mjs`; `tests/e2e/events-monitoring-tab.test.mjs`, `events-clear-log-mobile.test.mjs` | - | C1-C6 (red C2, C6) |
| B2 personal delete selected (hub) | E5 | api | `hub/events.go` (the new route only), `hub/events_test.go`; `store/human_events.go` (new `DeleteHumanEvents` on the interface), `human_events_memory.go`, `human_events_postgres.go`, `human_events_test.go`; `hub/openapi.json` (the path) | - | C7-C9 (red C8); `PRE_PUSH_TIER=full` |
| B3 workspace and system store, routes | E3 | rdb, api | new `rdb/<next>_workspace_system_events.sql` (both tables; RLS for the tenant one); new `store/log_events.go`, `log_events_memory.go`, `log_events_postgres.go`, `log_events_test.go`; `store/rls_test.go` (the table list only); new `hub/log_events.go` + `_test.go`; one route line in `hub/server.go`; `hub/openapi.json` (the four paths) | - | C10-C15 (red C11); `PRE_PUSH_TIER=full` |
| B4 lease reason on the wire; the hub writes it | E4 | api | `api/internal/wire/wire.go` (the frame field); `api/internal/action/lease.go` + new `lease_test.go`; `api/cmd/spool/lease.go` (the flag) + `cli_verbs_test.go`; `hub/box_lease.go` + `box_lease_test.go`; `store/fleet_lease.go`, `fleet_lease_postgres.go`, `fleet_lease_test.go` (CAS answers the previous holder and age); the `hub.started` write in the hub's start path | B3 on master | C16-C19 (red C17); `PRE_PUSH_TIER=full` |
| B5 the loop names the reason | E4 | orc | `orc/run/spl-dispatch-lease.func.sh` (new `spl_fleet_reason`; `--reason` on the write at `:2163` and on the SPL-2892 write; nothing on `spl_fleet_mirror_out`); new `orc/tests/spl-fleet-reason.tst.sh` | B4 served on dev and prd AND the `spool` binary on every box carries `--reason` (R2) | C20-C21 (red C21) |
| B6 workspace producers | E3 | api | `hub/rbac.go` (the five handlers of 3.4, one call each), `hub/channel_members.go` (`handleDeleteChannel`), `hub/join_tokens.go` (three handlers), and their `_test.go` cases | B3 on master | C22-C23 (red: C22's refused-call case with the write moved before the check) |
| B7 select and delete selected (page, Mine) | E5 | wui | `wui/pages/monitoring/events/index.vue`; new `wui/components/EventsBulkBar.vue`; the events client's `delete` in `wui/utils/event-log.mjs`; locale keys (new only, agy review last); `tests/unit/event-log.test.mjs`; the C24 e2e cases | B1 and B2 on master | C24-C25 (red C25) |
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

Open until the reviewer's pass. The author's proposals, for the reviewer
to accept or overturn:

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

(filled at v1.0: the reviewer's findings and what was folded)

## 9. Signatures

(filled at v1.0: the reviewer's signing commit)
