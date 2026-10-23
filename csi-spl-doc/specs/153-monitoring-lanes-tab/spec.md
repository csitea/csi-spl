# 153 Monitoring: the tab row beside the heading, and a live Lanes tab

Version v0.1 (2026-10-23). Step 1 of the owner rule for a big change: the
written spec, then the panel, then the build. Nothing in it is built.

Source: prd topic in the owner's workspace,
`topic:5e7b15c9-2995-427d-8b05-659762fbb9d8`. Issue: SPL-3075 (this spec),
epic SPL-2403. Each build row in section 5 gets its own issue when it is
placed.

Paths used below:

- `wui/` = `csi-spl-wui/src/`
- `hub/` = `csi-spl-api/src/go/spool-hub-api/internal/hub/`
- `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`
- `orc/` = `csi-spl-orc/src/bash/`

Every `file:line` was read on origin/master `2343dadbe`. Every prd count
was read on 2026-10-23 between 15:05Z and 15:20Z with
`ENV=prd ./run -a do_spl_db_query` (csi-spl-orc), n = 1 read each.

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
- `wui/assets/css/main.css:333-343`: `.feed-header` is a flex row, `gap:
  12px`, `padding: 12px 20px`, `min-height: 52px`. On a phone,
  `main.css:1003`: `padding: 4px 12px 4px 4px; gap: 6px`.
- `wui/assets/css/main.css:1581-1584`: `.monitoring-tabs` (flex, `gap:
  4px`, `padding: 0 16px`, its own bottom border) and `.monitoring-tab`
  (`padding: 8px 12px`, a 2px accent underline on the active one).
- Tests that find the bar by `data-test=monitoring-tabs`:
  `csi-spl-wui/tests/e2e/monitoring-costs.test.mjs:107` and
  `csi-spl-wui/tests/e2e/rail-order-default.test.mjs:341`. The unit test
  `csi-spl-wui/tests/unit/monitoring-tabs.test.mjs:24-26` pins the order
  `['agents', 'boxes', 'costs', 'tokens']`.

### 2.2 Data an active-lane list could read (A2)

What the hub has:

- **`fleet_lanes`** (`rdb/0096_fleet_lanes.sql:15-29`; key `(tenant_id,
  fleet, agent_id, agent_box)` since `rdb/0102_agent_at_box_key.sql:22`):
  one row per agent, `repo, branch, scope, files, topic, state live|done,
  writer_box, updated_at`. No issue key, no start time.
- It is written and read only over the box WebSocket: `lane_op put` and
  `lane_op list` (`hub/box_lane.go:13-23`, the row `LaneRow` :26-38). The
  only caller of `ListFleetLanes` is `hub/box_lane.go:132`. Only a box
  pinned in the tenant may call it (:22-23). **No HTTP route serves it,
  so the WUI cannot read it today.**
- The spawn path writes the row: `_spawn_lane_put`
  (`orc/features/spawn-agents/scripts/spawn-core.inc.sh:277-292`) runs
  `lane-map.sh put ... --topic "${SPAWN_LANE_TOPIC:-}"` in the background,
  best effort. `lane-map.sh done` sets `done` at the lane's exit
  (`orc/features/spawn-agents/scripts/lane-map.sh:55-59`).

What the prd data says (tenant `t1`, fleet `main`):

| measure | value |
|---|---|
| rows `state = live` | 212 |
| of those, `updated_at` within 1 h / 24 h / 7 days | 23 / 31 / 40 |
| of those, with a non-empty `topic` | 5 |
| rows `state = done` (pruned after a week, `0096:12-14`) | 1318, 14 with a topic |

So `live` alone is not "active": a lane that ends without `/exit-clean`
stays `live` (172 of 212 rows are older than 7 days). And the topic is
empty on 207 of 212 live rows: nothing sets `SPAWN_LANE_TOPIC` on the
normal spawn path (`grep -rn SPAWN_LANE_TOPIC orc/` finds it read at
`spawn-core.inc.sh:288,292` and `spawn-window.sh:151,400,403`, and set
only in tests). This lane's own row is an example: `c-898@sat`, `live`,
topic `''`.

Other hub routes, none of which carries a lane's topic or issue:

- `GET /v1/view/roster` (`hub/view.go:50`, tenant members): boxes, their
  agents and each agent's presence. The Agents tab reads it through the
  roster store (`wui/pages/monitoring/agents/index.vue`).
- `GET /v1/operator/fleet-tokens` (`hub/fleet_tokens.go:60`, operator
  admins only through `fleetLoadCaller`, `hub/fleet_load.go:120-139`): per
  agent `agent_id, vendor, model, box, last_active` and the burn. The
  Tokens tab polls it every `TOKENS_POLL_MS = 30000`
  (`wui/utils/monitoring-tokens.mjs:23`) while the page is visible
  (`wui/pages/monitoring/tokens/index.vue:96-119`).

What lives only on a box:

- `registry.tsv`, every agent id with its pane and run dir
  (`spawn-core.inc.sh:567,572`). Not pushed.
- The lane's issue key, `<spool root>/<id>/lifetime/issue`
  (written by the issue step, `orc/features/spawn-agents/scripts/spawn-window.sh:375-417`).
  This lane's reads `SPL-3075`. Not pushed to `fleet_lanes`.

### 2.3 Lane -> discussion -> issues (A3)

- An issue links its discussions in `issue_discussions(number, task_id)`
  (`rdb/0194_issue_discussions.sql:39-47`), indexed by topic (:49).
- Issue routes: `GET /v1/view/issues`, `GET /v1/view/issues/{ref}`, and
  `POST` / `DELETE /v1/issues/{ref}/discussions` (`hub/issues.go:797-807`).
  The list filters by status, label, assignee, priority, level and
  deadline; it has **no filter by discussion**.
- The lane issue's `assignee` is meant to be the lane
  (`orc/run/spl-lane-issue.func.sh:163-170`). In prd it is not: SPL-3075
  (this lane) reads `assignee = c-002@sat`, and of the 185 `wip` issues in
  `t1`, 0 have a lane id (`c-NNN`, `g-NNN`, ...) as assignee; 120 have a
  dispatch seat (`c-002` on its two boxes: 61 and 59) and 56 none. **So the
  hub cannot find a lane's issue from the issue side either.**
- All 185 `wip` issues have at least one `issue_discussions` row. SPL-3075
  links `5e7b15c9-...` (by `c-002`). So topic -> issues already works in
  the data.
- WUI links: a topic is `/t/<task_id>` (`wui/pages/t/[task_id].vue`;
  `discussionPath`, `wui/utils/issue-discussions.mjs:63-64`); an issue is
  `/issues?issue=<KEY>` (`issueHref`, `wui/utils/issue-key-links.mjs:40-44`).
  An issue shows its discussions (`wui/components/IssueDiscussions.vue`);
  **a topic does not show its issues** (`grep -rn issue wui/pages/t/`
  prints nothing).

### 2.4 Spec 143's reserved `/reporting/lanes` (T053)

- `wui/utils/reporting-tabs.mjs:25-26`: `lanes`, `/reporting/lanes`,
  `operatorsOnly: true`, `ready: false`.
- `wui/pages/reporting/lanes.vue:1-16`: the stub (T053, `d27cc331e`).
- Its scope (`csi-spl-doc/specs/143-reporting-section/spec.md:713-720`) is
  history: lanes spawned per day, landing success rate, duration per kind.

No clash: Reporting `/reporting/lanes` stays the history (counts over
days); Monitoring `/monitoring/lanes` is the live list (now, refreshed
every minute). Different paths, different tab lists, different label keys
(`reporting.tab.lanes` vs `monitoring.tab.lanes`). The hub view of
section 3.3 serves the live list only (panel question P6).

## 3. The design

### 3.1 The tab row on the heading's row (A1)

- `monitoring.vue`: the `<nav class="monitoring-tabs">` moves INSIDE the
  `<header class="feed-header">`, right after the `<h2>`, before
  `SectionClose side="end"`. The `data-test` values stay.
- 5 mm: a CSS millimetre is 3.78 px, so 5 mm is 18.9 px. The bar gets
  `margin-inline-start: 1.25rem` (20 px at the 16 px root), and the
  header's 12 px `gap` does not add to it (the nav's margin is the whole
  distance, e.g. a negative inline margin of the gap, or the gap moved to
  the other children). The first tab's own `padding-inline-start` (12 px)
  goes, so the first LABEL starts 20 px after "Monitoring".
- The bar loses its own bottom border and side padding; the header's
  border is the one line. The active tab's 2 px underline sits on that
  line.
- The end close X stays at the far end: the nav takes `flex: 1 1 auto;
  min-width: 0`.
- Phone (the `main.css:1003` block, header gap 6 px): the same row. The
  nav scrolls sideways INSIDE itself (`overflow-x: auto`, no scrollbar
  shown) when the tabs do not fit; the page never scrolls sideways; the
  heading never wraps under the tabs. 0.75rem (12 px) after the heading
  on a phone (panel question P5).
- The empty summary strip stays below the header, unchanged.

### 3.2 The Lanes tab (A2)

- A fifth row in `MONITORING_TABS`, after tokens: `{ id: 'lanes', path:
  '/monitoring/lanes', labelKey: 'monitoring.tab.lanes', operatorsOnly:
  true, ready: true }`.
- Page `wui/pages/monitoring/lanes/index.vue`, its own chunk.
- One row per ACTIVE lane: agent `id@box`, vendor, the scope (the brief's
  title), the discussion (topic title, linked), the issue key(s) (linked),
  the time since the row was written, and whether the agent is online.
- **Active** = `fleet_lanes.state = 'live'` AND the agent is a lane id
  (`^[cgamq]-[0-9]+$`; the `BOX-0` box row and old upper-case ids are left
  out) AND either the agent is online or `updated_at` is within 60 min.
  On today's data the 60 min part alone gives 23 rows instead of 212
  (2.2); the online part adds the long-running ones. The rule is panel
  question P1.
- Refresh: the page fetches every 60 s while the browser tab is visible,
  the way Tokens does every 30 s (`tokens/index.vue:96-119`), with
  "updated N s ago" and the same amber / red lag marks.
  `LANES_POLL_MS = 60000` in `wui/utils/monitoring-lanes.mjs`.
- Sort: newest `updated_at` first. Empty list: one line, "No active lanes".
- Who sees it: operator admins only (`operatorsOnly: true`), like Tokens:
  lane rows name fleet boxes, agents and the operator workspace's topics.
  The hub's 403 is the control; hiding the tab is only the UI. Owner
  question O1.

### 3.3 The hub view the tab reads

- `GET /v1/operator/fleet-lanes`, gated by `fleetLoadCaller` (an operator
  admin session or the operator service account), the same gate as
  fleet-tokens.
- Answer: `{ as_of, lanes: [{ agent_id, agent_box, vendor, scope,
  topic_id, topic_title, issues: [{ key, status }], updated_at, age_s,
  online }] }`, active rows only (3.2's rule; the 60 min cut-off is a hub
  constant).
- `issues` = the lane's own issue key (3.4) plus every issue that
  `issue_discussions` links to `topic_id` (one indexed lookup,
  `issue_discussions_task`), each key once.

### 3.4 Filling the row: topic and issue key (orc + rdb)

The view is empty of links while 207 of 212 rows carry no topic. So:

- `rdb/`: a new migration adds `fleet_lanes.issue_key text NOT NULL
  DEFAULT ''` (CHECK `''` or `^[A-Z][A-Z0-9]{1,9}-[0-9]{1,9}$`).
- `LaneRow` gets `issue_key`; `lane_op put` stores it.
- `lane-map.sh put` gets `--issue K`.
- `_spawn_lane_put` fills `--topic` from, in order: `SPAWN_LANE_TOPIC`;
  the topic the lane issue links (`LANE_ISSUE_TOPIC`, the value
  `spawn-window.sh:400` passes); the brief's first full topic uuid. It
  fills `--issue` from `lifetime/issue`, so the put runs after the issue
  step.
- A topic given as an 8-hex short id is resolved to the full uuid by the
  hub at `put`, or stored empty: a short id never reaches the WUI as a
  link.
- Stale rows: when an agent id is retired (`agent-id-retire.sh`) its row
  goes `done`. The 172 rows older than 7 days are closed once by a named
  dry-run-first action, never by hand (panel question P2).

### 3.5 Discussion -> issues (A3)

- The lane row's discussion link opens `/t/<topic_id>`.
- `GET /v1/view/issues?discussion=<task_id>`: a new filter on the existing
  list, served from `issue_discussions_task`. The issues list's access
  rules are unchanged.
- The topic header shows its linked issues as chips (`SPL-3075 wip`), each
  to `/issues?issue=<KEY>` (`issueHref`). None linked: no chip, no space.
- The lane row ALSO shows the issue keys (3.2), so the issue is one click
  away even before the topic chips land (panel question P3).

## 4. Cases

Every case is **planned**: none is built. "Master today" was read on
`2343dadbe` (code) and prd on 2026-10-23 (data). Each red control is the
check that FAILS on master today and passes once its row lands; (C) marks
a control that must pass on both.

| # | row | case | master today | expected | red control |
|---|---|---|---|---|---|
| C1 | B1 | `/monitoring/agents`, desktop 1280 px: `[data-test=monitoring-tabs]` is inside the header | a sibling after it | inside, same row | e2e: `nav.closest('header')` is null today |
| C2 | B1 | the same page: left edge of the first tab label minus right edge of the heading text | the bar is on the next row | 20 px +-2, the two `top`s within 4 px | e2e: the two rects' `top`s differ by a row today |
| C3 | B1 | phone 360 px, operator admin (5 tabs): heading and bar on one row, `scrollWidth <= innerWidth` | two rows | one row, the bar scrolls inside itself | e2e: the same-row check fails today |
| C4 | B1 | the end close X is the last element of the header row on desktop | yes | yes (C) | e2e reads `[data-close-side=end]` as the header's last child |
| C5 | B1 | `monitoring-costs.test.mjs` and `rail-order-default.test.mjs` find the bar by data-test | pass | pass (C) | the two files, unchanged |
| C6 | B2 | a dry-run spawn with a brief naming a topic uuid: the lane-map put line | `--topic ''` | `--topic <uuid> --issue SPL-n` | `test-spawn-dry-run.sh` case greps the PLAN line |
| C7 | B2 | the brief names only an 8-hex short id | `--topic ''` | the full uuid, or `''` when the hub cannot resolve exactly one | case with two topics sharing the prefix -> `''` |
| C8 | B2 | `agent-id-retire.sh c-NNN`: its fleet_lanes row | stays `live` | `done` | test reads the put call the retire makes |
| C9 | B3 | `lane_op put` with `issue_key: "SPL-3075"`, then `list` | field dropped | returned | Go test on the memory store and on Postgres |
| C10 | B3 | `issue_key: "spl 1"` | n/a | refused, row unchanged | Go test |
| C11 | B3 | `GET /v1/operator/fleet-lanes` as an operator admin | no route | 200, active rows only | Go test: a `live` row 2 h old and offline is absent |
| C12 | B3 | the same as a non-admin member of the operator workspace, and as an admin of another tenant | no route | 403 | Go test |
| C13 | B3 | a `BOX-0` row and an upper-case `CLE-77` row, both live and fresh | n/a | absent | Go test |
| C14 | B3 | a lane whose topic links SPL-1 and whose own key is SPL-2 | n/a | `issues` = SPL-1, SPL-2, each once | Go test |
| C15 | B4 | `MONITORING_TABS` ids | 4, no lanes | `[..., 'tokens', 'lanes']`, lanes `operatorsOnly` | `monitoring-tabs.test.mjs` order assertion |
| C16 | B4 | `visibleMonitoringTabs({ operator: false })` | no lanes | no lanes (C) | unit test |
| C17 | B4 | the Lanes page, a mock fleet of 3 lanes: a row's discussion link | page absent | `href` = `/t/<uuid>` | e2e on the mock bundle |
| C18 | B4 | a fake clock: the page fetches at 0 s and at 60 s, not at 30 s; none while hidden | n/a | as stated | unit test on the poll helper |
| C19 | B4 | i18n: `monitoring.tab.lanes` and the page keys in all 19 locales | missing | present; the `i18n-untranslated` and `i18n-no-raw-text` counts not raised | the two ratchet tests |
| C20 | B4 | initial JS budget (`ci_initial_gzip_kb`) | n/a | not raised: the page is its own chunk | `perf-budget.py` |
| C21 | B5a | `GET /v1/view/issues?discussion=<uuid of topic 5e7b15c9>` | no such filter | the issues linked to that topic only, SPL-3075 among them | Go test: an unlinked issue is absent |
| C22 | B5a | the filter with a topic of another tenant | n/a | empty list, never that tenant's issues | Go test |
| C23 | B5b | topic `/t/<uuid>` with a linked issue: a chip `SPL-n` to `/issues?issue=SPL-n` | no chip | the chip | e2e on the mock bundle |
| C24 | B5b | a topic with no linked issue | no chip | no chip, no empty row (C) | e2e |

## 5. Build rows

Disjoint files per row. B1 goes first and alone: it needs no data.

| row | area | files (only these) | after | cases |
|---|---|---|---|---|
| B1 tab row | wui | `wui/pages/monitoring.vue`; `wui/assets/css/main.css` (the `.monitoring-tabs` / `.monitoring-tab` rules at :1580-1584 and one line in the phone block near :1003); new `csi-spl-wui/tests/e2e/monitoring-tab-row.test.mjs` | - | C1-C5 |
| B2 lane row data | orc | `orc/features/spawn-agents/scripts/lane-map.sh`, `spawn-core.inc.sh` (`_spawn_lane_put` only), `agent-id-retire.sh`, the lane-put run action, their tests under `orc/features/spawn-agents/tests/`; a new named action that closes stale rows | B3's migration on master (the issue field) | C6-C8 |
| B3 hub view | rdb, api | a new `rdb/<next>_fleet_lanes_issue_key.sql`; `hub/box_lane.go`; new `hub/fleet_lanes_view.go` + `_test.go`; the store's fleet-lane methods; the route in the hub's mux | - | C9-C14 |
| B4 Lanes tab | wui | `wui/utils/monitoring-tabs.mjs`; new `wui/pages/monitoring/lanes/index.vue`; new `wui/utils/monitoring-lanes.mjs`; the hub client's fleet-lanes call; `csi-spl-wui/i18n/locales/*.json` (new keys only); `csi-spl-wui/tests/unit/monitoring-tabs.test.mjs`; new `tests/unit/monitoring-lanes.test.mjs`; new `tests/e2e/monitoring-lanes.test.mjs` | B1, B3 | C15-C20 |
| B5a issues by discussion | api | `hub/issues.go` (the list filter only), its test, the store's issue list query | - | C21-C22 |
| B5b topic issue chips | wui | `wui/pages/t/[task_id].vue` (or its header component), new `wui/components/TopicIssueChips.vue`, its locale keys, its tests | B5a | C23-C24 |

B4 and B5b both add locale keys: they land one after the other. B2 and B3
both touch the lane put; B3 lands first.

## 6. Panel questions

- **P1** Active: `updated_at` within 60 min OR online in the roster? Or a
  heartbeat column the lane refreshes? A lane can work for hours without a
  new `put`, so `updated_at` alone drops busy lanes.
- **P2** The 172 `live` rows older than 7 days: one named action marks
  them `done` (dry run first), or the view's cut-off only hides them?
- **P3** Should the lane row show the issue keys directly (3.2), or only
  through the discussion as the owner described?
- **P4** Poll every 60 s, or push a `lane` frame over the WUI socket? The
  poll matches Tokens and needs no socket change.
- **P5** Phone: 12 px instead of 20 px after the heading, and a bar that
  scrolls inside itself; or the tabs on their own row on a phone only?
- **P6** Does Reporting T053 (`/reporting/lanes`) reuse B3's view, or keep
  its own history query?

## 7. Owner questions

Only the owner can answer these.

- **O1** Who may see the Lanes tab: operator admins only (like Tokens), or
  also the admins of a workspace, for the lanes working on that
  workspace's topics?
