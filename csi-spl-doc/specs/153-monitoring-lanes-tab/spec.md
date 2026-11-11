# 153 Monitoring: the tab row beside the heading, and a live Lanes tab

Addendum (2026-11-10, SPL-5080): section 3.24 (a put that resends the topic
its row already stores keeps it, so a lane whose discussion is a version-5
topic of the operator's own workspace can be closed), cases C129-C132. A bug
fix on 3.21, placed as one lane brief, not a panel version.

Addendum (2026-11-07, SPL-5007): section 3.23 (a launch that crosses boxes
carries the lane row's topic, scope and files; the ok reply reports a refused
row), cases C127-C128. A bug fix on 3.21, placed as one lane brief, not a panel
version.

Addendum (2026-11-07, SPL-4940): section 3.22 (a Queue tab next to Lanes:
requests and plans, a priority on a request, a plan or a lane, a request
dragged to an exact position, what priority does to resources, and a measured
view of why throughput changes), cases C102-C126, rows Q1-Q12. Owner HUM-10,
t1 topics `c1400bbb` and `906c1b28`. Placed by the dispatch holder as one lane
brief, not a panel version. Design only: none of it is built. The owner answered
O2 and O3 (section 7): A and A.

Addendum (2026-11-04, SPL-4798): section 3.19 (a lane row's discussion,
issue and `dispatch-<topic8>` task render as links on their workspace's
host, through the one `type:id` renderer), cases C88-C89. Owner HUM-10, t1
topic `0c2d08a2`, msgs `e7009f10` and `ea369ab0`. Placed by the dispatch
holder as one lane brief, not a panel version.

Addendum (2026-11-04, SPL-4810): section 3.20 (a lane opens in a dialog
from the Lanes table; its Console button shows the lane's live tmux screen,
masked on the box, and Save writes it to a local file), cases C90-C94, L1-L4,
W1-W2, in [lane-console.md](lane-console.md). Owner HUM-10, t1 topic
`27162335`, msgs `038fa412`, `8dd53bd9` and `3b2ba6f3`. Placed by the
dispatch holder as one lane brief, not a panel version.

Addendum (2026-11-04, SPL-4778): section 3.17 (a workspace's own boxes,
such as a box joined to it, show their lanes and their announced agents on
the workspace's Lanes tab and in the operator's, keyed by agent@box),
cases C71-C81. Owner
HUM-10, t1 topic `dc2d6c40`. Placed by the dispatch holder as one lane
brief, not a panel version.

Addendum (2026-11-04, SPL-4797): section 3.20 (every new lane is written
with its discussion and its issue, the placer refuses one that names
neither, a 15-minute check reports the gaps; `unknown` is plain text),
cases C90-C97. Owner HUM-10, t1 topic `0c2d08a2`, msgs `e7009f10`,
`08ac07da`, `937e89a4`. Placed by the dispatch holder as lane (a) of three:
(b) the renderer, (c) the NOT NULL migration.

Addendum (2026-11-03, SPL-4729): section 3.15 (the Lanes list's sort and
filters live in its URL, so the link can be shared), cases C64-C67. Owner
HUM-10, t1 topic `0a730c21`, msg `ea87c5c1`. Placed by the dispatch holder
as one lane brief, not a panel version.

Addendum (2026-11-03, SPL-4727): section 3.14 (every lane row carries its
prio, the highest among its issues, as the 3rd column, sortable), cases
C61-C63. Owner HUM-10, t1 topic `0d0bc34c`, msgs `136f2e49` and
`c78812f2`. Placed by the dispatch holder as one lane brief, not a panel
version.

Addendum (2026-11-03, SPL-4730): section 3.16 (Refresh, its age and Clear
filters on the tabs' row, on the right, on Lanes, Topics and Tokens), cases
C68-C70. Owner HUM-10, t1 topic `3238db2c`, msg `2dd25d62`. Placed by the
dispatch holder as one lane brief, not a panel version.

Addendum (2026-11-03, SPL-4705): section 3.13 (a lane on a
`dispatch-<topic8>` task names the workspace of that topic; a Workspace
filter), cases C58-C60. Owner HUM-10, t1 topic
`0ea86216`, msg `aa56f0b5`. Placed by the dispatch holder as one lane
brief, not a panel version.

Addendum (2026-11-02, SPL-4620): section 3.12 (a lane row names the issue
it came from, a dispatch task and its relay hash resolve to the discussion),
cases C54-C57. Owner HUM-10, t1 topic `4e9f7153`, msg `9a89d1e1`. Placed by
the dispatch holder as one lane brief, not a panel version.

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
- SPL-4811 (owner HUM-10, t1 c7c44497, msg 416d130f: "the tabs must be in
  the same row as the "Reporting" - which should be Bold and 1px bigger
  font than "space space >> space space" than the tabs with their current
  size"): Monitoring and Reporting read `<title>  >>  <tabs>` on one row.
  - Between the `<h2 class="section-title">` and the bar, a
    `<span class="section-title-sep" aria-hidden="true">` holding the text
    `"  >>  "`, drawn with `white-space: pre` so both pairs of spaces show,
    muted, hidden from screen readers. The header's 12 px gap is cancelled
    on both sides of it (the separator's and the bar's
    `margin-inline-start: -12px`), so its spaces are the whole distance; the
    first label sits the first tab's border and padding (12 px) after it.
  - One rule in `main.css` sizes both pages: `--section-tab-fs` on
    `.monitoring-page, .reporting-page` (1rem on a desktop, 0.8rem at
    `max-width: 820px`, the sizes the tabs had before) sets the tabs and the
    separator; `h2.section-title` is `calc(var(--section-tab-fs) + 1px)`,
    weight 700.
  - Phone: the title and the separator are not drawn (CLE-77886, a section
    page shows no title); the bar is the row and scrolls inside itself.
  - Tests: `csi-spl-wui/tests/e2e/reporting.test.mjs` T1-T5 (both pages,
    1440, 390 and 320 px), and C2 here (the separator right after the
    heading, the first label 12 px +-2 after the separator).

### 3.2 The Lanes tab (A2)

- A fifth row in `MONITORING_TABS`, after tokens: `{ id: 'lanes', path:
  '/monitoring/lanes', labelKey: 'monitoring.tab.lanes', operatorsOnly:
  true, ready: true }`.
- Page `wui/pages/monitoring/lanes/index.vue`, its own chunk.
- One row per ACTIVE lane: agent `id@box`, vendor, the scope (the brief's
  title), the discussion (topic title, linked), the issue key(s) (linked),
  the time since the row was written, and the last token activity.
- Box (SPL-4458; owner HUM-10, t1 `0acd4eaa`, msg `97453531`: "the lanes
  should get also a box attribute on the listing - aka on which box the
  lane is working"): the box is its own column right after the agent,
  header `monitoring.lanes.col_box` (each locale's `filter_box` word),
  sortable like the others, the box select of the filter row under it,
  one line on a phone too. The operator route always sends it:
  `fleet_lanes.agent_box` is `NOT NULL` with a name check
  (`rdb/0096_fleet_lanes.sql:19`); prd 2026-10-31, n = 2143 rows, 0
  without a box. The workspace route (3.6) blanks it on purpose, so there
  the cell is a dash; a queued ask (3.8) has no box yet.
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
  `wui/components/monitoring/token-burn/token-burn.css:5`). On a phone
  (<= 820 px) the rows are dense cards instead, nothing scrolls sideways
  (3.25). An empty
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
  inside W and on a phone (on its card's third line, 3.25; the column is
  never dropped) (C42, C43).
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

### 3.11 No empty discussion or issue cell without a reason (SPL-4457)

The owner's words, verbatim (HUM-10, prd t1 `0acd4eaa`, msg `69522885`,
2026-10-30T23:33Z): "the registration of the lanes should improve - chk
https://spool-hub.ai/monitoring/lanes there are still lanes without proper
links fo rthe discussions and empty discussions or issues values".

Measured on prd 2026-10-31 00:20Z (`ENV=prd ./run -a do_spl_db_query`,
csi-spl-orc; the 3.2 active rule in SQL; n = 1 read; tree `4cd5b29d2`):
39 active rows (t1, fleet `main`), 30 with a topic, 36 with an issue key.

| class | rows | why the cell is empty or not a link | fix |
|---|---|---|---|
| role seat | 3 (c-001, c-002, c-003) | no topic and no issue by design | the row carries `role_seat`; the page says "Role seat" in both cells (C51) |
| the topic is another workspace's | 10 (csitea 9, one customer workspace 1) | the title is read in the operator workspace only, so the cell shows the uuid as text, no link (3.3) | not in this row: a cross-workspace link needs the target workspace's host (`tenantHostUrl`); named for its own row |
| no topic, the issue links one | 1 (c-131: SPL-4438 links `021d4921`) | the brief named the topic in no form the spawn path reads | the view takes the first discussion the lane's own issue links, never the tenant's default one (C50) |
| no topic, the brief names only its report task's uuid | 1 (c-749: on task `e15a3002-...`) | `_spawn_lane_topic` reads no bare uuid; and this one is a version-5 uuid, `uuid5(NAMESPACE_URL, "spool-task:dispatch-lease-gate-cross-box")` (`spool-fleet-relay.sh`), a relay task's hash of its name, not a discussion (R7 c-287 W1) | the spawn path reads `task `<uuid>`` / `--task <uuid>` as the last source only when the uuid is not version 5 (C52, C52d); c-749's row is left to the issue fallback (C50) |
| no topic anywhere | 4 (c-739, c-145, c-097: refactor round 17 rows, report task `dispatch-r42`; c-988: an R7 seat) | the brief names no discussion (read for c-739; the other three are the second box's, not read from this one, classed by their scope), and the issue links only the default one (`fcf09921`, which 2823 t1 issues link; read for all four) | upstream: `do_spl_spawn_enqueue` should refuse a brief with no topic, as it refuses one with no `Epic:`; that file is another lane's, named here, not built |

Queued asks (3.8): 32 on prd, none with `issue_key`, and the page never
shows them: `fleetLanesOf` drops a row with no `agent_id`, and a queued
row has none. Named for its own row, not built here.

What changes:

- **Hub** (`hub/lanes_registration.go`): `laneTopicsFromIssues` fills the
  topic of an active lane with none from `IssueDiscussionLinks` of its own
  key (the tenant's prefix only), skipping `store.IssueDiscussionDefault`;
  `laneIsRoleSeat` (`agentid.IsRoleSeat`, or the role rotation's exact
  scope shape `^role [acgmq]-[0-9]{3} \(rotation `) sets `role_seat` on the
  row; a lane whose brief heading merely starts with "role " is no seat
  (R7 c-287 W2). Both routes
  (3.3, 3.6) share it through `activeFleetLanes`.
- **Spawn path** (`_spawn_lane_topic`, spawn-core.inc.sh): after the
  `dispatch-<topic8>` task, the full uuid of the first report task the
  brief names, never a version-5 one: that is the hash a relay makes of a
  task name (`spool-fleet-relay.sh`, `uuid5 "spool-task:<name>"`), not a
  hub topic. Measured by R7 c-287 over every brief (n = 2985 briefs on one box, 4678
  on the other, tree `5a5a1b955`): of the readings the fallback changed, 356 of
  429 and 449 of 632 were version 5. A bare uuid still sets
  nothing (C6b, C52c).
- **Page** (`pages/monitoring/lanes/index.vue`): a role seat's empty topic
  and issue cells read `monitoring.lanes.role_seat`; a lane's still read a
  dash. One key, 19 locales (agy reviews them, the language rule).
- **Backfill** (`cd csi-spl-orc && ./run -a do_spl_lane_backfill_links`,
  a dry run unless `DRY_RUN=0`): this box's live rows with no topic or no
  issue, role seats and rows whose agent has no pane on this box aside
  (a write would bump `updated_at` and bring a dead lane back onto the
  page, the 3.2 rule; 105 such rows on one box, 2026-10-31 05:30Z, n = 1),
  filled from `<spool root>/<ID>/lifetime/brief.md`
  and `lifetime/issue`; prints each row before and after and the counts,
  and writes a filled row with its other fields kept. It runs per box: the
  briefs live on the box that started the lane.

Cases:

- **C50** an active lane with no topic whose own issue links a topic shows
  that topic, titled; **C50b** one whose issue links only the default
  discussion, or a key of another prefix, shows none; **C50c** a stored
  topic is kept. (`hub/lanes_registration_test.go`)
- **C51** c-001, g-002 and a row with scope `role <id> (rotation ...)` carry
  `role_seat`; a lane does not, nor one whose scope is "role seats: ..."; the page shows the key in the topic and
  issues cells. (same file; `tests/unit/monitoring-lanes.test.mjs`)
- **C52** a brief naming its report task as `on task `<uuid>`` or
  `--task <uuid>` puts that uuid as the topic; **C52c** a bare uuid puts
  none; **C52d** a version-5 task uuid puts none.
  (`spawn-agents/tests/test-spawn-dry-run.sh`)
- **C53** the backfill: dry run lists and writes nothing; `DRY_RUN=0`
  writes only the filled rows, every other field kept; a role seat, another
  box's row, a done row, a complete row and a row with no pane are left out.
  (`csi-spl-orc/src/bash/tests/lane-backfill-links.tst.sh`)

### 3.12 Every new lane links the discussion and the issue it came from (SPL-4620)

The owner's words, verbatim (HUM-10, t1 `4e9f7153`, msg `9a89d1e1`): "Once a
lane is created it it should add a link to both the discussions from where it
originated and to the issue from where it originated ..".

Measured on prd 2026-11-02 (`ENV=prd ./run -a do_spl_db_query`, csi-spl-orc;
t1, fleet `main`, role seats aside, rows written in the last 7 days; n = 1
read; tree `06c1fa804`): 1703 rows, 546 with a discussion, none with an origin
issue, because no column held one. Rows written since 2026-11-01 (after the 3.11
fix), each row's brief read on the box that started it (one box only, the other
box's 76 rows, 47 with a discussion, were not classed):

| class, n = 103 rows of that box | rows | discussion | what this section does |
|---|---|---|---|
| the brief names a topic | 36 | yes | nothing |
| the report task is a relay hash of `dispatch-<topic8>` | 7 | no | the hub resolves it |
| the report task is a relay hash of another name (`dispatch-r47`) | 31 | no | none exists: shows nothing |
| the report task is a name (`dispatch-r47`) | 28 | no | none exists: shows nothing |
| no brief left on the box | 1 | no | nothing |

Origin issue, the same 103 rows, by the rule below: 50 placed on an existing
issue, 53 name none and show nothing until their placer writes the line. Over
the 7 days, of 193 lanes whose brief names only a relay hash, 92 hash a real
`dispatch-<topic8>`.

What changes:

- **The column.** `fleet_lanes.origin_issue` (rdb 0253), next to `issue_key`,
  which stays the lane's own issue. No closed lane is backfilled.
- **Which issue**, the placer's words only (`li_origin_from_brief`,
  `lane-issue.inc.sh`): a brief line `Origin-Issue: <KEY>`; else `row N of
  <KEY>` or `review of <KEY>` in the brief's heading; else the existing issue the
  lane is placed on (an `Issue:` line or `SPAWN_ISSUE`). Never an epic, a key in
  the body or a key the lane files itself. `do_spl_lane_issue` writes it once to
  `lifetime/origin-issue`, because a rotation's brief carries the filed key too.
- **Which discussion.** An ask's `dispatch-<topic8>` topic launches with its 8
  hex, which the hub resolves as any short id (it set nothing before). Last
  source, a report task's relay hash: the hub stores the topic whose
  `dispatch-<topic8>` hashes to it (`laneTopicOfRelayHash`, one scan of the
  tenant's topics, 111 ms on prd, only on such a put), and nothing for any other
  hash or for two matches, so a lane's topic is still never a relay task's hash
  (3.11). `_spawn_lane_topic` is unchanged.
- **The page.** A column after Issues, `monitoring.lanes.col_origin_issue`, in
  all 19 locales, linked as 3.2 links an issue; another prefix is text; none
  leaves the cell empty, not a dash: nothing was lost. The workspace route (3.6)
  sends none: it numbers operator issues.
- **The issue.** Both links under the card's `## Source` (spec 135 7.1). A lane
  placed on an existing issue adds what its `## Source` lacks; an issue is no
  origin of itself. Not built: a lane whose only discussion source is a relay
  hash has that discussion on its row, not in its issue, whose Source is read
  before the lane's put.

Cases:

- **C54** a put carries `origin_issue` next to `issue_key`; none stores none; a
  bad key is refused. **C55** the view sends it with its status, absent for
  none, a key of another prefix with no status.
  (`hub/lanes_origin_test.go`)
- **C56** a short id and the relay hash of `dispatch-<topic8>` both store the
  full uuid; **C56b** the hash of any other name stores nothing; **C56c** a
  full topic uuid stays. (same file)
- **C57** the Origin cell links; another prefix is text; none is empty.
  (`tests/unit/monitoring-lanes.test.mjs`, `tests/e2e/monitoring-costs.test.mjs`)
- The brief rule, the card and a placed key's description:
  `csi-spl-orc/src/bash/tests/spl-lane-issue.tst.sh`; the put, done keeping it,
  and a box binary without the flag: `lane-map.tst.sh`; the ask's topic:
  `spl-spawn-queue.tst.sh`; the hash as last source: `test-spawn-dry-run.sh` C52d.

### 3.13 The workspace a lane works for, in sight (SPL-4705)

The owner, verbatim (HUM-10, t1 `0ea86216`, msg `aa56f0b5`, 2026-11-03
12:02Z): "we must have the workspace attribute in the lanes listing for hte
spool-hub https://spool-hub.ai/monitoring/lanes".

The column existed (3.8), last. Two gaps kept it out of sight or wrong:

- **A live lane on a `dispatch-<topic8>` task.** A put stores a bare 8-hex
  short id as the full uuid (3.7), but a topic sent as the task id
  `dispatch-<topic8>` is stored as sent; `laneWorkspaces` reads full uuids
  only, so the row fell back to the operator workspace. The view now
  resolves such a topic as a queued ask's (`askTopic` -> `laneTopic`): the
  operator's topic first, else the one topic of another non-archived
  workspace, else none (two topics with that prefix: none, never a guess).
  The row's `topic_id` becomes that uuid; another workspace's title stays
  withheld (3.3), only its workspace name shows
  (`laneDispatchTopics`, `hub/lanes_queued.go`). Queued asks already
  resolved this way (C40). Measured on prd 2026-11-03
  (`lane-map.sh list --all --json`, n = 1179 rows): of the live rows 34
  have a full uuid, 227 none and 1 a `dispatch-<8 hex>-build` topic (not
  this form): no live row on prd was in this form that day; this closes
  the gap for a put that sends the task id.
- **The column stays last.** The brief for this message moved it after
  Box; the dispatch holder dropped that (msg `e7b7da32`): the owner's own
  words in 3.8 (msg `67c63b8d`, "as their last right most column") stand,
  and `aa56f0b5` says nothing on position.
- **A Workspace filter** (owner HUM-10, t1 `0ea86216`, poll `33a36dde`,
  msg `c50a260f`: "C — I want to filter the list by workspace"). A select
  in the filter row under the Workspace column, beside box, vendor, state
  and age: "All", then each workspace of the answer once, by name (the id
  when it has none), sorted by name; it matches the row's workspace id, so
  two workspaces of one name stay apart. It combines with the other
  filters and Clear filters resets it (`LANES_NO_FILTER.workspace`,
  `laneFilterChoices().workspace`, `filterLanes`). No new text key: it is
  labelled by the column's name, as the box select is.

Cases:

- **C58** a live lane and a queued ask on `dispatch-<8 hex of a csitea
  topic>`: the operator route names workspace csitea and its name, the
  topic's uuid, no title. **C59** the 8 hex starts a topic in two other
  workspaces: the operator workspace, no topic. (`hub/lanes_workspace_resolve_test.go`,
  memory and Postgres; red on master `3da4fa390`: the live lane names the
  operator workspace.)
- **C60** the Workspace filter: one workspace's lanes by id (a name
  matches nothing), combined with vendor; the choices once each, by name,
  sorted; the select is the last filter cell and the column stays last.
  (`tests/unit/monitoring-lanes-sort-filter.test.mjs` "the Workspace
  filter", red on master: 5 fail; `tests/e2e/monitoring-costs.test.mjs`
  `lanesSortFilter` on the mock fleet's two workspaces.)

### 3.14 Every lane shows its prio, 3rd, and sorts by it (SPL-4727)

The owner, verbatim (HUM-10, t1 `0d0bc34c`, msg `136f2e49`): "also the
lanes must have their prio attributes in the lanes hilisting and it should
be possible to sort them by prio"; msg `c78812f2`: "the prio shoud be the
3rd attribute".

The rule (the dispatch holder's reading, the lane brief):

- **A lane's prio is the prio of its issue.** A lane lists several issues
  (its own key and every issue its topic links, 3.3; a spec 169 lane lists
  7 or more): it shows the highest among them, prio 1 the highest. The
  origin issue (3.12) is where the lane came from, not its work: it does
  not count. A key of another prefix has no issue the hub can read, so no
  prio. A lane with no issue, or with none that has a prio, shows a dash.
  A role seat (3.11) names no issue, so it shows a dash, as today.
- **The hub sends it, in the read it already makes.** `FleetLaneIssues`
  (`store/fleet_lane.go`, both drivers) returns each issue's status AND
  `priority` (rdb 0055: 1..5, 0 read as the default 5) from the same one
  query; both routes (`GET /v1/operator/fleet-lanes`, `GET /v1/view/lanes`)
  send `priority` on every issue and on the row (`lanePrio`,
  `hub/fleet_lanes_view.go`), omitted when none. One issue read per GET
  whatever the row count (C62).
- **The table.** The columns read Agent, Box, Prio, then the rest
  (`LANE_COLUMNS`); the filter row gets an empty cell under Prio. The cell
  is the number in the Issues sheet's colours, a dash for none; the name is
  the Issues sheet's word (`issues.field_priority`), so no new text key and
  no language review. The phone keeps the prio first on each card's first
  line (3.25).
- **The sort.** The name is the sheet's sort button (`cycleSort`,
  `sortLanes`, sort key `priority`): ascending = prio 1 first, descending =
  5 first, a lane with no prio last both ways, ties in the hub's order. No
  sort is still the hub's order (newest write first): the default is
  unchanged. The page keeps no stored sort choice today; the URL state of
  the sort is SPL-4729's, which carries this key like the others.
- **Not** a placement rule: the queue and the placer do not read it.

Cases:

- **C61** the operator route: a lane whose topic links prio 3 and 4 and
  whose own key is prio 1 sends `priority` 1 and each issue's prio; the
  same topic without the own key sends 3; no issue, or a key of another
  prefix only, sends none. **C61b** the workspace route sends the prio of
  the workspace's own issues on the topic. (`hub/lanes_prio_test.go`,
  memory and Postgres; red with the prio left out of `laneIssues`: every
  value 0.)
- **C62** each GET of either route makes one `FleetLaneIssues` call, for
  2 lanes and for 12 (a counting store over memory and Postgres). Red
  control: a planted per-row call counts 3 and 13.
- **C63** the Prio column is 3rd, its cells read 2, 1, dash, dash on the
  mock fleet's `topics` answer; a name click sorts prio 1 first and no
  prio last, a second click descending, a third the hub order; no sideways
  page scroll, at 1440 and 390 px (`tests/e2e/monitoring-costs.test.mjs`
  `lanesPrioSort`; unit `monitoring-lanes-sort-filter.test.mjs` "the Prio
  column"; red on master: no column).

### 3.15 The list's sort and filters, in its URL (SPL-4729)

The owner, verbatim (HUM-10, t1 `0a730c21`, msg `ea87c5c1`, 2026-11-03):
"the full state of the lanes listing must be shareable via a link - aka
once the lanes have been sorted and filtered - the same link should be
possible to be shared from the url to another person or" (the post ends
there).

The list's state, and where it lives:

| state | decides | where | URL parameter |
|---|---|---|---|
| sort column and direction (3.2, SPL-3887) | the row order | `sort` ref of the page | `sort=<column>&dir=asc\|desc`, a column of `LANE_COLUMNS` |
| box, vendor, state, workspace selects | which rows | `filters` of the page (`LANES_NO_FILTER`) | `box=`, `vendor=`, `state=`, `workspace=` (the workspace id) |
| age select | which rows | `filters.age` | `age=1h\|24h\|older` |
| text filter | which rows | `filters.text` | `text=`, as typed (spaces kept), at most 200 characters |
| the selected lane (3.9) | which row is marked | the route | `lane=<id@box>`, unchanged |
| the read: fleet or workspace route (3.6) | which lanes the hub sends | `lanesRead.own` | none: it is who the reader is, not a choice |
| the answer, its age, the stale marker | n/a | `view`, `fetchedAt` | none: live data |

How it behaves (`utils/monitoring-lanes-url.mjs`, the page's
`readUrl` / `writeUrl`; the Issues list's twin is SPL-4648):

- A sort or filter change replaces the address (`router.replace`), never
  adds a history entry, also while typing; a default (no sort, All, no
  text) writes no parameter. Clear filters drops the filter parameters,
  the sort stays. The minute's refresh and a reload keep them. Every other
  parameter, `lane` among them, passes through.
- A value the page cannot use (a column it does not sort, a direction
  other than `asc`/`desc`, an age outside the three, a box or vendor that
  is not a plain id, a text over 200 characters) reads as not named: no
  error, the list shows, the address drops it.
- **Another person.** The first answer sets back to All each box, vendor,
  state or workspace it does not offer, and the address drops it. A
  member (3.6) reads the workspace route, which sends no box: an
  operator's link with `box=` shows that member's lanes under the other
  filters, never a false empty list. The same holds for a workspace the
  reader does not see. A later refresh does not re-check, so a lane that
  ends mid-session leaves the filter as the reader set it.
- No new column, filter, text key or hub change.

Cases:

- **C64** a URL naming every parameter, as an operator admin at 1440 and
  390: the selects, the text and the sort mark show them, only the
  matching row lists, the address keeps every parameter; reload and
  Refresh keep it.
- **C65** a filter change, the third sort click and typing rewrite the
  address with no new history entry; Clear filters drops the filter
  parameters.
- **C66** bad values (`sort=zzz&dir=up&age=2h&box=<x>&vendor=nope&workspace=w9&state=gone`)
  beside `lane=c-085@box-a`: every lane lists, no page error, the address
  keeps `lane` only and c-085 is selected; `lane=` with `box=` and a sort
  selects that lane in the filtered list.
- **C67** `box=box-a&vendor=claude&workspace=mock&sort=agent&dir=asc`
  opened by a workspace admin (the workspace route, no box): c-085 lists,
  the box select is All, the address keeps the rest.

(`tests/e2e/monitoring-lanes-url.test.mjs` on the mock bundle, 32 checks;
`tests/unit/monitoring-lanes-url.test.mjs`. Red control: a bundle whose
reader drops `?vendor=` and skips the offered check fails C64 and C67.)

### 3.16 Refresh and Clear filters on the tabs' row (SPL-4730)

The owner, verbatim (HUM-10, t1 `3238db2c`, msg `2dd25d62`, 2026-11-03):
"the refresh and clear filters buttons shoud be on the ame row as the tabs
, but on the right side", with a screenshot of `/monitoring/lanes` on a
wide screen where `Refresh`, `Updated 25 s ago` and `Clear filters` had a
row of their own under the tabs.

Read by the dispatch holder as: those controls move up to the tabs' row,
right-aligned, on Lanes and on the other tabs with this Refresh (Topics,
Tokens), so the tabs do not differ.

- **Where they go.** Into the header row's slot `#monitoring-head-actions`
  (`pages/monitoring.vue`, SPL-3250), after the tab bar and before the end
  close X, by a client-only `<Teleport defer>`, as Events' Clear log. Lanes
  and Topics: Refresh, its age, Clear filters. Tokens: Refresh and its age.
  The data-test names, the behaviour and when each is enabled or shown do
  not change; leaving the tab unmounts them with it.
- **What stays above the table.** Lanes and Topics: the red "Data stale"
  badge and "shown n of total", in `.ln-head` / `.tp-head`, which renders
  only while one of them shows, so no empty row is left. Tokens: the window
  pick and the red badge stay in `.tk-head`.
- **Phone.** The header dissolves on a section page (`display: contents`,
  the tab bar its own row with its bottom line); the slot and the bar then
  share that row, the bar scrolling inside itself as before and the slot at
  its right end. Refresh and Clear filters become 44 x 44 icon buttons
  whose words stay their accessible name, and the open tab is scrolled
  into the bar (whole pixels, so the last tab may overrun by < 1 px).
- Not moved: Events' Clear log is already in the slot (desktop) and at the
  bottom on a phone (SPL-2093); no other tab has a control of this shape.

Cases:

- **C68** Lanes, Topics, Tokens at 1440, 390 and 320 px: each control is in
  `#monitoring-head-actions`; its vertical middle lies in the tab bar's
  box; the controls start right of the bar and end at the row's right side
  (the header's content edge, or the close X after them); no page scroll;
  on a touch screen each button is >= 44 px tall. Red control (the three
  pages from master `53846f26e`): 90/135, the controls under the tabs.
- **C69** Refresh reads again (the age back to 0..2 s); Clear filters is
  disabled with no filter, a box filter enables it, a click brings every
  row back. Moving to the next tab leaves none of the controls behind.
- **C70** the states without a list: an empty answer (Refresh and the age,
  no Clear filters, no `.ln-head` row), forbidden (the sentence and Refresh
  only), first load (Refresh before the answer, the age only with it).
  (`tests/e2e/monitoring-head-actions-row.test.mjs` for C68-C70.)

### 3.17 A workspace's own boxes show their lanes (SPL-4778)

The owner (HUM-10, t1 `dc2d6c40`, 2026-11-04), with the workspace and the
box owner's name replaced by placeholders: "why the lanes in the <W> do not
show the newest added box on the <FirstName>'s mac" / "the whole <W>
workspace is not visible in the lanes"; on the poll that followed, "A — Yes,
an agent is working there".

Measured on master `af48d0fcb` (code), and on prd by the dispatch holder
(`do_spl_db_query`, 2026-11-04 09:2x-09:4xZ, n = 1 read each):

- A put (`spool lane`, lane_op put) is stored in the tenant of the writing
  box's verified pin (`hub/box_lane.go:126-143`, `x.tenant`). Any pinned
  box may put, a box joined to a workspace (spec 108) too. Only the
  fleet's spawn tooling calls it (`_spawn_lane_put`); a joined box running
  only `spool hub-run` never does: prd held no `fleet_lanes` row written by
  the joined box.
- Both views read the operator workspace's rows only:
  `activeFleetLanes(ctx, op, ...)` in 3.3 and in 3.6. A workspace's own
  rows were read by nobody.
- The joined box's `spool hub-run` announces its agent: prd `roster`
  (W, the joined box) held `c-001`, `running` NULL (a client too
  old to report it). The same workspace's roster also holds the fleet
  boxes' agents (their desks are pinned there: `c-001`, `c-002`, ... on
  the fleet boxes, running true).

The design (`hub/workspace_own_lanes.go`), on `GET /v1/view/lanes` in a
workspace W other than the operator's:

- **W's own box** = a box pinned in W that is not also pinned in the
  operator workspace. The fleet's boxes are pinned in many workspaces;
  their lanes stay the operator's (3.6: on W's topics only, without the
  box).
- **W's own lanes**: W's `fleet_lanes` rows written by an own box, by 3.3's
  active rule, read in W's own scope. Each row keeps its box (W's own), W's
  topic title when the caller may open it (else none, as 3.3), and its own
  issue key (a W issue, read in W).
- **Announced agents**: each roster agent of W's online own boxes
  (`boxOnlineLocked`, the presence stamp) whose box does not report it as
  not running (true, or unreported = NULL), with a lane id
  (`^[acgmoqu]-[0-9]{3}$`) and no own lane row of the same
  `<agent>@<box>`. It shows as live with its box, vendor and workspace, no
  topic, scope or issue (the roster carries none), and `updated_at` = the
  box's last presence stamp.
- **Keyed by `<agent>@<box>`**, never by the id alone: W's own `c-001` and
  the fleet's `c-001` on a W topic are two rows.
- The order: the operator's lanes on W's topics, W's own lanes (newest
  write first), the announced agents (box, then agent), the queued asks.
- Isolation: nothing of another workspace is read; the operator
  workspace's own route (3.6 in the operator workspace) is unchanged.
- **The operator view** (3.3, `GET /v1/operator/fleet-lanes`; owner
  HUM-10 on the choice, read as A by the dispatch holder: "it must be seen
  too .. as part of the cluster") lists, after the operator's lanes, every
  other non-archived workspace's own lanes and announced agents, by the
  rules above, each named by its workspace. 3.3's rule for another
  workspace's topic holds: its id as text, no title, no issue and no origin
  issue, and no scope either (that workspace's own text; dispatch holder's
  ruling on R7 W1). An announced agent shows once: a box pinned in two
  workspaces announces it in each, and a lane row of it in any workspace
  stands for it (R7 N1); each workspace's own view still lists its own.
  The token burn and the operator's pins are read once per call;
  per workspace one `fleet_lanes` read, one roster read and the topic and
  issue resolution of its lanes (3.11; 19 workspaces
  on prd). This widens 3.3's "One tenant only" for these rows alone. The
  operator's Agents and Boxes tabs still read the session's workspace
  (`GET /v1/view/roster`); their cross-workspace view is another lane.

A topic or scope for a joined box's lane needs a put on that box:
`spool lane --fleet main --agent <ID> --box <box> --scope "<one line>"
--topic <uuid> --state live`, renewed within 60 min (3.3's active rule;
such a box pushes no token burn), `--state done` at the end.

Cases (`hub/workspace_own_lanes_test.go`, memory and Postgres):

- **C71** W's admin reads the operator's lane on its topic (no box) and
  its own box's lanes (with the box, its title on a W topic, without a
  topic too). **C72** an own row naming another workspace's topic shows no
  title and no text of it. **C73** a done row and a row written 3 h ago:
  absent. **C74** w2's admin, the operator admin on this route and the
  operator workspace's admin on this route do not show W's own lanes or
  box. **C79** the operator view lists W's own lanes, named by W, the topic
  id as text, no W title, scope, text or issue.
- **C75** the joined box's announced `c-001` and the fleet's `c-001` are
  two rows; an agent with a lane row shows once; an unreported agent
  shows. **C76** an agent reported not running: absent. **C77** an
  announced agent of an offline own box: absent. **C78** the agents of a
  fleet box pinned in W: absent, its box id never in W's answer. **C80**
  the operator view holds the fleet's `c-001` and the joined box's `c-001`
  as two rows of W, never C76-C78's agents. **C81** a box pinned in w1
  and w2 announcing `c-709` and `c-711` in both, `c-711` with a w2 lane
  row: the operator view lists each once; w1's own view lists both.
- Red controls: C71 on master `af48d0fcb` (W's admin read `[c-501]`
  only); C75 with `rosterLanes` returning none (the joined box's `c-001`
  and the unreported `c-707` absent); C79 and C80 on the tree before the
  operator part (the operator view read W's own lanes as `[]`); C79's
  scope and C81 on `451145f8f` (the operator rows carried "scope of
  c-701".."c-703"; `c-709` and `c-711` twice each).

### 3.18 Every workspace's own boxes and agents, in the operator's Agents and Boxes (SPL-4786)

The owner, verbatim (HUM-10, a customer workspace, topic `d60646d9`): "but why the newly
registered agent cannot be seen" (msg `34c50576`), "it must be seen too ..
as part of the cluster" (msg `0443824f`), "ok, fix this bug" (msg
`4103e959`); t1 `dc2d6c40` the same for Lanes. A box pinned only in a
customer workspace (a Mac with `c-001`) was in no list of
the operator workspace: Agents and Boxes read `GET /v1/view/roster`, the
session's workspace only. The Lanes part is SPL-4778's.

- **The hub route.** `GET /v1/operator/fleet-roster`
  (`internal/hub/operator_roster_view.go`), behind the fleet-lanes doors
  (the operator workspace's admin or the operator service account; 403 for
  anyone else). It reads every non-archived workspace other than the
  operator one in its own tenant scope (`ViewBoxes`), leaves out a box
  locked to someone in that workspace, and answers
  `{boxes: [{workspace, workspace_name, box_id, revoked, last_hello_at,
  online, agents, agent_presence}], also_seated: {<box_id>: [{workspace,
  workspace_name}]}}`. A row carries no key, no host facts and no topic,
  issue or message of its workspace.
- **One row per box** (dispatch c-002, msg `a3d9b5c9`). A box the
  operator workspace has (pinned there, or a fleet desk box, spec 158) is
  no row of another workspace: it stays in the operator's own list, and
  `also_seated` names the workspaces it is also seated in. Only a box
  pinned in a customer workspace and not in the operator one is a row,
  under that workspace. Agents follow their box: `c-001@sat` and
  `c-001@<customer-box>` are two rows, `c-001@sat` once.

Cases (`internal/hub/operator_roster_view_test.go`, memory and Postgres):

- **C82** a customer-only box is one row under its workspace, named, with
  its agent and presence and no key or facts; the operator's box also
  seated there is no customer row and is in `also_seated`. Red controls:
  the loop limited to the operator workspace (the customer box absent);
  the own-box skip dropped (the shared box a customer row).
- **C83** an archived workspace's box and a locked box are absent. Red
  controls: the archived skip dropped; the lock filter dropped.
- **C84** a developer of the operator workspace and an admin of another
  one read 403.

The WUI (`stores/fleet-roster.ts`, `utils/fleet-roster.mjs`), read once
per page load and only for a reader `/v1/view/me` may name the operator
admin; a 403 or a hub without the route shows nothing more:

- **Agents.** After the workspace's own agents, one group per other
  workspace ("Workspace: <name>", its count), each row `id@box` with
  `data-workspace`. Its card is `/monitoring/agents/<id@box>?ws=<id>`.
- **The foreign card.** Kind, workspace, box (no link: the box card is
  this workspace's), online / not running / offline, last hello, and the
  line "This agent runs in the workspace <name>. Its lanes, topics and
  messages stay in that workspace." No tabs, no Message. A `ws` the
  roster does not hold shows one line, never an error.
- **Boxes.** An own box seated in other workspaces carries "Also seated in
  <n> other workspace(s)", their names on hover. After the own groups,
  one group per other workspace, each box with its agents (no card). The
  filter also matches the workspace's name or id; the count holds both.
- New text: `agents.workspace_group`, `agents.workspace`,
  `agents.foreign_note`, `agents.foreign_missing`, `boxes.also_seated`, in
  every locale, reviewed by agy before it lands (the language rule).

Cases (`tests/e2e/monitoring-boxes-align.test.mjs` on the mock bundle,
`tests/unit/fleet-roster.test.mjs`):

- **C85** Agents: `CLE-07@box-a` and `CLE-07@mac-01` are two rows, the
  second under Customer Space; Boxes: `mac-01` once under it, `box-a` once
  with its also-seated line; the filter `customer` leaves `mac-01`. Red
  control: the three pages from master (no foreign row).
- **C86** the foreign card names its workspace, has no tabs and no
  Message, and the list keeps its row selected; an unknown `ws` shows one
  line.
- **C87** a non-operator sees no other workspace; no page errors.

### 3.19 Every id in a lane row renders as a link (SPL-4798)

The owner, verbatim (HUM-10, t1 `0c2d08a2`, 2026-11-04): "there are still
lanes created without a proper link to their discusions" (msg `e7009f10`,
a screenshot of Monitoring -> Topics: the discussions of the other
workspaces shown as bare
uuids), and "whenever an agent adds those , there should be some kind of
mechanical code base trigger which conerts those ( or a renderer on the
page ) , which continas those to links" (msg `ea369ab0`). Placed by the
dispatch holder as lane (b) of three (c-001 `b06ce20d`): (a) the writers
and the 15-min check, (c) the NOT NULL migration that writes `unknown` into
old rows, (b) this renderer.

- **One renderer.** Lanes and Topics hand each id to
  `utils/note-links.mjs` `noteLinkHref`, the WUI's renderer of `type:id`
  objects (how-to-post.md rule 11), through
  `composables/useLaneLinks.ts`. The row gives the typed ref
  (`utils/monitoring-lanes.mjs` `laneTopicRef`, `laneIssueRef`); the page
  builds no host itself.
- **Discussion.** A topic uuid opens `/t/<uuid>` on the host of the
  workspace the hub placed the lane in (3.8, `workspace`): another
  workspace's topic now links on its own host, where that page's own access
  check applies; this replaces 3.3's and 3.17's "its id as text" for the id
  (owner HUM-10, t1 `0c2d08a2`, msg `ea369ab0`). The title, scope and issue
  of another workspace stay hidden. `dispatch-<topic8>` (a spool task, stored as sent, C7b)
  opens `/t/dispatch-<topic8>` on the page's workspace; `noteLinkPath`
  accepts that one task form beside a uuid. The link text is the title,
  else the id.
- **Issue.** A key the hub sent a status for is the page's workspace's and
  opens there. A key with none is another prefix: it opens in the lane's
  workspace when that is not the page's (e.g. `DVN-3` on a w2
  lane), else it stays text.
- **Text, never a guess.** `unknown` (lane (c)'s value), an 8-hex short id,
  a uuid the hub found in no workspace (no title, the page's own workspace)
  and any id whose workspace has no known host (tenant hosts off: every
  workspace but the page's) stay plain text.
- **Trigger: render time, not the row write.** Every row already written,
  by any writer and before lane (c) ran, links the same way; the host comes
  from the env when the page renders (`siteUrl`, the apex tenant), so no row
  stores an address that a host change would break. Lane (a) checks that
  each row names an id; this section only shows it.

Cases:

- **C88** unit (`tests/unit/monitoring-lane-links.test.mjs`): a w2
  topic uuid read on the spool-hub page links
  `https://w2.<site>/t/<uuid>`; the apex tenant's on the apex;
  `dispatch-0c2d08a2` links `/t/dispatch-0c2d08a2` on the page's
  workspace; `SPL-4791` (wip) on the page's workspace, `DVN-3` (no status)
  on the lane's. Controls: `unknown`, a short id, an untitled uuid of the
  page's workspace, and tenant hosts off for another workspace stay text;
  both pages call `laneTopicRef` / `laneIssueRef` and no longer
  `laneTopicPath` / `laneIssuePath` (red on master).
- **C89** e2e on the mock bundle (`tests/e2e/monitoring-lane-id-links.test.mjs`,
  mock `spool.mock.fleet_lanes=links`), 1440 and 390 px, Lanes and Topics:
  `dispatch-5e7b15c9` links the task, `SPL-4791` its issue; controls:
  `DVN-3` of the page's own workspace and `unknown` stay text. Red control:
  the pages from master print the task as text.

### 3.20 No new lane without its discussion and its issue; a 15-minute check (SPL-4797)

The owner's words, verbatim (HUM-10, t1 `0c2d08a2`): "there are still lanes
created without a proper link to their discusions" (msg `e7009f10`), "the
links must be enforced , by even some kind of dispatcher , cron scheduled
work to check them" (msg `08ac07da`), "for the already nulls , do not use
resources to search what they were related to -, use the unknown string"
(msg `937e89a4`). The standing rule (t1 `f94e07bf`, msg `33f8eecb`): "each
lane must have at least 1 link to an issue WHAT It is doing and at least 1
link to a discusion from where did it originated".

Measured on prd 2026-11-04 ~13:30Z, tree `022055fe6`, n = 1 read:
`ENV=prd SQL="select agent_id, agent_box, topic, issue_key, ... from
fleet_lanes where state='live'" ./run -a do_spl_db_query` (csi-spl-orc) ->
182 live rows, 147 with no topic, 144 with no issue, 135 with neither; all
but 13 of the 147 are rows of October lanes never marked done. The rows of
lanes placed on 2026-11-04 with no topic, each brief read in
`/var/spool-hub/dispatch/briefs/`:

| lane | what the brief names | why the row has no topic |
|---|---|---|
| c-089 | `topic ebb24c8d-b371-50bc-...`, a customer workspace's topic | the hub took the version-5 uuid for a relay hash and stored nothing (fixed below) |
| c-850, c-927 (other box) | only the task `dispatch-s169-rows` | no discussion named: refused from now on |
| c-084, c-092 | only the task `820ea59e-79ef-588b-...`, a relay hash of a name (t1, no channel) | no discussion named: refused from now on |
| a-924 (other box) | no task, no topic | no discussion named: refused from now on |
| c-001, c-002, c-003 (both boxes), g-00N | role seats | by design (below) |

What changes:

- **The hub keeps another workspace's topic.** A put whose topic is a
  version-5 uuid that is no relay hash of the tenant's `dispatch-<topic8>`
  stores it when it is a topic of another non-archived workspace
  (`laneTopicIsElsewhere`, `internal/hub/box_lane.go`; operator workspace
  only, as `laneTopicElsewhere`). a customer workspace's topic ids can be version 5.
- **The placer refuses a lane with no discussion or no issue**
  (`spl_spawn_place_no_links`, `spl-spawn-place.func.sh`): no discussion = the
  ask's topic is neither a hub uuid nor `dispatch-<topic8>`, the ask has no
  `discussion` and the brief names none (`li_discussion_from_brief`,
  `lane-issue.inc.sh`: a `Discussion:` line wherever it is, words before its
  uuid allowed, then `Topic:` / `topic <id>` / `Discussion:` / `/t/<id>`,
  else a `dispatch-<topic8>` task. A version-5 uuid counts only on a
  `Discussion:` line (a customer workspace's topic can be one), unless the
  word before it is `task`; there and on `Topic:` and `/t/` it is skipped, a relay task's hash (SPL-5099: a reviewer brief's `Topic: <author task>` beat its
  `Discussion:` line and blanked the row at every rotation); no issue = no `Issue:` key and no
  `Epic:` + `Spec:` pair the placer files one under. The row goes to the
  holder as a SPAWN QUEUE blocker naming the line to add; nothing launches.
- **What the placer accepts is what the row gets** (R7 c-343 W1). The
  spawn's row reader (`_spawn_lane_topic`, `spawn-core.inc.sh`) calls
  `li_discussion_from_brief` first, so the two cannot drift (before, a
  `Discussion: <id>` or `**Topic:** <id>` brief passed the placer and the row
  stored no topic). An ask that passes on its `discussion` (a full uuid or its
  8 hex) launches with that as `SPAWN_LANE_TOPIC` when its topic names none.
- **Role seats** (001-003 of any vendor, or a row the role rotation wrote,
  scope `role <id> (rotation ...)`): their defined value is the hub's
  `role_seat` mark (3.11), which the pages show as "role seat" in both cells.
  They get no topic and no issue key; the check below leaves them out.
- **`unknown`** is the value lane (c) writes into the old empty rows, without
  a search. The pages show it as plain text: a non-uuid topic is never a
  link (`laneTopicPath`) and a non-empty one is never "No discussion"; an
  issue key with no status is never a link (`laneIssuePath`). The check
  counts `unknown` as a value.
- **The 15-minute check** `cd csi-spl-orc && DELIVER=1 ./run -a
  do_spl_lane_links_check` lists every live lane row (role seats, legacy ids
  and rows older than `LINKS_CHECK_MAX_AGE_H`, default 24 h, aside) with no
  topic or no issue, one line each, and sends them in one note to the
  dispatch lease holder on task `lane-links-check`; it fills nothing and
  searches nothing. The same list is sent again only after
  `LINKS_CHECK_RESEND_MIN` (120); a lease on another machine sends from
  there. `unanswered-sweep-cron.sh` (the minute cron of
  `do_spl_unanswered_sweep`) runs it every `LINKS_CHECK_EVERY_MIN` (15).

Not built here: the Topics tab shows another workspace's topic as its bare
uuid with no channel. Its title and channel are filled in
`internal/hub/fleet_lanes_view.go`, which deliberately sends no other
workspace's title to the operator (case C58, SPL-4705); showing it is a
change of that rule, left to the dispatch holder (that file is lane
SPL-4778's). The link is lane (b)'s renderer.

Cases:

- **C90** a put of another workspace's version-5 topic uuid stores it;
  **C91** its `dispatch-<topic8>` 8 hex resolves to it; **C92** a version-5
  uuid that is no topic anywhere stores nothing.
  (`hub/lanes_topic_elsewhere_test.go`; RED on `022055fe6`: C90 stored "")
- **C93** a row whose ask topic is `dispatch-s169-rows` and whose brief names
  no discussion is handed to the holder, nothing launched (control: the same
  brief on `dispatch-<topic8>` launches); **C94** a brief with no `Issue:` key
  and no `Epic:`/`Spec:` pair is handed off with "no issue".
  (`csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh` case 16c)
- **C97** a brief naming `Discussion: <uuid>` or `**Topic:** <uuid>` passes the
  placer and `_spawn_lane_topic` reads that uuid; an ask on
  `dispatch-s169-rows` whose `discussion` is set launches with
  `SPAWN_LANE_TOPIC=<discussion>`. (case 16d; RED on `76d88cb1c`: row=[] for
  both briefs, SPAWN_LANE_TOPIC unset)
- **C95** the check names the gaps and leaves out role seats, legacy ids,
  done, complete, `unknown` and day-old rows; DELIVER=1 sends one note to the
  holder, not again within the resend window; the minute cron runs it once
  per 15 min. (`csi-spl-orc/src/bash/tests/lane-links-check.tst.sh`)
- **C96** `unknown` is no link and keeps its own Topics row, apart from "No
  discussion". (`csi-spl-wui/tests/unit/monitoring-lanes-unknown.test.mjs`)

### 3.21 The lanes table holds no lane without its discussion and its issue (SPL-4799)

The owner's words, verbatim (HUM-10, t1 `0c2d08a2`, 2026-11-04): "and the
tble of the lanes must not accept nulls , for neither discussions nor
issues" (msg `80bee509`) and "for the already nulls , do not use resources
to search what they were related to -, use the unknown string" (msg
`937e89a4`). Lane (c) of the three this ask was split into; (a) is 3.20,
(b) is 3.19.

Measured on prd 2026-11-04 16:36Z, n = 1 read, read-only:
`ENV=prd SQL="select count(*), count(*) filter (where topic is null), ...
from fleet_lanes" ./run -a do_spl_db_query` (csi-spl-orc) -> 1035 rows,
0 NULL in either column, `topic = ''` 533, `issue_key = ''` 151, live rows
with either empty 155. Both columns were `NOT NULL` already (rdb 0096,
0221); the empty string, their `DEFAULT ''`, was the "null" the owner saw.

What changes:

- **rdb 0264** (`0264_fleet_lanes_topic_issue_required.sql`, forward-only,
  idempotent) writes the literal `unknown` into every empty (or NULL)
  `topic` and `issue_key`, with no search; drops both `DEFAULT ''`, so an
  insert that names neither fails on `NOT NULL`; adds `CHECK (topic <> '')`;
  and replaces 0221's `issue_key` CHECK (`''` or a key) with "`unknown` or
  a key". The old CHECK is dropped first: it refuses the `unknown` the
  UPDATE writes. `origin_issue` (0253) stays optional. It applies with the
  normal hub deploy (`spool migrate`).
- **The store refuses** a put of a lane with no topic or no issue key,
  `store.ErrLaneUnlinked`, on both drivers (`laneLinked`,
  `internal/store/fleet_lane.go`). The hub answers it `400 bad_frame` with
  the field that is missing, or "topic X names no single discussion" when
  the sent topic resolved to none (`internal/hub/box_lane.go`).
  `lane-map.sh put` runs in the background of a spawn, so a refused put
  never stops a spawn; lane (a)'s placer refuses such a lane first.
- **The spawner is told** (R7 c-198 W2): every spawn path, not only the
  placer's, reaches `_spawn_lane_put` (`spawn-core.inc.sh`). A lane whose
  put would carry no topic or no issue prints `WARN: LANE ROW REFUSED:
  <id> has no discussion (topic) [and] no issue` on the spawner's stderr
  (dry runs too) and appends it to `<SPOOL_ROOT>/<id>/lane-unlinked.log`,
  because the put's own answer goes only to the background `lane.log` and
  the lane would be missing from `lane-map --check` unseen. It never sends
  `unknown` for a lane: that would dodge the owner's rule. Rows that are no
  lane (below) are not named.
- **`unknown` is a value**, not a gap: an old row's done write carries it,
  and the issue-discussion fill of 3.12 (`laneTopicsFromIssues`) treats it
  like none.
- **Rows that are no lane** store `unknown` for a missing link, never a
  refusal: a box's own load row (`BOX-<n>`), a role seat (001..003 of any
  vendor) and a row the role rotation wrote (scope `role <id> (rotation
  ...)`, `store.LaneRoleScope`, the same rule as 3.20's).

Cases:

- **C98** a lane put with no topic, with no issue key, or with neither
  (`c-004`, and `c-005` whose scope merely starts with "role ") is refused
  with `ErrLaneUnlinked`; a linked put is stored; an `unknown` row takes
  its done write. **C99** `BOX-0`, `c-001`, `g-002`, `CLE-003` and a
  `role c-462 (rotation ...)` row with no links store `unknown` in both.
  Memory and Postgres (`store/fleet_lane_test.go`,
  `TestFleetLaneLinksRequired`).
- **C100** on the table as 0221 left it, three inserts are stored: one
  naming neither column, one with `topic = ''`, one with `issue_key = ''`.
  After 0264 each empty column of the three reads `unknown` and the
  others keep their value (n = 3); the same three inserts are refused
  (`23502` NOT NULL; `23514` `fleet_lanes_topic_set_check`; `23514`
  `fleet_lanes_issue_key_check`); a second apply runs without error and a
  linked insert is still stored
  (`store/fleet_lanes_required_migrate_test.go`, Postgres only). Two more
  inserts pin each `DROP DEFAULT` alone (R7 c-198 N1): one naming only
  `issue_key`, one naming only `topic`, each refused `23502` after 0264,
  and its missing column reads `unknown`. Red control: either `DROP
  DEFAULT` taken out, its insert gets `23514` instead (n = 1 each).
- **C101** a dry-run spawn with a topic and an issue prints no `LANE ROW
  REFUSED`; with no issue, no topic, or neither, it prints the line naming
  what is missing; `SPAWN_LANE_TOPIC` + `SPAWN_ISSUE` silence it; a role
  seat (`c-002`) and a `role c-462 (rotation ...)` scope are not named, a
  scope that merely starts with "role " is
  (`spawn-agents/tests/test-spawn-lane-unlinked.sh`, n = 8). Red control:
  the call taken out, the 4 refused cases fail.
- Red controls: C98 before this change, the refused puts were stored
  (n = 3 per driver); C99's role-rotation row with the scope rule taken out
  (refused, `ErrLaneUnlinked`); C100 with 0221's CHECK still in place (the
  UPDATE failed on the first empty `issue_key`).

### 3.22 The Queue tab: requests and plans, priority, drag, resources, and why it slows (SPL-4940)

Design only. Nothing here is built; every "today" below is what was read.

#### 3.22.1 The owner's words, verbatim

| topic, msg | time (UTC) | text |
|---|---|---|
| t1 `c1400bbb`, `973a1643` | 2026-11-06 19:12:26 | "we need a way to visualize them , aka this whole pipeline and how do they turn into lanes .." |
| t1 `c1400bbb`, `5cbb2061` | 2026-11-06 19:13:36 | "or does it have it's now attributes - aka it needs to be a separate tab - the aim is to be able the change the priority on what things will go into the pipeline and become lanes" |
| t1 `c1400bbb`, `3270dbae` (form `cbf26da2`) | 2026-11-06 19:17:51 | "Answer 1: A — A separate Queue tab next to Lanes (recommended) Answer 2: B — Requests and plans together from the start Answer 3: B — Also drag a request to an exact position" |
| t1 `906c1b28`, `fdff1189` | 2026-11-06 23:50:25 | "the priority of the lanes and the future plans and request must be setable via the ui" |
| t1 `906c1b28`, `9543b6cb` | 2026-11-06 23:50:50 | "and lower priority would mean using more resources - aka more resource allocation for the lanes" |
| t1 `906c1b28`, `f4f10fd4` | 2026-11-06 23:51:03 | "even if that would require spawning new agents for subtasks" |
| t1 `c1400bbb`, `3ced3a4f` | 2026-11-07 00:07:39 | "put this one ahead of the queue" |
| t1 `c1400bbb`, `469bc55e` | 2026-11-07 00:08:07 | "I want to be able to see thtat queue and why things are getting slower and slower every day" |

The brief also quotes t1 `6a7d0160`, msg `c2d9f809`: "plans queue". Not
confirmed: on prd `messages` holds no row with that msg prefix and no owner row
on that topic prefix (2026-11-07 00:3xZ, n = 1 read each, 0 rows), so these
words are second-hand.

**Should this split?** Yes, in the build, not in the design: four tracks land
apart. The placer rule (Q1) is one function and fixes a bug the owner already
hit, so it goes first. Requests and drag (Q2-Q6), plans (Q7-Q8), resources (Q9)
and the throughput view (Q10-Q11) do not wait for each other, except where
3.22.11 says so.

#### 3.22.2 What was read

Code on origin/master `fe0455e48`. Every prd count: `ENV=prd SQL="..."
./run -a do_spl_db_query` (csi-spl-orc), read-only, 2026-11-07 00:17-00:40Z,
n = 1 read each. The brief's second-hand claims, re-checked:

| claim (c-002, 19:13Z) | read | verdict |
|---|---|---|
| 129 queued rows | `count(*) filter (where state='queued')` -> 123 at 00:17Z, 120 at about 00:30Z | the table moves; re-read before quoting |
| order is priority, class, time in line | `askPositions`, `store/fleet_ask.go:293` | yes |
| a request's priority is its discussion's, else 3 | `askPrio`, `store/fleet_ask.go:253`; `TopicPriorityDefault = 3`, `store/topic_priority.go`. The comments in rdb 0214 and 0241 still say "no row = 5" | yes; the two comments are stale |
| plans are not in that table | `fleet_asks` has 37 columns, no plan row kind; no table named `%plan%` but `hours_plan` | yes |
| no per-request position | no such column among the 37; the position is computed on read | yes |

More facts the design rests on:

- **Most queued rows cannot carry a priority.** Of 122 queued at 00:2xZ, 93
  have `discussion` NULL: 89 name a topic that is not `dispatch-<topic8>`
  (`spawn-share` 15, the rest other tasks) and 4 are `dispatch-<topic8>` that
  resolved to no topic. `askDiscussion` (`hub/box_ask.go:292`) looks only in the
  ask's own workspace, and `askListPriorities`
  (`store/fleet_ask_postgres.go:172`) reads only that workspace's
  `topic_priorities`. Whether those 4 are other workspaces' topics: not checked.
- **Every priority set in t1 is the owner's.** `select set_by, priority,
  count(*) from topic_priorities where tenant_id='t1'` -> HUM-10 on all 48 rows
  (13 at 1, 16 at 2, 15 at 4, 4 at 5). Agents have no door to it (the PUT takes
  a member session, `hub/topic_priority.go`).
- **The band pick ranks queue position last.** `spl-spawn-place.func.sh:366`:
  `sort_by(._t, -._s, ._o, .position)`; only a `ci` or flagged head skips it
  (`spl_spawn_place_band`, :349). So a priority 1 row is not safe at position 1.
- **The feature issue, read in the placer log** (`cron.out` on the holder's box,
  lines 67945-67950). This lane's ask `369f326d` got priority 1 at 00:07:22
  (`topic_priorities`). The next pick read "band pick: ask 881adc37 (bug at 37%,
  queue position 2)": a bug row still under its band beat position 1, whose
  feature class sorts with `_s` 0. `881adc37` was placed at 00:13:30. The next
  pick read "band pick: ask 369f326d (feature at 47%, queue position 1)", placed
  00:16:51. c-002 set the bypass flag at 00:15:05, but that line is the path
  only an unflagged head takes, so the flag did not decide that pick: bug had
  gone OVER (41%) once `881adc37` was placed. The row got through on the
  arithmetic.
- **The band pick reaches far down.** The same log, one pick earlier: "band pick:
  ask 892699a7 (feature at 46%, queue position 117)", placed 00:08:32.
- **The hub never hears why a row waits.** The placer's hold reason goes to
  `<asks dir>/.place.wait` on its own box (`spl_spawn_place_wait`, :1093), and
  the placer sends the hub no reason (`grep -nE 'ASK_REASON|--reason'
  spl-spawn-place.func.sh` -> 0). The Lanes table's `wait` is the ask's own
  reason field (`hub/lanes_queued.go:62`), so a held row reads "waiting for room"
  whatever holds it.
- **The placer log has no time on its lines**, so a hold cannot be counted per
  day from it. Over its last 14,000 lines, per row per tick, so not comparable
  with each other: agy out of quota 5309, pinned to a box past its overflow or
  cordoned 3635, claude weekly limit 977, fleet load target 944, the gap after a
  launch 188.
- **Plans cannot become requests while a queue exists.** The idle filler is on
  (`all.env.yaml:1190`), and it stops at any queued row
  (`spl-spawn-fill.func.sh:72`).

#### 3.22.3 The tab

A tab **Queue** right after Lanes: `MONITORING_TABS` gets
`{ id: 'queue', path: '/monitoring/queue', labelKey: 'monitoring.tab.queue' }`,
its own chunk (C20's budget rule holds). Who reads it:

- **An operator admin** reads and changes every row (`operatorActor`, as
  `GET /v1/operator/fleet-lanes`).
- **A workspace's owners and admins** read the requests on their own topics, as
  3.8 already shows them on Lanes (C40), and set the priority of their own
  discussion through the door that exists. They do not drag: a position orders
  other workspaces' work. Row Q8b; the first build is operator only.

The page reads one route, every 60 s as Lanes does (P4):
`GET /v1/operator/fleet-queue`. Three blocks, top to bottom: the line "what the
placer did last" (3.22.8), the **Requests** table, then the **Plans** table
(3.22.5). The flow table of 3.22.8 sits under them, collapsed by default.

The Requests columns, in this order:

| column | value | source |
|---|---|---|
| Position | `n/total`, or `placing` | `askPositions`; state `acked` |
| Prio | 1..5, with a mark for where it came from: own, discussion, default | 3.22.6 |
| Class | ci, refactor, bug, feature, plus urgent / bypass | `class`, `flag` |
| Summary | the ask's summary | `summary` |
| Discussion | `type:id` link (3.19), a dash for none | `discussion` |
| Issue | the key as a link, a dash for none | `issue_key` |
| Vendor | before the `:` of the placement | `placement` |
| In line | since `enqueued_at` | hub clock |
| Waits on | the hold reason, or "room" | new, 3.22.8 |
| Lane | empty until placed, then the lane link | below |

**How a request links to its lane.** The placer closes an ask with reason
`placed: <ID>@<box>` (`spl-spawn-place.func.sh`, TAKE). The route parses that
one form and sends `lane: "<ID>@<box>"`. A **Placed** filter (off by default)
lists the closed rows, which the hub keeps a week (rdb 0097). The cell links to
`/monitoring/lanes?lane=<ID>@<box>` (`laneDeepLink`, 3.9); a lane no longer
active reads "ended" with its agent id as text. A reason of any other shape is
no link, and is never guessed from the summary.

#### 3.22.4 Which rows it lists

Only `role = 'orch'` rows in state `queued`, or `acked` with an `enqueued_at`,
exactly as `spl_spawn_q_rows` reads them, so the tab and `do_spl_spawn_queue`
agree (C103).

#### 3.22.5 Plans

**What a plan is:** a piece of work someone decided on that has no spawn request
yet. Read from the tree and the hub, there are four places:

| where | what it holds | measured | priority today |
|---|---|---|---|
| open issues | status `todo` or `eval`, kind `issue` | t1: 276 open and not archived; `spec_path` set on 0 of them; 94 of 299 (no archive filter) carry the `[NNN id]` spec import prefix | yes, 1..5, settable, follows the discussion (spec 150 3.4 item 4) |
| round plan rows | `doc/md/*-round-*-plan.md` tables | rounds 20-26 among others, each plan's own table form | no |
| spec rows | `specs/*/tasks.md`, spec section 5 tables | 171 spec folders, 107 with a `tasks.md` | no |
| work groups | `<spool root>/dispatch/groups/<EPIC>.json` on the orch box | 14 files; rows carry class, placement and issue key (`do_spl_spawn_group_put`) | no; a width instead |

**The source is decided: open issues (O2 = A, section 7).** A planner files an
issue for each round and spec row when its plan is signed. Issues are the one place
with a priority, a UI door, a discussion link and tenant isolation, and "every lane
carries an issue" means a row needs a key before it lands anyway.

**Filing a signed plan (row Q12).** `do_spl_spec_import_issues` files the entries
of a `tasks.md` (or a `cases.tsv`), idempotent on the `[NNN <id>]` title prefix
(`orc/run/spl-spec-import-issues.func.sh:3-12`). It reads neither a round plan's
table nor a spec's section 5 table, so nothing files those rows today. Q12 adds
`SPEC_IMPORT_PLAN=<file>` and `SPEC_IMPORT_PLAN_TABLE=<heading>`: one issue per
row of that table, status `eval`, under the plan's epic, linking its discussion (a
plan's `Epic:` and `Topic:` lines, or the run's `ISSUE_DISCUSSIONS` for a spec). A
row that already names an `SPL-n` is not filed again; a plan with no epic or no
discussion is refused. The planner runs it as the last step of signing, a step
`lane-issue-and-docs.md` will name. Nothing detects a signed plan whose planner
skipped that step: its rows stay out of Plans until someone runs it.

**How it shows.** A second table under Requests, same page, sorted by priority
then age, 50 rows and a "show more". Columns: Prio, Kind (`plan`), Class (from
the label `bug`, `feature` or `refactor`; none is shown as none, never guessed),
Title, Issue, Discussion, Epic, Age. It leaves out what the filler's own rule
leaves out (`spl-spawn-fill.func.sh:184`): an issue a live lane or an ask already
holds, a label `needs-owner`, `blocker` or `epic`, a human assignee. So a row is
in one table only, the rule C110 pins.

**Priority on a plan** is the issue's priority, set through the issue door that
exists. If the issue follows a set discussion, the 5-minute sync
(`do_spl_topic_prio_sync`) would put the discussion's value back, so the chooser
sets the discussion instead and says so.

**How a plan becomes a request** ("what things will go into the pipeline").
Today it cannot while the queue is non-empty (3.22.2). New in Q8: an issue the
owner set to priority 1 or 2 passes the filler's "queue is empty" gate, still one
per tick (`SPAWN_FILL_MAX`), still with the filler's brief and class rules, and
still never one with no class label. A plan at 3..5 waits for an empty queue, as
today. No drag on a plan: answer 3 names a request, and a plan has no place in a
line until it is a request.

#### 3.22.6 Priority: on a request, on a plan, on a lane

**On a request.** New nullable `fleet_asks.priority` (1..5) with `priority_by`
and `priority_at`. The effective priority, which `askPrio` returns and the row
carries with its `priority_source`:

1. the ask's own and the discussion's are both set: **the newer write wins**
   (`priority_at` against `topic_priorities.set_at`). Setting a discussion later
   overrides an older setting on one request of it, and the reverse;
2. only one is set: that one;
3. neither: 3, as today.

This keeps the owner's rule that discussion, issue and lane agree (spec 150 3.4
item 4) for everything that has a discussion, and gives a handle to the 93 rows
that have none. Setting 3 stores a 3; there is no clear, as for a topic. The ask's
own priority does not move its issue or discussion: it is about this request.

`PUT /v1/operator/fleet-asks/{ask_id}/priority`, body `{"priority": 1..5}`:
operator admin only, else 403; 404 for no such ask; 409 `not_queued` once placed;
400 outside 1..5. A change is logged in the hub's event log with who and the old
and new value.

**Across workspaces.** `askDiscussion` and `askListPriorities` also read the
other workspaces' topics from the operator workspace, as `followTopicPriority`
already does, so a priority set on another workspace's discussion reaches its
ask. One match or none, never guessed (panel F3 stands). Row Q2.

**On a lane.** The Prio cell of the Lanes table (3.14) becomes the same 1..5
chooser for whoever may set it. A lane has no priority of its own (3.14: the
highest of its issues), so:

| the lane has | the chooser writes | so |
|---|---|---|
| a discussion | that topic's priority, in the workspace that holds it | its issues follow at once, and every lane and queued ask of that discussion with them (spec 150 3.4 item 4). The cell says so in its hint: this changes the discussion |
| only its own issue (topic `unknown`) | that issue's priority | that lane only |
| neither (a role seat, a `BOX-n` row) | nothing; a dash, no chooser | as 3.14 |

`PUT /v1/operator/fleet-lanes/{agent_id}@{agent_box}/priority`, operator admin,
because the plain topic PUT cannot reach a topic of another workspace from the
operator's session (its read door answers 404). A workspace's own staff use the
topic PUT, with its policy "Who can archive topics" (spec 150 D8).

Raising a running lane does nothing to the lane's work except what 3.22.9 gives it.

#### 3.22.7 Drag: a request's exact position

**What is stored.** New nullable `fleet_asks.queue_rank` (bigint), plus `rank_by`
and `rank_at`, which name who dragged **this** row. Order, `askPositions`:

1. effective priority (poll Q5 A stands: priority first);
2. `queue_rank`, ranked rows first, lower first;
3. the class rank, then `enqueued_at`, then `ask_id`, as today.

**The move.** `PUT /v1/operator/fleet-asks/{ask_id}/position`, body
`{"before": "<ask_id>"|null, "after": "<ask_id>"|null}`, the row's two neighbours
as the page saw them. In one transaction, with the role's queued rows locked:

- a neighbour that is no longer adjacent, or no longer queued: 409
  `stale_position`, nothing changes, the page re-reads and says so;
- the moved row **takes the priority of the row it now sits directly above**
  (of the row above it, when it lands last), written as its own priority, so a
  drop across a priority line is what it looks like;
- it gets a rank between its neighbours. Every unranked row of that priority above
  it gets a rank in its current order, because a rank cannot sit below an unranked
  row. Those rows get no `rank_by`: nobody dragged them, and their order has not
  changed;
- ranks use gaps of 1024; when a gap runs out, that priority's ranks are renumbered
  in the same transaction.

**How the placer honours it.** It already reads the hub's order. Only the band
pick changes (3.22.8, row Q1): a head with a `rank_by` is taken as it is.

**Against each thing the row can meet:**

| it meets | what happens |
|---|---|
| a band | a head that was dragged, or has priority 1, is taken past the bands. A dragged row that is **not** the head does not stop the band pick while the head has neither. So the position is exact in the line, and a band may still take a row out of the line below an undragged head. The owner's bands stay binding on everything he did not touch (msg `8cb6cc7d`) |
| a hold (vendor quota, a pinned box past overflow, weekly limit) | it keeps its place and the next row is tried, as today (`spl_spawn_place_take_next`, SPL-4265), and Waits on names the hold. A dragged row never stops the line |
| no room (ceiling 40, the gap after a launch, the load target) | it waits at its place: no row is placed, as today. Neither drag nor priority 1 makes room |
| a new arrival | it goes after every ranked row of its priority. An arrival of **higher** priority goes ahead of them, by rule 1, so a dragged row's number can grow; its place among its own priority does not |
| a new arrival behind a held row | the held row keeps its place in the line. A row behind it, a new arrival included, may be placed first while the hold lasts, as today, within `SPAWN_PLACE_HOLD_TRIES` tries a tick (default 5, `spl-spawn-place.func.sh:216`). The line's order does not change |
| its priority changing (set on the row, or its discussion's newer) | `queue_rank` and `rank_by` are cleared: a new decision, and it joins the new priority by rule 3. Other rows keep theirs |
| a stalled placement back in line | keeps its rank (the column is not touched, as `enqueued_at` is set once) |
| closing | the rank goes with the row; no renumbering, the gaps are harmless |

**Who may drag.** An operator admin, in the page. An agent has no drag door. When
the owner asks in words ("put this one ahead"), the dispatch holder uses the same
op through `ask_op position`, with the owner's msg id required and recorded in
`rank_by`, as `SPAWN_BYPASS` does today.

**Not only a mouse.** HTML drag does not fire on a phone and has no keyboard. Each
row also has Move up, Move down and "Move to position" (a number), all the same
PUT.

#### 3.22.8 The band pick, and why things slow

**An owner's top priority beats the band pick.** `spl_spawn_place_band` gets one
more early return, beside `ci` and flagged: a head with effective **priority 1**,
or with a `rank_by`, is returned as it is. All 48 t1 priorities are the owner's
(3.22.2), and he said a bypass is his to make explicitly (msg `8cb6cc7d`), so
setting 1 or dragging is that act. How often: of the 896 asks with an `enqueued_at`
the hub still keeps, 44 sit on a priority 1 discussion, about 5%. The bands keep
the rest. Priority 2 stays under the bands.

- A `ci` row ranks as priority 1 in `askPrio`, first by its class rank: trunk red
  must not wait behind the owner's priority 1 rows. The rules row says the placer
  "takes a `ci` row first"; priority first changed that without saying so. This is
  a choice this spec adds; the holder may ask the owner.
- "You have to keep track for me" (msg `8cb6cc7d`): each such pick writes a line to
  `bypass.tsv` (time, ask id, `prio1:<set_by>` or `drag:<rank_by>`, the holder)
  and one log line; `do_spl_spawn_share` counts it.
- The rule's one home is `fleet-rules-index.md` (the spawn queue row); Q1 changes it.

**A hold the hub can read.** One new column `fleet_asks.hold_reason`, written by a
new op `ask_op holds` with the whole map of asks to reasons, only when that map
changed since the last tick, so a quiet tick writes nothing. The Waits on column
reads it; empty means room.

**The last tick.** One row per fleet, overwritten: `fleet_place_state` (`at`, the
outcome class below, the free text of the log line, the ask). It is the line on top
of the page, "at 00:16:51Z the placer placed 369f326d", or "held: ...". It is
written at most once a minute by the tick that already runs.

**Why it slows: only what was measured.** What the tables can say today, the first
reading (all prd unless named; "placed" = `state='done'`, reason `placed:%`, by
`updated_at`; landed = `git log origin/master`, committer date, UTC, on
`fe0455e48`; load = mean of `load5 / cpus`, `box_stats`; CI = workflow 10 on
master, `gh api`, success and failure runs, median minutes, read for 11-03, 11-05
and 11-06 here, and 20 on 10-30):

| day | landed | enqueued | placed | median wait, min | p90 wait, min | load % sat | load % box-a | CI |
|---|---|---|---|---|---|---|---|---|
| 10-31 | 103 | 126 | 131 | 49 | 795 | 294 | 203 | - |
| 11-01 | 87 | 98 | 88 | 40 | 202 | 136 | 129 | - |
| 11-02 | 99 | 156 | 110 | 40 | 270 | 185 | 145 | - |
| 11-03 | 72 | 96 | 76 | 99 | 1815 | 119 | 162 | 19 |
| 11-04 | 113 | 162 | 128 | 167 | 2672 | 231 | 204 | - |
| 11-05 | 161 | 151 | 161 | 54 | 1264 | 212 | 169 | 21 |
| 11-06 | 35 | 71 | 52 | 119 | 1225 | 190 | 88 | 20 |

What this shows and does not:

- **More goes in than comes out:** 860 enqueued against 746 placed over those 7
  days, and 120 wait, 52 of them over 3 days.
- **The p90 wait rose,** from 202-795 min to 1225-2672 min from 11-03 on. The
  median did not rise steadily.
- **Landings did not fall day by day.** They swing from 72 to 161; 11-06 is the one
  low day, with no landing from 09 to 17Z. Its cause was not measured. box-a wrote
  112 `box_stats` samples that day against about 280 on most others, but 99 on 11-01
  with 87 landed, so that is no explanation. "Slower every day" is not shown over
  this week, and one week cannot prove or disprove a longer trend.
- **The CI gate did not slow:** median 19-21 min on the 4 days read (n = 44..78 runs
  a day). The pre-push hook's time is not stored anywhere, so it is **unknown**.
- **Load is high.** A daily mean of 88-294% of cores; box-a's high mark read 90% in
  the placer log, sat's was not read. What that costs in wait is not measured: the
  log has no time (3.22.2). That gap is the point of Q10.
- The wait counts only rows that were placed, so the 120 still waiting are left out
  and it reads low. Closed rows are pruned after a week, so 10-31 is partial.

**The view.** A flow table on the Queue tab, one row per day, 30 days, numbers and
no written cause: the page never says "because". Its reader compares columns. What
each column needs:

| column | source | exists today |
|---|---|---|
| enqueued, placed, waiting at day's end, wait p50 and p90 | `fleet_asks`, by a daily rollup before the week's prune | yes |
| landed | `git rev-list --count` on origin/master | yes |
| CI p50, p90 and reds, workflow 10 | `gh api`, once an hour at most (the shared token's limit) | yes |
| box load, per box | `box_stats` | yes |
| tick minutes per outcome: placed, ceiling, gap, load target, vendor limit, agy quota, pinned box, one at a time, empty | a new line per tick, with its time, in `<asks dir>/place-ticks.tsv` | **no** |
| pre-push minutes, p50 and p90 | a new line per push from `do_spl_push_master`, `<spool root>/push-times.tsv` | **no** |

`do_spl_flow_daily` (csi-spl-orc, hourly on the dispatch holder's box) reads them and
upserts `fleet_flow_daily` (fleet, day, metric, box, value, n), one row per metric
per day. It is a rollup, so the hub adds no per-tick writes. The tick outcome is the
one reason that tick took no row or placed one: exactly one per tick, so a day's
minutes add up and the row says how many ticks it saw. A day with fewer than 1000
ticks is marked partial, as the holder's box moves and its files stay behind.

#### 3.22.9 Resources: what priority gives a lane

**Decided (O3 = A, section 7): a lower number gets more.** The owner's "lower
priority would mean using more resources" means the number: priority 1, the highest
today (3.14), gets the most agents.

**What can be given,** read from the code:

| lever | today | with priority |
|---|---|---|
| place in line | priority first | as now, and 3.22.8 for priority 1 |
| agents for subtasks | a lane may ask for a spawn; nothing ties it to priority | new, below |
| width of a work group | `GROUP_WIDTH` 1..9 per epic, by hand | not tied in this spec: a group's rows run at their own priority |
| box room, the 40 ceiling, the load target | hard stops | **unchanged.** Priority takes room from other lanes; it never makes any |
| vendor quota, the data rule, the language rule | hard stops | unchanged |
| a running lane of another priority | runs on | unchanged: no lane is stopped to free room, because a stopped lane can lose its unpushed work |

**Agents for subtasks** ("even if that would require spawning new agents"). A lane
may queue helper lanes up to an allowance by its current priority, cnf
`env.box.prio_helpers` (starting values, for the owner to change):

| prio | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| helpers at once | 3 | 2 | 1 | 0 | 0 |

In code, not in a brief (the owner's rule: orchestration is if-else, not
judgement): `do_spl_spawn_enqueue` with `SPAWN_PARENT_LANE=<id>` reads the parent's
priority, counts its open helpers and refuses above the allowance. A helper is a
normal request: its own brief, issue and lane, `Kind:` and vendor by
`do_spl_lane_mix`, with the parent's discussion, so it follows the parent's
priority; the data, language and scope rules apply as to any lane. A row in the
Queue table shows its parent. Raising a lane changes its allowance on its next
enqueue; the lane is told once, by a spool note, that it now may. Lowering it stops
no helper already running.

What this costs: helpers count against the 40 and against the load target, so with
the queue full they slow everything else. Nothing here measures whether a helper
shortens a lane; Q11's table shows only the total.

#### 3.22.10 Cases

All planned. A red control is the check that fails on master today, or the plant
named.

- **C102** (Q3) `GET /v1/operator/fleet-queue` as an operator admin lists the rows;
  a member, or an admin of another workspace, 403. Red: no route.
- **C103** (Q3) the rows' order and count equal `do_spl_spawn_queue`'s
  on one seeded queue. Red control: a planted filter on `class` makes them differ.
- **C104** (Q3) an ask closed `placed: c-101@box-a` sends `lane`; a reason `dead:
  c-101@box-a` and `placed: nonsense` send none. Red: no field.
- **C105** (Q4) `MONITORING_TABS` has `queue` right after `lanes`; a plain member
  has no Queue tab. Red: `monitoring-tabs.test.mjs` order.
- **C106** (Q4) mock fleet: the columns in 3.22.3's order, a discussion and lane
  link, no sideways page scroll at 1440 and 390 px. e2e; red: page absent.
- **C107** (Q4) no Queue code in the initial download. `perf-budget.py` and the
  e2e chunk check. Red control: a planted static import.
- **C108** (Q7) the Plans route lists a `todo` and an `eval` issue
  by priority, then age. Red: no route.
- **C109** (Q7) a `needs-owner`, an `epic` and a human-assigned
  issue are absent. Red control: the filter taken out.
- **C110** (Q7) an issue an ask holds is in Requests only, an issue
  a live lane holds in neither; each row in one table. Red control: as C109.
- **C111** (Q2) effective priority on the memory store and Postgres: own only, 2;
  discussion only, 4; both, the newer; neither, 3, with each `priority_source`.
  Red: the own column absent.
- **C112** (Q2) the priority PUT: 1..5 stored with who; 0 and 6 are 400; a placed
  ask 409; a member 403. Red: no route.
- **C113** (Q2) an ask on `dispatch-<8 hex>` of another workspace's topic gets that
  discussion, and its priority reaches the queue; a prefix of two topics, none. Red
  on master: `discussion` NULL.
- **C114** (Q5) a lane on a discussion: the chooser writes the topic's priority, its
  issues and a queued ask of the topic follow; a lane on `unknown` with an issue
  writes the issue; a role seat shows no chooser. Red: no route.
- **C115** (Q2) a move: rows A B C D with no rank, D dropped between A and B: order A
  D B C, A has a rank and no `rank_by`, D has both; B and C unranked. Red: no route.
- **C116** (Q2) drop across a line: a prio 4 row dropped directly above a prio 2 row
  reads 2 with the source own. Red control: without the write it snaps back on read.
- **C117** (Q2) a stale neighbour is 409 and changes nothing; two moves at once both
  end in a valid order. Postgres. Red control: the lock taken out, the race test.
- **C118** (Q2) a new arrival of the same priority lands after the ranked rows; a
  higher one ahead; a priority change clears the rank; a stall back in line keeps it.
  Red: no ranks.
- **C119** (Q1) the band pick, `spl-spawn-place-argmax.tst.sh`: 3.22.2's two rows, a
  bug under its band at position 2 and a priority 1 feature at position 1: picks the
  feature. The same with priority 3: picks the bug, unchanged. Red on master: picks
  the bug, as the log of 00:13Z. A `bypass.tsv` line is written.
- **C120** (Q1) a dragged head is taken; a dragged row at position 3 under a plain
  head does not stop the band pick. The test stubs the row until Q2 lands. Red
  control: the early return taken out.
- **C121** (Q2) a `ci` row at no priority is position 1 ahead of a priority 1
  feature. Red on master: priority first puts the feature ahead.
- **C122** (Q3) `ask_op holds`: a map sets `hold_reason`, a second same map writes
  nothing (a counting store), a row left out is cleared. Red: no op.
- **C123** (Q10) a fixture of 3 days of `place-ticks.tsv`, `push-times.tsv`, a queue
  and `box_stats`: the rollup's metrics equal hand-counted values; a second run
  changes nothing. Red control: a tick counted twice.
- **C124** (Q11) the flow table on the mock: 30 rows, a partial day marked, no
  sentence of cause. Red: page absent.
- **C125** (Q9) `SPAWN_PARENT_LANE` at allowance is refused with a
  named reason, one under is queued with the parent's discussion; a lane raised
  from 4 to 1 may then queue 3. Red: no check.
- **C126** (Q12) a fixture plan of two rows, one already naming an `SPL-n`: a run
  files one issue, status `eval`, under the plan's epic and linking its discussion;
  a second run files none; a plan with no `Epic:` is refused. Red: the plan's rows
  are not read.

#### 3.22.11 Rows Q1-Q12

Disjoint where the order allows. Every row with web UI text carries: "agy language
review BEFORE land: push review/<slug>, ask the dispatch holder for the agy reviewer,
land only after its PASS".

| row | kind | files (only these) | tests and red control | after | cases |
|---|---|---|---|---|---|
| Q1 prio 1 beats the band | `simple_coding`, class bug | `orc/run/spl-spawn-place.func.sh` (`spl_spawn_place_band`); `orc/tests/spl-spawn-place-argmax.tst.sh`; `csi-spl-doc/doc/md/fleet-rules-index.md` (spawn queue row) | the argmax test; red on master: picks the bug | - | C119, C120 |
| Q2 store: priority and rank | `complex_coding` | new `rdb/<next>_fleet_ask_queue_order.sql` (`priority`, `priority_by`, `priority_at`, `queue_rank`, `rank_by`, `rank_at`, `hold_reason`, all nullable); `store/fleet_ask.go`, `store/fleet_ask_postgres.go`, the memory store; `hub/box_ask.go` (`askDiscussion`, `ask_op position`); new `hub/fleet_ask_order.go` + `_test.go`; one line in `hub/server.go`; `hub/openapi.json`. `PRE_PUSH_TIER=full` | Go, memory and Postgres; red: C111-C118's | - | C111-C113, C115-C118, C121 |
| Q3 the queue route, holds | `complex_coding` | new `hub/fleet_queue_view.go` + `_test.go`; one line in `hub/server.go`; `hub/openapi.json`; `hub/box_ask.go` (`ask_op holds`); `orc/run/spl-spawn-place.func.sh` (the holds send only); `orc/tests/spl-spawn-queue.tst.sh` | Go; red: no route, C103's planted filter | Q2 | C102-C104, C122 |
| Q4 the tab, read only | `complex_coding` | `wui/utils/monitoring-tabs.mjs`; new `wui/pages/monitoring/queue/index.vue`, new `wui/utils/monitoring-queue.mjs`; the client call; `csi-spl-wui/i18n/locales/*.json` (new keys only); `tests/unit/monitoring-tabs.test.mjs`, new `tests/unit/monitoring-queue.test.mjs`; `tests/e2e/monitoring-costs.test.mjs`. agy language review BEFORE land: push review/<slug>, ask the dispatch holder for the agy reviewer, land only after its PASS | e2e and unit; red: page absent, C107's planted import | Q3 | C105-C107 |
| Q5 chooser on request and lane | `complex_coding` | `wui/pages/monitoring/queue/index.vue`, `wui/pages/monitoring/lanes/index.vue` (the Prio cell), `wui/utils/monitoring-queue.mjs`; the client call; new `hub/fleet_lane_priority.go` + `_test.go`; one line in `hub/server.go`; `hub/openapi.json`; locale keys. agy language review BEFORE land: push review/<slug>, ask the dispatch holder for the agy reviewer, land only after its PASS | Go and e2e; red: no route, no chooser | Q4 | C114 |
| Q6 drag | `complex_coding` | `wui/pages/monitoring/queue/index.vue`; `wui/utils/monitoring-queue.mjs` (the move's two neighbours, `stale_position`); locale keys; `tests/e2e/monitoring-costs.test.mjs`. agy language review BEFORE land: push review/<slug>, ask the dispatch holder for the agy reviewer, land only after its PASS | e2e, with the mouse and with Move to position, at 1440 and 390 px; red: no handle | Q5 | C115 through the page |
| Q7 Plans read | `complex_coding` | new `hub/fleet_queue_plans.go` + `_test.go`; `wui/pages/monitoring/queue/index.vue`; locale keys. agy language review BEFORE land: push review/<slug>, ask the dispatch holder for the agy reviewer, land only after its PASS | Go and e2e; red: C109's filter taken out | Q4 | C108-C110 |
| Q8 a set plan passes the filler | `simple_coding` | `orc/run/spl-spawn-fill.func.sh` (the gate at :72); `orc/tests/spl-spawn-fill.tst.sh`; `csi-spl-doc/doc/md/fleet-rules-index.md` (filler row) | the filler test: prio 2 with a queue queues one, prio 3 none; red on master: none | - | - |
| Q8b workspace readers | `complex_coding` | new `hub/workspace_queue_view.go` + `_test.go`; `wui/utils/monitoring-tabs.mjs`; `wui/pages/monitoring/queue/index.vue`. No new text key | Go, as C25/C26; red: a member of w2 reads w1's row | Q4 | - |
| Q9 helpers by priority | `complex_coding` | `orc/run/spl-spawn-enqueue.func.sh`; `orc/tests/spl-spawn-queue.tst.sh`; `csi-spl-cnf/csi-spl/all.env.yaml` (`prio_helpers`); `csi-spl-doc/doc/md/fleet-rules-index.md`. No UI text | the enqueue test; red: no check | - | C125 |
| Q10 flow record | `complex_coding` | `orc/run/spl-spawn-place.func.sh` (one line per tick, `fleet_place_state`); `orc/run/spl-push-master.func.sh` (one line per push); new `orc/run/spl-flow-daily.func.sh` + `orc/tests/spl-flow-daily.tst.sh`; new `rdb/<next>_fleet_flow_daily.sql`; new `hub/fleet_flow.go` + `_test.go`; `orc/cnf/box-crons/box-crons.manifest`. `PRE_PUSH_TIER=full` | the fixture; red: a tick counted twice | Q3 | C123 |
| Q11 flow view | `simple_coding` | `wui/pages/monitoring/queue/index.vue` or a new child component; `wui/utils/monitoring-queue.mjs`; locale keys. agy language review BEFORE land: push review/<slug>, ask the dispatch holder for the agy reviewer, land only after its PASS | e2e; red: no table | Q10, Q4 | C124 |
| Q12 a signed plan files its issues | `simple_coding` | `orc/run/spl-spec-import-issues.func.sh`; `orc/scripts/spec-import-issues.py`; `orc/tests/spec-import-issues.tst.sh`; `csi-spl-doc/doc/md/lane-issue-and-docs.md` (the signing step). No UI text | the import test; red: the plan's rows are not read | - | C126 |

Order: Q1 at once and alone. Q2, then Q3, Q4, Q5, Q6. Q10 after Q3 (both touch the
placer) and Q11 after it. Q7 after Q4. Q8, Q9 and Q12 at any time. Q4, Q5, Q6, Q7 and Q11 touch one
page and the locale files, so they land one after another.

### 3.23 A launch that crosses boxes keeps its lane row (SPL-5007)

`spawn-window.sh` hands the launcher `SPAWN_LANE_TOPIC`, `SPAWN_LANE_SCOPE` and
`SPAWN_LANE_FILES` through the pane's environment. A lane placed on another box
goes through `spawn-remote.sh` instead, whose request carried only kind, title,
workdir, slug and expiry, so the far launcher read the brief alone. A brief with
no discussion in it (c-023, `Topic: dispatch-refactor-r26`, n = 1) then lost its
row to 3.21 while the spawn reply still said ok.

- **The request carries them**: optional header lines `topic:` (from
  `SPAWN_LANE_TOPIC`, else `LANE_ISSUE_TOPIC`, the order `_spawn_lane_put` uses),
  `scope:` and `files:`, each only when set. A scope or a file list is flattened
  to one line, so it cannot add a header or end the header block, and the sender
  cuts a scope to the hub's 500 bytes on a character boundary, in any locale.
  Both sides refuse a topic outside the hub's `[A-Za-z0-9_-]`, up to 64, a scope
  over 500 bytes (the receiver's case is a request made by hand), and a control
  character in the other two.
- **Older ends keep working**: a request with none of the lines launches as
  before, and a receiver from before this ignores them. A sender's fix does
  nothing until the far box runs this code too.
- **The ok reply reports a refused row**: `warn: <line>` when this spawn wrote
  `<id>/lane-unlinked.log`, printed on the requester's stderr; stdout and exit 0
  stay, because the lane did start. The log is on the far box, out of the
  spawner's reach, which is how the case above went unseen. Best effort: only
  claude has a start check that waits for its launcher, so another kind's line
  can come too late for the reply, and a refusal only the hub sees (`lane.log`,
  e.g. a topic that names no discussion) is not reported.
- **The local case of 3.21 is narrower than it reads**: `spawn-window.sh` starts
  its launcher in a tmux pane, so that WARN goes to the pane's stderr, and reaches
  the spawner's only when the launcher is run directly. Read from the code, not
  changed here.
- **A second path, not fixed here**: a claude handover in mode A
  (`spl-lane-handover.func.sh`, op `resume`) starts `restore-claude.sh` over ssh.
  It sends no spawn request and runs no `_spawn_lane_put`, and it writes no
  `lifetime/brief.md` on the target, so the next rotation records "no brief was
  recorded at spawn". The mistral handover copies that brief; the claude one does
  not. It matches c-156 (branch `c-156-handover`, n = 1), read from the code; that
  lane's files were not read.

Cases (`spawn-agents/tests/test-spawn-remote.sh`):

- **C127** (case 10) the far launcher gets all three, with the receiver's
  environment cleared of them; with none set, none is invented; a request from an
  older sender is served; a `topic:` line in the brief is not a header; newlines
  in a scope cannot rewrite the slug or kind; a hostile topic, scope or files line
  is REJECTED and never spawned. Behind serve, the real `spawn-claude.sh` dry
  plans `--topic <uuid>`; its control, the same brief with no topic sent, prints
  `LANE ROW REFUSED`.
- **C128** (case 11) a refused row is on the requester's stderr with stdout and
  exit 0 unchanged; a line older than this spawn is not reported.
- Red control: the test on the code before this change, 17 of 77 failed, among
  them the far launcher's fields and the real launcher's `--topic`.

### 3.24 A lane's close keeps the topic its row already stores (SPL-5080)

Seen on prd 2026-11-08 (n = 3 lanes, from the lane brief): closing a lane
row was refused with `bad_frame (topic <id> names no single discussion (rdb
0264: a lane needs one))`, by `lane-map.sh done` (c-810, c-812) and by the
reaper (c-842), which retries from `.reap/lane-close.tsv` while the retired
seat still reads live on the map.

Why: a lane opened with its topic's 8 hex is stored with the full uuid
(`laneTopic`, `TopicsByPrefix` of the tenant). When that discussion is a
version-5 uuid of the operator's OWN workspace, a later put that resends the
stored uuid (`spl-lane-put.func.sh` reads the row and sends its topic back)
goes down the relay-hash path: it is no relay hash of a topic, and
`laneTopicIsElsewhere` skips the operator workspace, so it resolved to none
and 3.21 refused it. The live map read 2026-11-10 (`LANE_FORMAT=json
LANE_ALL=1 ./run -a do_spl_lane_map`, n = 1 read) held 8 of 953 rows with a
version-5 topic, c-842, c-381 and c-383 among them, all `live`.

What changes: when the sent topic resolves to none, the hub keeps it if the
row of that agent and box already stores exactly it (`laneTopicPut`,
`internal/hub/box_lane.go`): the hub took that topic when the row was
opened, so a close or a re-put of the same row is not refused. A new row,
and a put naming a topic its row does not hold, still go through 3.21
unchanged: the rule protects a lane's creation, and a relay hash is still
never stored as a new lane's discussion.

Not changed: a new lane that names a version-5 topic of the operator's own
workspace by its full uuid is still refused; by its 8 hex it is stored.

Cases (`internal/hub/lanes_topic_kept_test.go`,
`TestLanePutKeepsItsOwnV5Topic`; Memory, and Postgres under
`SPOOL_TEST_PG_DSN`):

- **C129** a live re-put with the stored full uuid keeps it.
- **C130** the close (`state: done`) with the stored full uuid keeps it.
- **C131** a new row naming that version-5 uuid is refused as before.
- **C132** a close naming a version-5 uuid its row does not hold is refused.
- Red control: on master 4522b6b1e, C129 and C130 were refused with "names
  no single discussion"; C131 and C132 passed.

### 3.25 A phone reads each lane as a dense card (SPL-5235)

Owner HUM-10, t1 389ad5fd, msg e3fad8e4: "The lanes view on mobile should
be improved similarly to how the releases listing was improved on mobile:
maximum utilization of space." No earlier lane or ref changed this layout
(searched: issues, the page's git log, every branch name; the only phone
change was SPL-4842, Refresh inside the tabs' row).

- At the one phone breakpoint (`max-width: 820px`) the same table, its
  cells, links, `data-test` names and the row's LaneDialog click unchanged,
  is laid out by CSS only (`pages/monitoring/lanes/index.vue`): table,
  head and body are blocks, each row a flex card across the list's whole
  width, in three short lines:
  1. prio, agent@box, vendor, state ... updated (end);
  2. discussion (cut, title holds it) ... issue keys, origin issue;
  3. scope (cut) ... box, workspace (cut at 35 %), last active (end).
  An empty origin cell is not drawn. The two ages carry their column name
  as a `title`. Card text 0.8125rem, issue keys 0.75rem.
- The three lines hold for any number of issue keys (W1 of the R7 review):
  the keys stay on line 2, at most 45 % of it, on one line; the keys that
  do not fit are cut with an ellipsis. The cell's `title` lists every key,
  and the LaneDialog (the agent's click) lists them all as well. Before
  this, a lane with 3 or more keys stacked them one per line, 4 to 6
  lines at 320 px.
- The sort names wrap above the cards as a row of buttons; the filter row
  wraps under them, the text search first on its own line. (Superseded by
  3.26: a phone sorts and filters in the Event log's bar and sheets, the
  names stay in the DOM for readers, visually hidden.)
- Nothing scrolls sideways at 320, 360 and 390 px, the page nor the list;
  the desktop table is unchanged.
- No new text key.
- Test: `csi-spl-wui/tests/e2e/monitoring-lanes-phone.test.mjs` (P1-P6 at
  320/360/390, D1 at 1440). Red control: on the code before it, P1b and P2
  fail at all three widths (the list 1703 px wide in a 308..378 px box).
  P6 reads the mock `spool.mock.fleet_lanes=keys`, which adds lane c-404
  with 4 issue keys; it is red on the card layout before the cut.

### 3.26 Sort and filter as the Event log; Refresh where Clear log is (SPL-5276)

Owner HUM-10, t1 e1e97af9 (03:54Z): msg 7ccb6bfa "Sorting and filtering in
lanes should behave exactly as sorting and filtering for the event log.",
msg 2dedcc73 "Also, the refresh button should be in the same place where the
clear lock button is." The page has no "clear lock" button; the Event log's
**Clear log** (`pages/monitoring/events/index.vue`) is the one it names.

What differed, read on origin/master `9cda5fdae`:

| | Event log (the reference) | Lanes before |
|---|---|---|
| sort control | the column name is a button, ▲ / ▼ after the sorted one | the Issues sheet's `SheetSortButton` (a faint ▲ on hover) |
| sort cycle | none -> asc -> desc -> none, a new column asc | the same (`cycleSort`) |
| default order | newest first (When) | the hub's, newest write first |
| filters | one under every column: a text box (part, any case) or a select (exact, All first) | 6 controls: box, vendor, state, age, workspace selects and one text box over 4 columns; agent, prio and last active none |
| Clear filters (desktop) | on the tabs' row only while a filter is on, before Clear log | always on the row, disabled with no filter |
| phone | a bar "Sorted: <column>, <direction>" + Sort and Filters buttons (a dot while filtered), each a bottom sheet; Clear filters in the Filters sheet | the names and the filter row wrapped above the cards |
| URL | none | sort, dir and each filter (3.15) |
| Clear log / Refresh | Clear log last on the tabs' row (desktop), fixed at the bottom centre above the dock (phone) | Refresh first on the tabs' row, on a phone too |

Now:

- One column sheet for both tables, reused, never copied:
  `wui/utils/column-sheet.mjs` (the sort cycle, its mark and `aria-sort`,
  the phone bar's words, one text or choice filter per column, the values a
  choice offers), `wui/components/SheetHead.vue` (the names and the filter
  row), `SheetFilterField.vue` (one filter), `SheetPhoneBar.vue` (the bar and
  its two sheets), `PhoneDockButton.vue` (the bottom-centre action). The
  Event log's page and `utils/event-sheet.mjs` use them with their
  behaviour, text and `data-test` names unchanged.
- Lanes' columns (`LANE_SHEET_COLUMNS` in `wui/utils/monitoring-lanes.mjs`):
  text filters on agent (id@box), scope, discussion (title and id), issues
  (the keys), origin; choice filters on box, prio, vendor, state, workspace
  (by name, matched on the id), and on Updated and Last active an age
  (within 1 h, within 24 h, over 24 h; Last active against the answer's
  `as_of`, a lane with none matches no age). The one text box over four
  columns is gone. The sort values stay 3.14's (prio 1 first, an empty cell
  last both ways, names with numbers). No sort reads "Updated, newest first".
- The URL (3.15) keeps working: each filter is a parameter named as its
  column (`agent`, `box`, `priority`, ..., `workspace`); an old link's `age`
  reads as `updated`, its `text` is dropped, and neither is written back.
- Refresh takes Clear log's place: on a desktop the tabs' row reads the age,
  Clear filters (while a filter is on), Refresh last; on a phone the age
  stays on the row and Refresh is fixed at the bottom centre above the dock,
  with room under the last card. Every column, the LaneDialog, the deep link
  `?lane=`, the stale line and "n of total" are unchanged.
- No new text key.
- Tests: unit `tests/unit/column-sheet.test.mjs` (the shared rules, the same
  clicks and filters through both tables), `monitoring-lanes-sort-filter`,
  `monitoring-lanes-url`, `event-sheet` (unchanged, green); e2e
  `tests/e2e/monitoring-lanes-like-events.test.mjs` (S1-S4 the same steps on
  both pages at 1440 and 390, R1-R2 Refresh where Clear log is),
  `monitoring-lanes-phone`, `monitoring-lanes-url`,
  `monitoring-head-actions-row`, `monitoring-costs`. Red control: the bundle
  of origin/master fails S1, S3, S4, R1 and R2.

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
| C2 | B1 | the same page: left edge of the first tab label minus right edge of the heading text (SPL-4811: of the separator's text, which starts at the heading's end +-1 px) | the bar is on the next row | 20 px +-2 (SPL-4811: 12 px +-2), the two `top`s within 4 px | e2e: the two rects' `top`s differ by a row today |
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

**O2 and O3 (3.22).** Asked as one form through the dispatch holder:

```poll
O2. Where do the Queue tab's plans come from?
(A) Open issues; a planner files an issue for each round and spec row when its plan is signed (recommended: the one place that already has a priority and a UI)
(B) Read the plan files in git as they are; no priority can be stored on those rows
(C) A new plans table, with its own priority beside the issues'
(D) Only the work groups' waiting rows
```

```poll
O3. "Lower priority would mean using more resources": which way?
(A) A lower NUMBER gets more: prio 1, the highest today, gets the most agents
(B) A lower IMPORTANCE gets more: prio 5 gets the most agents
```

**O2 and O3 answered: A and A.** Owner HUM-10, t1 topic `c1400bbb`, poll `ea4fd300`:

| msg | text |
|---|---|
| `9d3f3f35` | "Answer 1: A — Open issues; a planner files an issue for each round and spec row when its plan is signed (recommended) Answer 2: A — A lower NUMBER gets more: priority 1, the highest today, gets the most agents" |

So: plans are open issues (3.22.5, rows Q7, Q8), and the filing is row Q12. A lower
number gets more agents (3.22.9, row Q9). No row waits on the owner now.

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
