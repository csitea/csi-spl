# 153 Monitoring: the tab row beside the heading, and a live Lanes tab

Addendum (2026-10-30, SPL-4421): section 3.10 (the Topics tab, one row
per topic with its lanes and issues, and the `topic_channel` field on the
two lanes routes), cases C45-C48 and build row B10. Owner HUM-10, t1
topic `08213e0e`, msg `8caf41ec`. Placed by the dispatch holder as one
lane brief, not a panel version: v1.3 below is unchanged.

Version v1.3 (2026-10-27): v1.2 plus section 3.8 (every Lanes row names
its issue, its discussion and its workspace; queued asks show; a rotation
keeps the lane's topic), cases C36b (narrowed), C38-C44 and build row B8.
Owner HUM-10: csitea topic `a1ae72a7`, msgs `80e92ffb` + `a6c87420`; t1
topic `f94e07bf`, msgs `77d5b3ab`, `33f8eecb` and `67c63b8d`
(2026-10-27 10:01-10:1xZ). Issue SPL-3818.

Version v1.2 (2026-10-26): v1.1 plus section 3.7 (how a lane names the
workspace it works for), cases C28b and C31-C37, build row B7 and C28's
short-id clause, which B7 reverses. Owner HUM-10, topic
`f88d6ee4`, msg `694f9ede` (2026-10-26 09:52:36Z): "I want to see the
lanes working here as well" (the Monitoring > Lanes tab of a customer workspace, W below). Issue
SPL-3514. Nothing else changed.

Version v1.1 (2026-10-24): v1.0 plus the owner's answer to O1 = B
(section 7), which changes 3.2 "Who sees it" and adds section 3.6, cases
C25-C30 and build row B6. Nothing else changed. v1.1 is not reviewed yet:
the dispatcher places one cross-vendor reviewer on it before B6 is built.

v1.0 (2026-10-23) was the panel result, with the claude seat's D1
text fix (section 8). Step 2 of the owner rule for a
big change: the written spec, then the panel, then the build. v0.1
(`20b5d6eae`) plus the editor's findings, the claude seat's findings and
re-check, and the agy seat's findings (section 8). Signed by each seat's
own message on this sha (section 9). Built since: B1 `41087d88d`, B3
`b7fba33ad`, B5a `43ceebc3f`, B2 `cfc52d41c`.

Source: prd topic in the owner's workspace,
`topic:5e7b15c9-2995-427d-8b05-659762fbb9d8`. Issue: SPL-3075 (this spec),
epic SPL-2403. Each build row in section 5 gets its own issue when it is
placed.

Paths used below:

- `wui/` = `csi-spl-wui/src/`
- `hub/` = `csi-spl-api/src/go/spool-hub-api/internal/hub/`
- `store/` = `csi-spl-api/src/go/spool-hub-api/internal/store/`
- `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`
- `orc/` = `csi-spl-orc/src/bash/`

Every `file:line` was read on origin/master `848de71ef` (v0.1 read
`2343dadbe`; no cited code line moved between the two). The v1.0 changes
(the agy seat's findings) were checked on `369b25d5f`. Every prd count was
read on 2026-10-23 between 15:05Z and 15:40Z with
`ENV=prd ./run -a do_spl_db_query` (csi-spl-orc), n = 1 read each, by the
editor; the claude seat has no prd access and did not re-check them.

## 1. The owner's asks, verbatim

Owner HUM-10, in the topic above:

| msg | time (UTC) | text |
|---|---|---|
| `3cb1628e-c1ab-4ab0-9d5e-a51c913ea4e1` | 2026-10-20 16:46:05 | "the tabs for the monitoring should start some 5 mm next to the monitoring on the same row" |
| `98b31bae-ae5b-4ba5-baca-c601e3a200c0` | 2026-10-20 16:46:12 | (no text; one attachment `image.png`, 2560x1600: a screenshot of `/monitoring/tokens` with the "Monitoring" heading on one row and the tabs Agents, Boxes, Costs, Tokens on the row below it) |
| `5949d68e-4d4c-4ccb-b4ca-f204e21398e0` | 2026-10-20 16:46:31 | "and we should add the lanes tab ,, which will show each 1 minute the a active lanes ..." |
| `5c7d1395-2fc3-44e0-9b74-9ba3f32f3eee` | 2026-10-20 16:46:56 | "so that from an active lange row one could jump to the discussion and from there to the issues" |
| `7ea36ebd-b7a3-456b-b563-dbf1e443cc60` | 2026-10-23 12:15:41 | "Go for implementation." |

Read as three asks:

- **A1** The Monitoring tab bar moves onto the heading's row, starting
  about 5 mm to the right of the word "Monitoring".
- **A2** A new tab, Lanes, lists the active lanes and refreshes every
  minute.
- **A3** A lane row opens the lane's discussion (the topic it works for),
  and the discussion opens its issues.

## 2. What exists on master

### 2.1 The tab bar today (A1)

- `wui/utils/monitoring-tabs.mjs:16-23`: `MONITORING_TABS`, four tabs:
  agents, boxes, costs (`perm: 'costs.read'`, :20), tokens
  (`operatorsOnly: true`, :22). `ready: false` reserves a tab the bar
  never draws (:14-15). `visibleMonitoringTabs` filters by operator and
  perm (:34-37).
- `wui/pages/monitoring.vue:9-14`: the `<header class="feed-header">` holds
  `MobileBack`, `SectionClose side="start"`, the `<h2
  data-test="monitoring-heading">` (:12) and `SectionClose side="end"`.
- `wui/pages/monitoring.vue:16`: an empty summary strip, hidden while
  empty (`wui/assets/css/main.css:1580`).
- `wui/pages/monitoring.vue:17-27`: the `<nav class="monitoring-tabs"
  data-test="monitoring-tabs">` is a SIBLING after the header, so it sits
  on its own row below the heading. This is the owner's screenshot.
- `wui/assets/css/main.css:333-343`: `.feed-header` is a flex row,
  `align-items: center`, `gap: 12px`, `padding: 12px 20px`, `min-height:
  52px`. On a phone, `main.css:1003`: `padding: 4px 12px 4px 4px; gap:
  6px`.
- `wui/assets/css/main.css:344-350`: `.feed-header h2` has `min-width: 0;
  overflow-wrap: anywhere`, so in a crowded row it may shrink and break a
  word. This rule is shared by every section header.
- `wui/assets/css/main.css:1581-1584`: `.monitoring-tabs` (flex, `gap:
  4px`, `padding: 0 16px`, its own bottom border) and `.monitoring-tab`
  (`padding: 8px 12px`, `margin-bottom: -1px`, a 2px accent underline on
  the active one).
- The end close X: `wui/components/SectionClose.vue:9` renders it only off
  the phone (`v-if="!stack.isMobile.value"`); `margin-inline-start: auto`
  (`SectionClose.vue:33`) pushes it to the end.
- Tests that find the bar by `data-test=monitoring-tabs`:
  `csi-spl-wui/tests/e2e/monitoring-costs.test.mjs:107` and
  `csi-spl-wui/tests/e2e/rail-order-default.test.mjs:341`. The unit test
  `csi-spl-wui/tests/unit/monitoring-tabs.test.mjs:25` pins the order
  `['agents', 'boxes', 'costs', 'tokens']`.

### 2.2 Data an active-lane list could read (A2)

What the hub has:

- **`fleet_lanes`** (`rdb/0096_fleet_lanes.sql:15-29`; key `(tenant_id,
  fleet, agent_id, agent_box)` since `rdb/0102_agent_at_box_key.sql:22`;
  the agent id rule `rdb/0155_mistral_kind.sql:34-35`, a lane id is
  `[acgmq]-` and three digits): one row per agent, `repo, branch, scope,
  files, topic, state live|done, writer_box, updated_at`. No issue key, no
  start time.
- It is written and read only over the box WebSocket: `lane_op put` and
  `lane_op list` (`hub/box_lane.go:13-24`, the row `LaneRow` :27-39). The
  only non-test caller of `ListFleetLanes` is `hub/box_lane.go:132`. Only a
  box pinned in the tenant may call it (:23-24). **No HTTP route serves
  it, so the WUI cannot read it today.**
- `done` rows older than 7 days are pruned (`store/fleet_lane.go:33`
  `LaneDoneTTL`), but only inside a `put`
  (`store/fleet_lane_postgres.go:35-36`). `live` rows are never pruned.
- The spawn path writes the row: `_spawn_lane_put`
  (`orc/features/spawn-agents/scripts/spawn-core.inc.sh:277-293`, the put
  at :291-292) runs `lane-map.sh put ... --topic "${SPAWN_LANE_TOPIC:-}"`
  in the background, best effort. `lane-map.sh done` sets `done` at the
  lane's exit (`orc/features/spawn-agents/scripts/lane-map.sh:55-59`) and
  at retire (`orc/features/spawn-agents/scripts/agent-id-retire.sh:292-295`).

What the prd data says (tenant `t1`, fleet `main`):

| measure | value |
|---|---|
| rows `state = live` | 212 |
| of those, `updated_at` within 1 h / 24 h / 7 days | 23 / 31 / 40 |
| of those, with a non-empty `topic` | 5 |
| rows `state = done` | 1318, 14 with a topic |
| the 172 `live` rows older than 7 days: last written | all on or before 2026-10-14 (sat 113 rows, written 10-02..10-11; the second box 55 by its box desk on 10-02, and 4 more, 10-09..10-14) |
| of the 113 sat ids, in `/var/spool-hub/registry.retired.tsv` on sat | 3 |

So `live` alone is not "active": a lane that ends without `/exit-clean`
and is never retired stays `live`. And the topic is empty on 207 of 212
live rows. Where `SPAWN_LANE_TOPIC` is set (`git grep -n SPAWN_LANE_TOPIC
848de71ef`): read at `spawn-core.inc.sh:288,292` and
`spawn-window.sh:151,400,403,465`; set in two tests
(`test-spawn-dry-run.sh:165`, `spawn-window-journal.tst.sh:80`) and in the
hand commands of `csi-spl-doc/doc/md/runbook-dispatcher.md:225` and
`csi-spl-doc/doc/md/runbook-orchestrator.md:82`. **The queue placer, which
places most lanes, never passes it**: its launch
(`orc/run/spl-spawn-place.func.sh:547-552`) calls `spawn-window.sh` with
`SPAWN_BOX` and `SPOOL_AGENT_ID` only, on two lines: the test seam
`SPAWN_PLACE_LAUNCH_CMD` (:547-549) and the real call (:551-552). An ask's
topic is `^([A-Za-z0-9_-]{1,64})?$` (`rdb/0097_fleet_asks.sql:46`): a full
uuid, or another id such as a `dispatch-<topic8>` alias (the task the
queue's replies ride, `orc/run/spl-spawn-queue.func.sh:92-93`). This lane's own row is an example:
`c-898@sat`, `live`, topic `''`.

Other hub routes, none of which carries a lane's topic or issue:

- `GET /v1/view/roster` (`hub/view.go:50`, tenant members): boxes, their
  agents and each agent's presence. The Agents tab reads it through the
  roster store (`wui/pages/monitoring/agents/index.vue`). Lanes are often
  absent from it: a box may not announce its lanes
  (`orc/run/spl-lane-issue.func.sh:164-166`).
- `GET /v1/operator/fleet-tokens` (`hub/fleet_tokens.go:60`, operator
  admins only through `fleetLoadCaller`, `hub/fleet_load.go:120-139`): per
  agent `agent_id, vendor, model, box, last_active` and the burn.
  `last_active` is the last minute with token burn
  (`store/fleet_tokens.go:319`), pushed by the box cron every 30 s
  (`orc/.../token-burn-collect-cron.sh:2-5`). The burn rows are per
  `(box_tag, agent_id, minute_bucket)` with no tenant
  (`rdb/0199_fleet_token_burn.sql:6,11-12,23`). In prd `box_tag` and
  `fleet_lanes.agent_box` use the same box ids (2026-10-23 17:2xZ, n = 1:
  burn rows of the last day carry `box_tag` `sat` 5046 and the second box
  2781; `t1` live lane rows carry `agent_box` `sat` 132 and the second box
  78; no other value on either side). The Tokens tab polls it every
  `TOKENS_POLL_MS = 30000` (`wui/utils/monitoring-tokens.mjs:23`) while the
  page is visible (`wui/pages/monitoring/tokens/index.vue:96-119`).

What lives only on a box:

- `registry.tsv`, every agent id with its pane and run dir
  (`spawn-core.inc.sh:567,572`). Not pushed.
- The lane's issue key, `<spool root>/<id>/lifetime/issue`, written by
  `sw_issue` (`orc/features/spawn-agents/scripts/spawn-window.sh:382-417`)
  after the claim and before the window, so before `_spawn_lane_put` runs
  inside the window start (`spawn-core.inc.sh:539`). A dry run writes no
  file (`spawn-window.sh:393-395`, PLAN only); the seed then reads
  `SPAWN_ISSUE` or the brief's `Issue:` line (`_spawn_issue_block`,
  `spawn-core.inc.sh:351-356`). This lane's file reads `SPL-3075`. Not
  pushed to `fleet_lanes`.

### 2.3 Lane -> discussion -> issues (A3)

- An issue links its discussions in `issue_discussions(number, task_id)`
  (`rdb/0194_issue_discussions.sql:39-47`, `task_id uuid` at :42), indexed
  by topic (:49), tenant-scoped by RLS (:51-56).
- Issue routes: `GET /v1/view/issues`, `GET /v1/view/issues/{ref}`, and
  `POST` / `DELETE /v1/issues/{ref}/discussions` (`hub/issues.go:797-807`).
  The list filters by status, label, assignee, priority, level and
  deadline; it has **no filter by discussion**.
- The lane issue's `assignee` is meant to be the lane
  (`orc/run/spl-lane-issue.func.sh:163-171`), but the hub takes only
  agents its roster announces and a box may not announce its lanes, so the
  desk that placed the lane is set instead (:164-166). In prd: SPL-3075
  (this lane) reads `assignee = c-002@sat`, and of the 185 `wip` issues in
  `t1`, 0 have a lane id as assignee; 120 have a dispatch seat (`c-002` on
  its two boxes: 61 and 59) and 56 none. **So the hub cannot find a lane's
  issue from the issue side either.**
- All 185 `wip` issues have at least one `issue_discussions` row. SPL-3075
  links `5e7b15c9-...` (by `c-002`). So topic -> issues already works in
  the data.
- WUI links: a topic is `/t/<task_id>` (`wui/pages/t/[task_id].vue`;
  `discussionPath`, `wui/utils/issue-discussions.mjs:63-64`); an issue is
  `/issues?issue=<KEY>` (`issueHref(prefix, key, pathFor)`,
  `wui/utils/issue-key-links.mjs:40-44`, which needs the tenant's key
  prefix). An issue shows its discussions
  (`wui/components/IssueDiscussions.vue`); **a topic does not show its
  issues** (`git grep -n -i issue -- 'csi-spl-wui/src/pages/t/'
  csi-spl-wui/src/components/TopicPane.vue` prints nothing).

### 2.4 Spec 143's reserved `/reporting/lanes` (T053)

- `wui/utils/reporting-tabs.mjs:25-26`: `lanes`, `/reporting/lanes`,
  `operatorsOnly: true`, `ready: false`.
- `wui/pages/reporting/lanes.vue:1-16`: the stub (T053, `d27cc331e`).
- Its scope (`csi-spl-doc/specs/143-reporting-section/spec.md:713-720`) is
  history: lanes spawned per day, landing success rate, duration per kind,
  from `fleet_asks`, `box_beats` and registry logs.

No clash: Reporting `/reporting/lanes` stays the history (counts over
days); Monitoring `/monitoring/lanes` is the live list (now, refreshed
every minute). Different paths, different tab lists, different label keys
(`reporting.tab.lanes` vs `monitoring.tab.lanes`). The hub view of
section 3.3 serves the live list only (decision P6).

## 3. The design

### 3.1 The tab row on the heading's row (A1)

- `monitoring.vue`: the `<nav class="monitoring-tabs">` moves INSIDE the
  `<header class="feed-header">`, right after the `<h2>`, before
  `SectionClose side="end"`. The `data-test` values stay.
- 5 mm: a CSS millimetre is 3.78 px, so 5 mm is 18.9 px. The bar gets
  `margin-inline-start: 0.5rem` (8 px at the 16 px root), and the
  header's 12 px `gap` does not add to it (the nav's margin is the whole
  distance, e.g. a negative inline margin of the gap, or the gap moved to
  the other children). Every tab keeps its `padding: 8px 12px`, the first
  one too, so its underline and its tap target stay symmetric (agy seat).
  So the first LABEL starts 8 + 12 = 20 px (1.25rem) after the end of
  "Monitoring", which is what C2 measures.
- The heading never shrinks or breaks: on this page only
  (`.monitoring-page .feed-header h2`, since `.feed-header h2` is shared),
  `flex: none; white-space: nowrap`.
- The bar loses its own bottom border and side padding; the header's
  border is the one line. The nav takes `align-self: stretch` and puts its
  tabs at its bottom (`align-items: flex-end`), so the active tab's 2 px
  underline sits ON the header's bottom border despite the header's
  `align-items: center` and 12 px block padding (the header's block
  padding is cancelled for the nav, e.g. a negative block margin).
- The end close X stays at the far end: the nav takes `flex: 1 1 auto;
  min-width: 0`; the X keeps `margin-inline-start: auto`.
- Phone (the `main.css:1003` block, header gap 6 px): the same row, the
  first LABEL 12 px after the heading (decision P5): the nav's margin is
  0 and the header's 6 px gap does not add to it, so the 12 px is the
  first tab's own padding. There is no end X on a
  phone (`SectionClose.vue:9`), so the bar takes the rest of the row and
  scrolls sideways INSIDE itself (`overflow-x: auto`) when the tabs do not
  fit; the page never scrolls sideways. No scrollbar is shown, since it
  would crowd the 52 px header and the 2 px underline:
  `scrollbar-width: none` and `.monitoring-tabs::-webkit-scrollbar {
  display: none }`.
- The empty summary strip stays below the header, unchanged.

### 3.2 The Lanes tab (A2)

- A fifth row in `MONITORING_TABS`, after tokens: `{ id: 'lanes', path:
  '/monitoring/lanes', labelKey: 'monitoring.tab.lanes', operatorsOnly:
  true, ready: true }`.
- Page `wui/pages/monitoring/lanes/index.vue`, its own chunk.
- One row per ACTIVE lane: agent `id@box`, vendor, the scope (the brief's
  title), the discussion (topic title, linked), the issue key(s) (linked),
  the time since the row was written, and the last token activity.
- **Active** (decision P1) = `fleet_lanes.state = 'live'` AND the agent is
  a lane id (`^[acgmq]-[0-9]{3}$`, the form of `rdb/0155:35`; the `BOX-0`
  box row and old upper-case ids are left out) AND either the agent's
  fleet-tokens `last_active` is within 15 min or `updated_at` is within
  60 min. A vendor with no burn parser falls back to the 60 min part. The
  join is `fleet_token_burn_events.agent_id = fleet_lanes.agent_id AND
  box_tag = fleet_lanes.agent_box` (the same ids, 2.2). Measured in prd
  2026-10-23 17:21Z, n = 1, over the 145 `t1` live rows with a lane id:
  burn within 15 min 25, `updated_at` within 60 min 24, active (either) 27.
  No new heartbeat column, no roster presence (lanes are often not in the
  roster, 2.2).
- Refresh (decision P4): the page fetches every 60 s while the browser tab
  is visible, the way Tokens does every 30 s (`tokens/index.vue:96-119`,
  with the visibility catch-up), with "updated N s ago" and the same amber
  / red lag marks. `LANES_POLL_MS = 60000` in
  `wui/utils/monitoring-lanes.mjs`.
- Long cells: the scope may be up to 500 characters
  (`rdb/0096_fleet_lanes.sql:22`) and a topic title is long too. The
  scope and discussion cells stay on one line (`white-space: nowrap;
  overflow: hidden; text-overflow: ellipsis`, a max width of about
  280 px) with the full text in a `title` attribute. The table sits in a
  wrapper that scrolls sideways inside itself, as the Tokens table does
  (`.tk-table-wrap { overflow-x: auto; max-width: 100% }`,
  `wui/components/monitoring/token-burn/token-burn.css:5`). An empty
  discussion or issue cell shows a muted dash.
- Text: `monitoring.tab.lanes` reuses each locale's existing
  `reporting.tab.lanes` word (19 locales, all present, e.g. en "Lanes",
  bg "Линии"). "updated N s ago" mirrors `monitoring.tokens.updated`
  (en "Updated {n} s ago") word for word in each locale; most use a short
  "s" with no plural forms (he and tr do not: "{n} שניות", "sn"; the
  agy seat's call).
- Sort: newest `updated_at` first. Empty list: one line, "No active lanes".
- Who sees it (owner O1 = B, section 7): an operator admin sees every
  active lane, as built (3.3). A workspace's owners and admins see only
  the active lanes working on that workspace's own topics (3.6, row B6).
  Every other member sees no tab. The hub's 403 is the control; hiding
  the tab is only the UI. Until B6 lands the tab stays `operatorsOnly:
  true` (B4).

### 3.3 The hub view the tab reads

- `GET /v1/operator/fleet-lanes`, gated by `fleetLoadCaller` (an operator
  admin session or the operator service account), the same gate as
  fleet-tokens. Route registered beside `routeFleetTokens`
  (`hub/server.go:487`).
- Answer: `{ as_of, lanes: [{ agent_id, agent_box, vendor, scope,
  topic_id, topic_title, issues: [{ key, status }], updated_at, age_s,
  last_active }] }`, active rows only (3.2's rule; the 15 and 60 min
  cut-offs are hub constants).
- `issues` = the lane's own issue key (3.4) plus every issue that
  `issue_discussions` links to `topic_id` (one indexed lookup,
  `issue_discussions_task`), each key once.
- **One tenant only.** The view reads the operator tenant's `fleet_lanes`,
  topics and issues, and never another tenant's. A lane whose topic is not
  a topic of the operator tenant (a lane working in a customer workspace)
  gets `topic_title ""`, its `topic_id` shown as text and not linked, and
  `issues` holding the lane's own key only.

### 3.4 Filling the row: topic and issue key (orc + rdb)

The view is empty of links while 207 of 212 rows carry no topic. So:

- `rdb/`: a new migration `<next>_fleet_lanes_issue_key.sql` adds
  `fleet_lanes.issue_key text NOT NULL DEFAULT ''` (CHECK `''` or
  `^[A-Z][A-Z0-9]{1,9}-[0-9]{1,9}$`). `<next>` is the next free number at
  B3's LAST rebase, re-checked after it: on `848de71ef` the last was
  `0213_box_locks.sql`; on `369b25d5f` `0214_topic_priorities.sql` has
  landed (`a63179997`, SPL-3052, agy seat), so the next is at least
  `0215`, and more unlanded worktrees plan numbers too.
- `LaneRow` gets `issue_key`; `lane_op put` stores it.
- `lane-map.sh put` gets `--issue K`.
- `_spawn_lane_put` fills `--topic` from, in order: `SPAWN_LANE_TOPIC`;
  the topic the lane issue links (`LANE_ISSUE_TOPIC`, the value
  `spawn-window.sh:400` passes); the brief's first HUB topic uuid, i.e. one
  written as `topic:<uuid>`, `topic <uuid>` or `/t/<uuid>`. Never the
  first bare uuid in the brief: a spool task alias such as
  `dispatch-5e7b15c9` maps to a spool uuid (`84f409b7-...` on this lane)
  that is not the hub topic.
- `_spawn_lane_put` fills `--issue` from `lifetime/issue` on a live spawn
  (already written before the put, 2.2: no reorder) and, in a dry run,
  from `_spawn_issue_block`'s fallback: `SPAWN_ISSUE`, then the brief's
  `Issue:` line.
- The queue placer (`orc/run/spl-spawn-place.func.sh:547-552`) sets
  `SPAWN_LANE_TOPIC` from the ask's topic ONCE, before the
  `SPAWN_PLACE_LAUNCH_CMD` branch, so the test seam and the real call
  carry the same value; only when the topic is a full uuid (a
  `dispatch-<topic8>` alias sets nothing). This is the path that places
  most lanes.
- A topic given as an 8-hex short id is passed to the put unchanged and
  resolved to the full uuid by the hub at `put`, or stored empty when it
  does not match exactly one topic of the tenant: a short id never reaches
  the WUI as a link.
- Stale rows (decision P2): no prd write. The view's activity cut-off
  hides them; retire already closes a row (2.2).

### 3.5 Discussion -> issues (A3)

- The lane row's discussion link opens `/t/<topic_id>`.
- `GET /v1/view/issues?discussion=<task_id>`: a new filter on the existing
  list, served from `issue_discussions_task`. The `ListIssues(ctx,
  tenantID)` signature (`store/issues.go:392`) does NOT change: it has
  about 20 callers outside the store (`git grep -n 'ListIssues(' --
  csi-spl-api | grep -v 'func '` -> 20 on `369b25d5f`). A new store
  method returns the issue numbers linked to one topic (interface, memory
  store and Postgres), and the hub's one list path, `listIssues`
  (`hub/issues.go:668`), keeps only those numbers. A value that is not a uuid
  is a 400 `bad_request`, checked before the query (the column is `uuid`:
  Postgres would throw 22P02). The issues list's access rules are
  unchanged.
- The topic header shows its linked issues as chips (`SPL-3075 wip`), each
  to `/issues?issue=<KEY>` (`issueHref` with the tenant's key prefix).
  None linked: no chip, no space. Each chip has an `aria-label` from a new
  key `topic.issue_chip_aria` ("Linked issue {key}: {status}"); the status
  code itself stays untranslated as in the issues list, its hover text the
  existing `issues.status_hint.<id>` (`wui/utils/issues-view.mjs:13,25`).
- The lane row ALSO shows the issue keys (3.2), so the issue is one click
  away even before the topic chips land (decision P3).

### 3.6 A workspace's owners and admins see their own lanes (O1 = B, row B6)

What is on master, read on `0073343c2` (B1, B2, B3 and B5a landed; B4
not: `ls csi-spl-wui/src/pages/monitoring/` -> agents, boxes, costs,
tokens):

- **How a lane is tied to a workspace.** Only by its topic:
  `fleet_lanes.topic` (`rdb/0096_fleet_lanes.sql:15-29`), filled by
  `_spawn_lane_put` (`orc/features/spawn-agents/scripts/spawn-core.inc.sh:277-308`,
  B2): `SPAWN_LANE_TOPIC`, else `LANE_ISSUE_TOPIC`, else the brief's
  first `topic:<id>` / `/t/<id>`. The row itself lives in the tenant of
  the box that wrote it (`hub/box_lane.go:128-131`, `x.tenant`), i.e. the
  operator workspace for the fleet's boxes. An 8-hex short id resolves
  only among THAT tenant's topics (`hub/box_lane.go:22-23,154`), so a lane
  is tied to a customer workspace only when its topic is a full uuid. The
  lane's own issue key (rdb 0221) is an issue of the operator workspace,
  not of the customer's. A lane with no topic, or with a topic that is not
  one of the workspace's, is tied to no workspace: the workspace view
  shows nothing for it.
- **Why the hub must do the join.** `fleet_lanes` is tenant-scoped by RLS
  (`rdb/0096_fleet_lanes.sql:33-39`): a session in workspace w1 cannot read
  the operator's rows. Every piece the join needs already exists:
  `ListFleetLanes(ctx, op, fleet, now)` in the operator scope
  (`store/fleet_lane_postgres.go:55-58`), then `DiscussionStates(ctx, w1,
  topics)` (`store/issue_discussions.go:358`), which reads only w1's
  messages under w1's RLS (:350-355), so a topic it finds IS a w1 topic,
  then `canReadTopic(ctx, w1, task, hum)` (`hub/privacy.go:129`) and
  `FleetLaneIssues(ctx, w1, topics, nil)` (`store/fleet_lane_postgres.go:89`).
- **The gate today.** `GET /v1/operator/fleet-lanes` admits only
  `fleetLoadCaller` (`hub/fleet_load.go:120-139`): an admin of the
  operator workspace (`hub/operator_workspaces.go:99-106`) or the operator
  service account.
- **Who is "owner" and "admin".** `rbac.Access` (`rbac/rbac.go:207-212`):
  owner = `TenantOwner`, true when any role of the member's set is a tenant
  owner (the system role `biz_owner`, `rbac/rbac.go:68,153`); admin = the
  role id `admin` anywhere in the set, `Access.Has(rbac.Admin)`
  (`rbac/rbac.go:70,215`). The hub already gates on exactly that pair:
  `a.TenantOwner || a.Has(rbac.Admin)` (`hub/embed_staff.go:63`).
- **How the WUI decides today.** `monitoring.vue:51` passes
  `visibleMonitoringTabs({ operator: operator.visible, can })`;
  `operator.visible` is `operatorConsoleVisible` (`wui/utils/operator-console.mjs:63-64`,
  `wui/stores/operator-pane.ts:40`); an `operatorsOnly` tab needs it
  (`wui/utils/monitoring-tabs.mjs:34-37`). `normalizeMe`
  (`wui/utils/access.mjs:33-43`) keeps `role` (the primary one) and
  `tenantOwner` but drops `roles`, though `GET /v1/view/me` sends the
  whole set (`hub/rbac.go:96-100`): an admin whose primary role is not
  `admin` is not seen as one today.

The design:

- `GET /v1/view/lanes?fleet=<default main>`, a member session of
  workspace W. The gate: `TenantOwner || Has(rbac.Admin)` in W, else 403
  `forbidden`; the operator service account is refused here (it keeps
  3.3).
- The rows: the operator workspace's active lanes (3.2's rule, the same
  code path as 3.3, factored so both share it) whose `topic` is a topic of
  W that the caller may open (`DiscussionStates` + `canReadTopic` in W). A
  lane failing either is absent, never shown with a blank cell.
- The answer has 3.3's shape, so the page reuses its table, with three
  differences: `agent_box` is `""` (a fleet box name is the operator's);
  `issues` = W's issues that `issue_discussions` links to the topic, with
  their status; the lane's own key is left out (it is an operator
  workspace issue).
- Called in the operator workspace by its admin, the route answers the
  lanes on the operator's own topics; the WUI's operator path still reads
  3.3, which lists every lane.
- WUI: `normalizeMe` keeps `roles`; the Lanes tab row gets
  `operatorsOnly: false, staff: true`, and `visibleMonitoringTabs` draws a
  `staff` tab for an operator OR for `who.staff === true` (= `tenantOwner`
  or `roles` holds `admin`); `monitoring.vue` passes `staff`. The page
  reads 3.3 when `operator.visible`, else `/v1/view/lanes`. No new text
  key is planned (the tab, the columns and the empty line are B4's); a key
  B6 does add gets the agy review of the language rule.

### 3.7 A lane names the workspace it works for (v1.2, row B7)

Measured on prd 2026-10-26 10:08-10:12Z (`ENV=prd ./run -a
do_spl_db_query`, n = 1 read each, tree `a066b182e`). The lanes c-001
named as working for W are all rows of the operator workspace t1,
fleet `main`, state `live`, and all were active by 3.2's rule (a token-burn
minute 10:06-10:11Z):

| lane | row topic | why 3.6 lists it in W, or not |
|---|---|---|
| g-515, m-526, m-799 (seats) | `55fd7531-...`, a #development topic of W | listed: the seat briefs name the topic as a full uuid |
| c-425 (SPL-3501, W's site) | `""` | absent: its brief names the topic only as `topic 55fd7531.`, the 8-hex short id; the put resolved it among t1's topics only (`hub/box_lane.go:154-164` on `a066b182e`), found none and stored `""` |
| a-461 (SPL-3505, its Bulgarian reviewer) | `""` | absent: its brief names no topic at all |
| a-355 (SPL-3498) | `""` | absent, and rightly: rotation work, not W's |

The topic stays the one link between a lane and a workspace (no new
column, no human step): a lane works for the workspace that holds its
topic. Two gaps close:

- **Hub, at put.** An 8-hex short id that starts no topic of the writer's
  workspace is looked up in every other workspace (archived ones aside),
  each in its own scope, only when the writer is the operator workspace;
  exactly one match is stored as its full uuid, none or two store `""`.
  The operator's own topic still wins (C33). A customer box never resolves
  outside its own workspace (C34): it would learn another workspace's
  topic id. 19 workspaces on prd: at most 19 indexed reads per put, and a
  put is a spawn or a rotation, not a page view.
- **Orc, at spawn.** `_spawn_lane_put` takes, after the 3.4 sources, the 8
  hex of a line-start `Task: dispatch-<topic8>` line: a seat brief names
  its desk topic so (the dev-seat briefs of W), and the hub resolves
  it in the workspace that holds it. Prose that mentions a dispatch task,
  and a `dispatch-orc-<topic8>` relay task, set nothing (C36b).

Option (a), a workspace field set at spawn, was not taken: it needs a new
column, a CLI flag and every spawn caller to know the workspace, and a
caller can set it wrong; the topic is already in the brief and the hub
checks it against the workspace's own messages.

Isolation is 3.6's, unchanged: the workspace view shows the lane id, its
state, its one-line scope and W's own topic title and issues, never the
box, the lane's own (operator) key, another workspace's topic or text
(C31). The operator view of a lane on a workspace topic shows no title and
none of that workspace's issues: `DiscussionStates` reads the operator's
messages only (C35).

Not covered: a lane whose brief names no topic (a-461) stays tied to no
workspace; the brief has to name one. A row stored before B7 keeps its
`""` until its next put (a rotation keeps the old value).

### 3.8 Every row names its issue, its discussion and its workspace (v1.3, row B8)

The owner's rules, verbatim (HUM-10, t1 `f94e07bf`, 2026-10-27):

- msgs `77d5b3ab` + `33f8eecb`: "each lane must have at least 1 link to an
  issue WHAT It is doing and at least 1 link to a discusion from where did
  it originated".
- msg `67c63b8d`: "the lanes must have also to which workspace do they
  beong even if they are viewed from within that workspace - as their last
  right most column".
- csitea `a1ae72a7`, msg `80e92ffb`: "you stated that a new lane has been
  dedicated, but I cannot see any other lanes ... here": the lane promised
  was a queued ask, which no route listed.

Measured on prd 2026-10-27 10:28Z (`ENV=prd ./run -a do_spl_db_query`, the
3.2 active rule in SQL, n = 1 read, tree `2d74bdd49`): 38 active rows, 33
with topic `""`, 7 with issue key `""`, 33 missing either. 19 of the 33
are lanes of the box this was measured on; each one's task brief
(`<spool root>/<ID>/lifetime/brief.md`) was read: 15 name a topic by the
rule below (10 in a `topic` form, 5 only as a `dispatch-<topic8>` task),
4 name none. Why the 15 rows are blank:

- **A rotation blanks the topic.** The hourly rotation and a seat restart
  start the lane again through `spawn-window.sh` with a seed file as the
  brief ("you are c-NNN again ..."); `_spawn_lane_put` read the topic from
  that seed only, found none and put `""` over the row
  (`orc/run/spl-rotate-lib.func.sh` `spl_rotate_spawn`; the scope survives
  because `spl-lane-rotate.func.sh` passes it, the topic did not). Fix:
  `_spawn_lane_put` reads, after the brief, the lane's own task brief
  `$SPOOL_ROOT/<ID>/lifetime/brief.md` (C39).
- **A report task names the topic.** Most dispatcher lanes report on
  `dispatch-<topic8>`, written in prose ("Report on `--task
  dispatch-1be0e370`"). v1.2 took only a line-start `Task:`; v1.3 takes the
  first `dispatch-<topic8>` the brief names, as the last source, and the
  hub resolves the 8 hex as for every short id (3.4, 3.7). A
  `dispatch-orc-<topic8>` relay task still sets nothing (C36b, C38).
- **Queued asks are rows.** A spawn ask the placer holds
  (`fleet_asks.state = 'queued'`, role `orch`) is listed with state
  `queued`, after the live lanes: the scope is the ask's summary, the
  vendor its placement's, the time its `enqueued_at`. Its topic is the
  ask's `topic` when a full uuid, else the 8 hex of a `dispatch-<topic8>`
  topic resolved as a lane put resolves it (`laneTopic`); `gc-sat`,
  `dispatch-status-sweep` and the like name no topic. The wait reason is the
  ask's stored reason; the placer keeps its HOLD reason on its own box
  (`<asks dir>/.place.wait`, not in the hub), so the row says "waiting for
  room" (C40, C41).
- **Workspace column, last.** Every row on both routes carries
  `workspace` (id) and `workspace_name`: the workspace holding the row's
  topic, else the operator workspace, where the row lives. The workspace
  route (3.6) names W. The WUI shows it as the right-most column, also
  inside W and on a phone (the table scrolls sideways in its wrapper, 3.2;
  the column is never dropped) (C42, C43).
- **A lane with no issue or no topic** shows a dash, as before. The defect
  is upstream: a brief with neither an `Issue:` line nor a topic should be
  refused where it is queued (`do_spl_spawn_enqueue` already refuses one
  with no `Epic:` / `Spec:` line); that check is another lane's file and is
  named, not built, here. Role seats (c-001, c-002, c-003) carry neither
  by design.
- **Several topics.** A lane links to ONE topic: `fleet_lanes.topic` is one
  column. A lane whose brief names several owner topics shows the first;
  listing all needs a `topics` column (rdb, store, put, both views) and is
  left to its own row.
- **The topic page** has no lanes strip (`grep -il lane
  csi-spl-wui/src/pages/t/*.vue` -> none). The smallest addition: under
  the topic header, the rows of `GET /v1/view/lanes` whose `topic_id` is
  this topic, reusing the Lanes table row; not built in this row.

### 3.9 The agent card's tabs: the lanes this agent works on (row B9, SPL-4206)

The owner's words, verbatim (HUM-10, prd t1 `fb9b6e4b`, 2026-10-29):

- msg `78f2071b` (on Monitoring -> Agents, an agent's card open on the
  right): "we should see from tis view also different tabs per agent ...
  the first tab should be - one which lanes this agent is working on".
- msg `470ae116`: "and of course the links to those lanes tot refer to the
  lanes section o fthe monitoring".

What is built (`csi-spl-wui/src/pages/monitoring/agents/[id].vue`,
`csi-spl-wui/src/utils/agent-card-tabs.mjs`):

- **Tabs.** The card gets a tab row: **Lanes** first and the default, then
  **Details** (the card as it was: kind, box, last seen, Message). The open
  tab is in the URL, `?tab=details` (Lanes drops the key), so a link opens
  the right tab; an unknown value opens Lanes.
- **Which lanes.** The card reads the lanes as the Lanes page does (3.6:
  the fleet route for an operator admin, else, after its 403, the
  workspace's own) and keeps the rows whose agent id is this agent's and
  whose box is this agent's box (a row with no box matches the id). The
  hub's lane row carries no spawner or owner field (`fleet_lanes_view.go`
  sends agent, box, vendor, scope, topic, issues, times, state,
  workspace), so a role seat (orchestrator, dispatcher) lists only its own
  lane rows, never the lanes it placed: listing those needs a spawner
  column in the hub first, left to its own row. No lane: "This agent works
  on no active lane."; a reader the lanes routes refuse sees their 403
  sentence.
- **The link rule.** Each lane links to Monitoring -> Lanes at
  `/monitoring/lanes?lane=<id@box>`. That page marks the row whose
  `laneName` equals the value (`data-selected`, `aria-current`, the
  selected-row background) and scrolls it into view once it is in the
  answer; an unknown value marks nothing.
- **Text.** Four new keys under `agents.`: `tabs_label`, `tab_lanes`
  (the locale's `monitoring.tab.lanes` word), `tab_details`, `lanes_none`,
  in all 19 locales; agy reviews them (the language rule).
- **Proof.** Unit: `csi-spl-wui/tests/unit/monitoring-lanes.test.mjs`
  (the tab rule, the lane match, the link, the keys). e2e:
  `csi-spl-wui/tests/e2e/monitoring-takeover.test.mjs` section 5 (Lanes
  first, the agent's lane only, a click lands on Monitoring -> Lanes with
  that row selected and in view, an agent with no lane says so; 1400x900
  and 390x844).

### 3.10 The Topics tab: one row per topic, its lanes and issues (row B10, SPL-4421)

The owner's words, verbatim (HUM-10, t1 `08213e0e`, msg `8caf41ec`,
2026-10-30 17:07Z, with a screenshot of /monitoring/lanes): "we need a new
topics tab in the monitoring section , which will have the same narrow
listing like the lanes , but for topics , and outline the issues and lanes
per discussion /topic".

What is built:

- **The tab.** **Topics**, right after Lanes, at `/monitoring/topics`
  (`csi-spl-wui/src/utils/monitoring-tabs.mjs`), for the same readers as
  Lanes: an operator admin, a workspace's owner or admin (3.6). Anyone else
  sees no tab, and the direct URL shows the Lanes 403 sentence.
- **The data.** No new route. The page reads the Lanes answer (3.3 / 3.6,
  `readLanes`) and groups its rows by `topic_id`
  (`csi-spl-wui/src/utils/monitoring-topics.mjs`). The read, the minute
  poll, Refresh, the stale marker, the sort engine (`sortRowsBy`, factored
  out of `sortLanes` with no change to the Lanes order) and the links are
  `monitoring-lanes.mjs`'s, reused.
- **One row per topic**, narrow, one line: the title (linked to
  `/t/<uuid>` when the topic is this workspace's, as 3.2; else the id as
  text), the workspace, the channel (`#name`), the **last lane activity**,
  the lanes and the issues. Lanes on no topic share one "No discussion"
  row. Default order: newest lane activity first.
- **Last lane activity** is the newest token minute (`last_active`) or row
  write (`updated_at`) of the topic's lanes. It is lane activity, not the
  topic's last message: the hub sends no message time, and none is read.
- **Lanes** are `id@box` chips with the lane's state (Live / Queued), each
  linking to its row on Monitoring -> Lanes (`?lane=<id@box>`, 3.9).
- **Issues** are the topic's lanes' issues, each key once, as `SPL-n`
  chips with their status, linked to `/issues?issue=<KEY>` (a key with no
  status, another prefix, is text, as 3.2).
- **Sort and filter**, as the Lanes sheet: each column name sorts (▲, ▼,
  then the default order); the filter row keeps a topic when one of its
  lanes is on the box, of the vendor or in the state picked, by the age of
  its last lane activity, and by text (title, channel, workspace, lane ids,
  issue keys).
- **The channel field (hub).** Each lane row of
  `GET /v1/operator/fleet-lanes` and `GET /v1/view/lanes` carries
  `topic_channel`, filled from the same `DiscussionStates` read that fills
  `topic_title` (`fleetLaneLinks`), and only where the title is filled (the
  same door): `""` for another workspace's topic, a withheld title, a DM
  or no topic. No new route and no new query (GO: c-002, task
  `dispatch-08213e0e`, msg `321a1bee`).
- **Text.** One tab label `monitoring.tab.topics` and ten keys under
  `monitoring.topics.`, in all 19 locales; agy reviews them (the language
  rule). The page is its own chunk: nothing on the first screen imports
  `monitoring-topics.mjs`.
- **Proof.** Go: `csi-spl-api/src/go/spool-hub-api/internal/hub/lanes_topic_channel_test.go`.
  Unit: `csi-spl-wui/tests/unit/monitoring-topics.test.mjs`,
  `monitoring-tabs.test.mjs`. e2e: `csi-spl-wui/tests/e2e/monitoring-costs.test.mjs`
  (`topicsTab`, C3b with six tabs), 1400x900 and 390x844.

## 4. Cases

Every case is **planned**: none is built. "Master today" was read on
`848de71ef` (code) and prd on 2026-10-23 (data). Each red control is the
check that FAILS on master today and passes once its row lands; (C) marks
a control that must pass on both. A case whose master value is "n/a" (the
route does not exist yet) is a real control only with its "without the
rule" twin, named in its control column.

| # | row | case | master today | expected | red control |
|---|---|---|---|---|---|
| C1 | B1 | `/monitoring/agents`, desktop 1280 px: `[data-test=monitoring-tabs]` is inside the header | a sibling after it | inside, same row | e2e: `nav.closest('header')` is null today |
| C2 | B1 | the same page: left edge of the first tab label minus right edge of the heading text | the bar is on the next row | 20 px +-2, the two `top`s within 4 px | e2e: the two rects' `top`s differ by a row today |
| C2b | B1 | the same page: the active tab's rect `bottom` vs the header's rect `bottom` | the tab is below the header | equal +-1 px | e2e: today the tab's bottom is a row below |
| C3 | B1 | phone, 4 tabs (B1 lands before B4): narrow the viewport until the tabs overflow (320 px, the longest locale): heading and bar on one row, `scrollWidth <= innerWidth`, the h2's height is one line | two rows | one row, the bar scrolls inside itself | e2e: the same-row check fails today |
| C3b | B4 | C3 again with 5 tabs as an operator admin, 360 px | n/a | as C3 | the C3 e2e, run with the lanes tab |
| C4 | B1 | with `close_buttons: 'windows'`, the end close X is the last element of the header row on desktop | yes | yes (C) | e2e sets the claim, reads `[data-close-side=end]` as the header's last child (desktop only: no X on a phone). The default `'mac'` renders the start X only (`wui/utils/view-prefs.mjs:77-79`, `UiCloseButton.vue:18` `v-if="shown"`): twin C4b |
| C4b | B1 | the default `close_buttons: 'mac'`: the start X comes before the heading, no end X, the bar runs to the row's end | yes (start X first) | yes (C) | the same e2e with the default claim: `[data-close-side=start]` precedes the h2, `[data-close-side=end]` absent |
| C5 | B1 | `monitoring-costs.test.mjs` and `rail-order-default.test.mjs` find the bar by data-test | pass | pass (C) | the two files, unchanged |
| C6 | B2 | a dry-run spawn with `SPAWN_ISSUE=SPL-n` and a brief naming `topic:<uuid>`: the lane-map put line | `--topic ''`, no `--issue` | `--topic <uuid> --issue SPL-n` | `test-spawn-dry-run.sh` case greps the PLAN line |
| C6b | B2 | a brief carrying a spool task alias uuid and a `/t/<uuid>` topic | `--topic ''` | `--topic` = the `/t/` uuid, never the alias uuid | the same test, the alias uuid planted first in the file |
| C6c | B2 | the queue placer launches an ask whose topic is a full uuid | no `SPAWN_LANE_TOPIC` | `SPAWN_LANE_TOPIC=<uuid>` in the launch env | placer test with `SPAWN_PLACE_LAUNCH_CMD` recording its env (valid only because the value is set before the branch, 3.4); twin: an ask topic `dispatch-5e7b15c9` sets none |
| C7 | B2 | the brief names only an 8-hex short id | `--topic ''` | `--topic <8 hex>`, unchanged | the dry-run test greps the PLAN line |
| C7b | B3 | `lane_op put` with an 8-hex topic: one match, and two topics sharing the prefix | stored as sent | the full uuid; `''` for two matches | Go test, memory store and Postgres |
| C8 | - | `agent-id-retire.sh c-NNN` closes its lane row | yes (`agent-id-retire.sh:292-295`) | yes (C) | the retire test's `lane-map.sh done` step |
| C9 | B3 | `lane_op put` with `issue_key: "SPL-3075"`, then `list` | field dropped | returned | Go test on the memory store and on Postgres |
| C10 | B3 | `issue_key: "spl 1"` | n/a | refused, row unchanged | Go test; twin: `"SPL-1"` is stored |
| C11 | B3 | `GET /v1/operator/fleet-lanes` as an operator admin | no route | 200, active rows only | Go test: a `live` row 2 h old with no token burn for 2 h is absent |
| C11b | B3 | a `live` row 3 h old, `agent_box` `sat`, whose agent burned tokens 5 min ago under `box_tag` `sat` | no route | present | Go test on Postgres; twin: the same burn under another `box_tag` leaves the row absent |
| C12 | B3 | the same as a non-admin member of the operator workspace, and as an admin of another tenant | no route | 403 | Go test |
| C13 | B3 | a `BOX-0` row and an upper-case `CLE-77` row, both live and fresh | n/a | absent | Go test; twin: a fresh `c-077` row is present |
| C14 | B3 | a lane whose topic links SPL-1 and whose own key is SPL-2 | n/a | `issues` = SPL-1, SPL-2, each once | Go test; twin: a lane with SPL-1 as both lists it once |
| C14b | B3 | a lane whose topic belongs to tenant B | n/a | `topic_title ""`, `issues` = the lane's own key only, no tenant B data | Go test on Postgres; twin: the same topic in the operator tenant is titled |
| C15 | B4 | `MONITORING_TABS` ids | 4, no lanes | `[..., 'tokens', 'lanes']`, lanes `operatorsOnly` | `monitoring-tabs.test.mjs:25` order assertion |
| C16 | B4 | `visibleMonitoringTabs({ operator: false })` | no lanes | no lanes (C) | unit test |
| C17 | B4 | the Lanes page, a mock fleet of 3 lanes: a row's discussion link | page absent | `href` = `/t/<uuid>` | e2e on the mock bundle |
| C18 | B4 | a fake clock: the page fetches at 0 s and at 60 s, not at 30 s; none while hidden | n/a | as stated | unit test on the poll helper |
| C19 | B4 | i18n: `monitoring.tab.lanes` and the page keys in all 19 locales | missing | present; the `i18n-untranslated` and `i18n-no-raw-text` counts not raised | the two ratchet tests |
| C20 | B4 | initial JS budget (`ci_initial_gzip_kb`) | n/a | not raised: the page is its own chunk | `csi-spl-orc/src/bash/scripts/perf-budget.py` |
| C21 | B5a | `GET /v1/view/issues?discussion=<uuid of topic 5e7b15c9>` | no such filter | the issues linked to that topic only, SPL-3075 among them | Go test: an unlinked issue is absent |
| C21b | B5a | `?discussion=abc` | ignored | 400 `bad_request`, never 500 | Go test on Postgres (the memory store would not throw) |
| C22 | B5a | the filter with a topic of another tenant | n/a | empty list, never that tenant's issues | Go test; twin: the same link in the caller's tenant is listed |
| C23 | B5b | topic `/t/<uuid>` with a linked issue: a chip `SPL-n` to `/issues?issue=SPL-n`, with its `aria-label` | no chip | the chip | e2e on the mock bundle |
| C24 | B5b | a topic with no linked issue | no chip | no chip, no empty row (C) | e2e |
| C25 | B6 | two active operator lanes, one on a w1 topic, one on a w2 topic: `GET /v1/view/lanes` as an `admin` of w1 | no route | 200, the w1 lane only, `agent_box ""` | Go test on Postgres (RLS, tenant scope); twin: the same call as an admin of w2 lists the w2 lane only. Master today 404 on the route |
| C25b | B6 | C25 as w1's owner (`biz_owner`, no `admin` role), and as a member whose primary role is `developer` with `admin` as a second role | no route | both as C25 | Go test; twin: the same member without the `admin` role gets 403 (C26) |
| C26 | B6 | a plain member of w1 (`developer` only): the route, and the tab | no route; no tab | 403 `forbidden`; `visibleMonitoringTabs({ staff: false })` has no lanes | Go test + unit test; twin: `{ staff: true }` has lanes |
| C26b | B6 | `normalizeMe` on a me body with `roles: ['developer', 'admin']` | `roles` dropped, not staff | staff | unit test on `wui/utils/access.mjs` |
| C27 | B6 | an operator admin: `GET /v1/operator/fleet-lanes` still lists the w1 AND the w2 lane, with `agent_box` and the own keys; the WUI tab reads that route | as B3 | unchanged (C) | B3's `fleet_lanes_view_test.go` unchanged and green; WUI e2e on the mock bundle as an operator |
| C28 | B6 | an active lane with no topic, one on an operator topic | no route | neither in w1's view | Go test; twin: the same lane with the w1 topic's full uuid is listed. v1.1 also had a lane put with an 8-hex short id of a w1 topic, stored `""`; B7 reverses that (C28b) |
| C29 | B6 | a w1 lane whose own key is SPL-2 (operator) and whose topic links w1's issue 5 | no route | `issues` = w1's key for 5 with its status only; SPL-2 absent | Go test on Postgres; twin: the operator view of the same lane lists SPL-2 |
| C30 | B6 | a w1 lane on a w1 topic the calling admin may not open (`canReadTopic` false) | no route | absent | Go test; twin: a topic the caller may open is listed |
| C28b | B7 | an operator box puts a lane with the 8-hex short id of a w1 topic | stored `""` | stored as the w1 topic's full uuid | Go test on Postgres (`TestWorkspaceLanesShortID`) |
| C31 | B7 | C28b's lane: `GET /v1/view/lanes` as w1's admin, and as w2's | w1 empty | w1 lists it with w1's title, no box; w2 lists nothing; neither sees C32-C34's lanes | Go test on Postgres |
| C32 | B7 | the short id starts a w1 AND a w2 topic | `""` | `""` | Go test; red control: accepting more than one match stores one |
| C33 | B7 | the short id starts an operator AND a w1 topic | the operator's | the operator's | Go test |
| C34 | B7 | a box of workspace `other` puts the short id of a w2 topic | `""` | `""` | Go test; red control: no operator-only check stores w2's uuid |
| C35 | B7 | the operator view (3.3) of C28b's lane | n/a | listed, no w1 title or text | Go test; red control: titles read in every workspace leak `W1 build` |
| C36 | B7 | a brief whose only topic source is `Task: dispatch-55fd7531` | `--topic ''` | `--topic '55fd7531'` | dry-run test (`test-spawn-dry-run.sh`); twin C36b: `Task: dispatch-orc-...` and a longer word (`dispatch-55fd7531x`) give `--topic ''` (v1.3: prose `on task dispatch-...` now fills it, C38) |
| C37 | B7 | owner HUM-10, discussion `7e25d7ab`, msg `bd450d6a`: one person, a `regular_user` of the operator workspace and an `admin` of w1, with a w1 lane and a w2 lane active | 403 on both routes in the operator workspace; w1 lists its lane | unchanged (C): `GET /v1/operator/fleet-lanes` and `GET /v1/view/lanes` in the operator workspace 403; in w1 the w1 lane only | Go test `TestLanesAllWorkspacesOperatorAdminOnly`; red control: dropping the admin check in `operatorActor` lists both lanes; twin: the operator admin lists both |
| C38 | B8 | a brief whose only topic source is the prose report task `--task dispatch-1be0e370` | `--topic ''` | `--topic '1be0e370'` | dry-run test (`test-spawn-dry-run.sh`) |
| C39 | B8 | a rotation: the seed names no topic, `<spool root>/<ID>/lifetime/brief.md` names `topic <uuid>` | `--topic ''` | `--topic '<uuid>'` | dry-run test |
| C40 | B8 | an ask queued on `dispatch-<8 hex of a w1 topic>`: `GET /v1/view/lanes` as w1's admin | absent | a row, `state queued`, scope = the summary, `topic_id` = the w1 topic, `wait ""` | Go test (`TestLanesQueuedAsk`); twin: the same as w2's admin lists nothing |
| C41 | B8 | the same ask: `GET /v1/operator/fleet-lanes` | absent | a `queued` row after the live ones; an ask on `gc-sat` too, with no topic | Go test |
| C42 | B8 | a live lane on a w1 topic: the operator route | no workspace | `workspace` w1, `workspace_name` its name; a lane with no topic names the operator workspace | Go test |
| C43 | B8 | the Lanes table, operator and w1 admin | no column | the last `th` is the workspace column, every row's last cell its name; at 360 px the column is still in the DOM | WUI unit (`monitoring-lanes.test.mjs`, `fleetLanesOf` keeps the fields) + e2e |
| C44 | B8 | a `queued` row in the table | n/a | the agent cell says queued, the wait cell "waiting for room" when `wait` is empty | WUI unit + e2e |
| C45 | B10 | `MONITORING_TABS` ids, and who sees Topics | no topics | `[..., 'lanes', 'topics', 'file-streams']`; Topics shows exactly when Lanes does | `monitoring-tabs.test.mjs`; e2e C3b (six tabs for an operator admin); control: a plain member has neither |
| C46 | B10 | the Topics page on the mock fleet with a fourth lane on c-085's topic | page absent | 3 rows for 4 lanes, newest activity first; the shared topic lists c-085@box-a and c-733@box-a (Live), SPL-3075, SPL-3215 and SPL-4421 each once, `#monitoring`, its workspace, "1 min ago"; the no-topic lane in a "No discussion" row | e2e `topicsTab` on the mock bundle + unit `topicsOf`; control: another workspace's topic links nothing and shows no channel |
| C47 | B10 | initial JS budget | n/a | not raised: no Topics code in the initial download | e2e chunk check + `perf-budget.py` |
| C48 | B10 | `topic_channel` on both lanes routes | absent | the channel where the title is set; `""` for another workspace's topic and no topic | Go `TestLanesTopicChannel`; red on master (every channel `""`) |

## 5. Build rows

Disjoint files per row. B1 goes first and alone: it needs no data.

| row | area | files (only these) | after | cases |
|---|---|---|---|---|
| B1 tab row | wui | `wui/pages/monitoring.vue`; `wui/assets/css/main.css` (the `.monitoring-tabs` / `.monitoring-tab` rules at :1580-1584 with the scrollbar rule, one `.monitoring-page .feed-header h2` rule, one line in the phone block near :1003); the cases go into the existing `csi-spl-wui/tests/e2e/monitoring-costs.test.mjs` (a new e2e file moves the shard spread: if one is added, `node --test tests/unit/e2e-shard-pack.test.mjs` runs before the push) | - | C1-C5 |
| B3 hub view | rdb, api | a new `rdb/<next>_fleet_lanes_issue_key.sql` (3.4); `hub/box_lane.go`; new `hub/fleet_lanes_view.go` + `_test.go`; `store/fleet_lane.go`, `store/fleet_lane_postgres.go` and the memory store's fleet-lane methods; one line in `hub/server.go` (:487) | - | C7b, C9-C14b |
| B2 lane row data | orc | `orc/features/spawn-agents/scripts/lane-map.sh`, `spawn-core.inc.sh` (`_spawn_lane_put` only), `orc/run/spl-spawn-place.func.sh` (the launch at :547-552 only), the lane-put run action, their tests under `orc/features/spawn-agents/tests/` and the placer's test | B3 on master (the issue field, the short-id resolution) | C6-C7 |
| B4 Lanes tab | wui | `wui/utils/monitoring-tabs.mjs`; new `wui/pages/monitoring/lanes/index.vue`; new `wui/utils/monitoring-lanes.mjs`; the hub client's fleet-lanes call; `csi-spl-wui/i18n/locales/*.json` (new keys only); `csi-spl-wui/tests/unit/monitoring-tabs.test.mjs`; new `tests/unit/monitoring-lanes.test.mjs`; C17 and C3b in an existing monitoring e2e file (or a new one plus the shard-pack test) | B1, B3 | C3b, C15-C20 |
| B5a issues by discussion | api | `hub/issues.go` (the list filter only), its test; `store/issues.go` (one NEW interface method beside `ListIssues` at :392, which keeps its signature, and its memory store body) and `store/issues_postgres.go` (the new method only) | - | C21-C22 |
| B5b topic issue chips | wui | `wui/pages/t/[task_id].vue` (or its header component), new `wui/components/TopicIssueChips.vue`, its locale keys, its tests | B5a | C23-C24 |
| B6 workspace lanes (O1 = B, 3.6) | api, wui | `hub/fleet_lanes_view.go` (factor the active rule and the row fill out of `fleetLanesView`; 3.3's behaviour unchanged); new `hub/workspace_lanes_view.go` + `_test.go`; one line in `hub/server.go` beside `routeFleetLanes` (:488); `hub/openapi.json` (the new path); `wui/utils/access.mjs` (`normalizeMe` keeps `roles`) and its unit test; `wui/utils/monitoring-tabs.mjs` (the lanes row and the `staff` rule); `wui/pages/monitoring.vue` (pass `staff`); `wui/pages/monitoring/lanes/index.vue` (pick the route); the hub client's lanes call in `wui/utils/spool-client-lazy.mjs`; `csi-spl-wui/tests/unit/monitoring-tabs.test.mjs`; the B4 lanes e2e file (C27's operator case). No store, rdb or orc file | B2, B3 and B4 on master (B4 owns the tab row, the page and the client call that B6 changes) | C25-C30 |
| B7 workspace a lane works for (3.7) | api, orc | `hub/box_lane.go` (`laneTopic`, new `laneTopicElsewhere`); `hub/workspace_lanes_view_test.go`; `orc/features/spawn-agents/scripts/spawn-core.inc.sh` (`_spawn_lane_put` only); `orc/features/spawn-agents/tests/test-spawn-dry-run.sh`. No store, rdb or wui file, no new text key | B6 on master | C28b, C31-C37 |
| B8 rows complete (3.8) | orc, api, wui | `orc/features/spawn-agents/scripts/spawn-core.inc.sh` (`_spawn_lane_put`, new `_spawn_lane_topic`) and `test-spawn-dry-run.sh`; `hub/fleet_lanes_view.go`, `hub/workspace_lanes_view.go`, new `hub/lanes_queued.go` and their tests; `wui/pages/monitoring/lanes/index.vue`, `wui/utils/monitoring-lanes.mjs`, its unit test, the lanes e2e, `csi-spl-wui/i18n/locales/*.json` (new keys only, agy review). No rdb, no store, no placer file | B7 on master | C36b, C38-C44 |
| B10 Topics tab (3.10) | api, wui | `hub/fleet_lanes_view.go`, `hub/workspace_lanes_view.go` (`topic_channel` only), new `hub/lanes_topic_channel_test.go`, `hub/fleet_lanes_view_test.go` (the decoded field); `wui/utils/monitoring-tabs.mjs`; new `wui/pages/monitoring/topics/index.vue`, new `wui/utils/monitoring-topics.mjs`; `wui/utils/monitoring-lanes.mjs` (`sortRowsBy`, `uniqSorted`, `ageMatches` exported; `topicChannel`; the `topics` mock); `csi-spl-wui/i18n/locales/*.json` (new keys only, agy review); `tests/unit/monitoring-tabs.test.mjs`, new `tests/unit/monitoring-topics.test.mjs`; `tests/e2e/monitoring-costs.test.mjs`. No rdb, store or orc file | B9 on master | C45-C48 |
| B9 agent card tabs (3.9) | wui | `wui/pages/monitoring/agents/[id].vue`; new `wui/utils/agent-card-tabs.mjs`; `wui/utils/monitoring-lanes.mjs` (`agentLanes`, `laneDeepLink`, `readLanes`); `wui/pages/monitoring/lanes/index.vue` (the `?lane=` deep link); `csi-spl-wui/i18n/locales/*.json` (four new keys, agy review); `tests/unit/monitoring-lanes.test.mjs`; `tests/e2e/monitoring-takeover.test.mjs`. No hub, rdb or orc file | B8 on master | - |

Order: B1, B3 and B5a may run at once (B3's store interface is
`store/fleet_lane.go:65`, B5a's `store/issues.go:392`: different files); B2 after B3; B4 after B1 and B3;
B5b after B5a. B4 and B5b both add locale keys: they land one after the
other, and each ends with an agy review of its text (the language rule).
B6 after B2, B3 and B4, and after the v1.1 review.

## 6. Panel decisions

Seats: editor c-898@sat (claude), seat c-228 (second box) (claude,
msgs `a7c15b01`, `abea4bdc`), seat a-277 (second box) (agy, msg
`1c6e077e`). The mistral seat (m-039, second box) was voided after two
failed tries (c-002 msg `54ed5f39`). All three seats: P1-P6 no dissent.

| # | question | decision | reason | dissent |
|---|---|---|---|---|
| P1 | what is "active" | `live` AND a lane id AND (fleet-tokens `last_active` within 15 min OR `updated_at` within 60 min), joined on `agent_id` + `box_tag = agent_box`; the row field is `last_active`, not `online` | lanes are often not in the roster (`spl-lane-issue.func.sh:164-166`), so presence reads false; the token burn is already a per-agent heartbeat every 30 s behind the same gate (2.2); the join matches in prd (25 of 27 active rows by burn, 3.2) | none |
| P2 | the 172 stale `live` rows | the view's cut-off hides them; no close action, no prd write | all last written on or before 2026-10-14 (2.2); retire already runs `lane-map.sh done` (`agent-id-retire.sh:292-295`) | none |
| P3 | issue keys on the lane row | yes, as well as through the discussion | the view already computes them, and the lane's own issue is often not linked to the row's topic | none |
| P4 | poll or push | poll every 60 s | it matches Tokens and needs no socket change; the claude seat believes, unchecked, that no fleet-lane frame exists on the WUI socket | none |
| P5 | the phone | one row, 12 px after the heading, the bar scrolls inside itself with no scrollbar shown | no end X on a phone (`SectionClose.vue:9`); the h2 rule of 3.1 keeps the heading whole | none |
| P6 | does Reporting T053 reuse B3's view | no, it keeps its own history query | spec 143:720 names `fleet_asks`, `box_beats` and registry logs; `fleet_lanes` keeps a `done` row only 7 days | none |

## 7. Owner questions

Only the owner can answer these. The dispatcher posts them after v1.0.
The build does not wait on O1: v1.0 builds (A), the safe side (3.2), and
(B) would be its own later row. The agy seat recommends (A): lane rows
name fleet boxes, branches and agent ids, and (B) needs cross-tenant
filtering out of this spec's scope. The claude seats raised no
dissent on (A) as the default.

```poll
O1. Who may see the Monitoring Lanes tab?
(A) Operator admins only, like the Tokens tab
(B) Also each workspace's admins, for the lanes working on that workspace's own topics only
```

**O1 answered: B** (v1.1). Owner HUM-10, in the topic above:

| msg | text |
|---|---|
| `4982c60e` (poll `a063c1ac`) | "Answer: B — Also each workspace's admins, for the lanes working on that workspace's own topics only" |
| `1b07dd26` | "O1. Who may see the Monitoring Lanes tab? Actually, both the business owners and admins can see them." |

So: an operator admin sees every lane (3.3, as built); each workspace's
owners (`TenantOwner`) and admins (`admin`) see only the lanes working on
that workspace's own topics (3.6, row B6). B1-B5 are unchanged.

## 8. Panel record

| when (UTC) | who | what |
|---|---|---|
| 2026-10-23 15:26 | c-898@sat | v0.1 landed, `20b5d6eae` |
| 2026-10-23 17:07 | c-898@sat | panel sha `20b5d6eae` and editor findings 1-3 to the claude seat (msg `5a638be8`) |
| 2026-10-23 17:10 | c-228 (second box) | claude seat findings (msg `a7c15b01`): 33 rows checked; gaps folded in as 2.1 h2, 3.1 underline, 3.3 one tenant, 3.4 sources and dry run, 3.5 400, C2b, C3/C3b, C6b, C6c, C7b, C11b, C14b, C21b, B1 shard note, B3 `<next>` and `server.go` |
| 2026-10-23 17:2x | c-228 (second box) | re-check of v0.2 (msg `abea4bdc`): 8 rows; folded in as the placer seam (:547-552, set once before the branch), the C6c alias twin, the burn join key with its prd measure (2.2, 3.2, C11b), B5a's store files; P1-P6 and O1 no dissent |
| 2026-10-23 22:38 | c-898@sat | panel sha `35a7f08fd` confirmed to the agy seat a-277 (second box) (msg `9960aade`) |
| 2026-10-23 22:42 | a-277 (second box) | agy seat findings (msg `1c6e077e`), checked on `369b25d5f`: 12 rows, 7 OK; folded in as 3.1 first-tab padding kept and no scrollbar, 3.2 long cells and table wrap (the cited lines corrected to `0096:22` and `token-burn.css:5`), 3.2 text reuse, 3.4 `0214` landed, 3.5 chip `aria-label`, C4 under `'windows'` plus C4b, 3.5 and B5a `ListIssues` kept (20 callers by the editor's count; the seat said 23); P1-P6 no dissent; O1 recommends (A) |
| 2026-10-23 22:4x | a-277 (second box) | signs `a60967dab` (msg `9305635a`), no dissent |
| 2026-10-23 22:4x | c-228 (second box) | signs `a60967dab` with dissent D1 (msg `f6fc3588`): 3.1 gave the bar both a 20 px and an 8 px margin, and the phone's 12 px was ambiguous; fixed in 3.1 (bar margin 8 px, label at 20 px; phone: label at 12 px, nav margin 0). Also folded: the he and tr forms in 3.2 |
| 2026-10-23 22:5x | c-898@sat | D1 fix landed `5a8621a23`; re-sign asks to both seats (msgs `4c458805`, `efdf7279`) |
| 2026-10-23 22:5x | c-228, a-277 (second box) | both sign `5a8621a23`, no dissent (msgs `0ed0fbf6`, `9f5cd2dd`). Panel closed |
| 2026-10-23 22:54 | c-002@sat | ACCEPTED the panel result on `0b4e55c9f` (msg `64bc4a7e`); O1 goes to the owner, the build rows get placed |
| 2026-10-24 | c-995@sat (claude) | v1.1, SPL-3210: O1 = B recorded (section 7), 3.2 changed, 3.6, C25-C30 and B6 added; code read on `0073343c2`; no prd read. One cross-vendor review of v1.1 to follow |
| 2026-10-26 | c-283@sat (claude) | v1.2, SPL-3514: 3.7, C28b, C31-C36 and B7 added, C28 narrowed; code read on `a066b182e`; prd read 10:08-10:12Z (3.7). One cross-vendor review (R7) before B7 lands |
| 2026-10-26 | c-283@sat (claude) | v1.2, SPL-3514: C37 added (owner msg `bd450d6a`: only the operator admin sees every workspace's lanes); master already holds it, the test pins it |

Editor findings folded in: retire already closes the lane row (C8 is a (C)
control, no build); the stale-row data of 2.2 (P2); the migration number is
not pinned (3.4).

## 9. Signatures

v1.0 is signed by each seat's own message; the editor records each
message id here after it arrives.

| seat | on `a60967dab` | on the D1 text fix `5a8621a23` |
|---|---|---|
| editor c-898@sat (claude) | the v1.0 commit | the D1 fix commit |
| c-228 (second box) (claude) | `f6fc3588`, dissent D1 | `0ed0fbf6`, no dissent, D1 resolved |
| a-277 (second box) (agy) | `9305635a`, no dissent | `9f5cd2dd`, no dissent |
