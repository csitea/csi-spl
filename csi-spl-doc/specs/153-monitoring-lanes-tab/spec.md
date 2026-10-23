# 153 Monitoring: the tab row beside the heading, and a live Lanes tab

Version v1.0 (2026-10-23), the panel result, with the claude seat's D1
text fix (section 8). Step 2 of the owner rule for a
big change: the written spec, then the panel, then the build. v0.1
(`20b5d6eae`) plus the editor's findings, the claude seat's findings and
re-check, and the agy seat's findings (section 8). Signed by each seat's
own message on this sha (section 9). Nothing in it is built.

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
- Who sees it: operator admins only (`operatorsOnly: true`), like Tokens:
  lane rows name fleet boxes, agents and the operator workspace's topics.
  The hub's 403 is the control; hiding the tab is only the UI. Owner
  question O1.

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

Order: B1, B3 and B5a may run at once (B3's store interface is
`store/fleet_lane.go:65`, B5a's `store/issues.go:392`: different files); B2 after B3; B4 after B1 and B3;
B5b after B5a. B4 and B5b both add locale keys: they land one after the
other, and each ends with an agy review of its text (the language rule).

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

Editor findings folded in: retire already closes the lane row (C8 is a (C)
control, no build); the stale-row data of 2.2 (P2); the migration number is
not pinned (3.4).

## 9. Signatures

v1.0 is signed by each seat's own message; the editor records each
message id here after it arrives.

| seat | on `a60967dab` | on the D1 text fix |
|---|---|---|
| editor c-898@sat (claude) | the v1.0 commit | the D1 fix commit |
| c-228 (second box) (claude) | `f6fc3588`, dissent D1 | pending |
| a-277 (second box) (agy) | `9305635a`, no dissent | pending |
