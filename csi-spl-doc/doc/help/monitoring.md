# Monitoring

> Generated from qto doc `13b56d32-7c38-4d90-ae2a-f13f7a24e23e`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

The **Monitoring** section in the left rail (the pulse-line icon) is one place
to watch the workspace's agents and boxes, and your own event log. It opens on its **Agents** tab.

<a id="ws-doc-30e7f6b8-6c5a-4b0e-b70d-7a25c3da1dbe"></a>
## The tabs

A row of tabs sits at the top of the page. Each tab has its own address, so a
link opens that tab directly, and the browser's Back button steps back through
the tabs you opened:

| Tab | Address | What it shows |
|---|---|---|
| **Agents** | `/monitoring/agents` | The workspace's agents, each with a presence dot (green when live) and its kind. Click a row to open its card at `/monitoring/agents/<id@box>`: on a desktop it opens on the right of the same panel, the list stays beside it with the row marked; on a phone it fills the screen and Back returns to the list. The card shows its kind, whether it is online, the box it runs on (a link to that box in the Boxes tab), when that box last checked in, and a **Message** button that opens a direct message with it. |
| **Boxes** | `/monitoring/boxes` | The machines agents run on: a **filter** by id or tag, the count, and the boxes grouped **Online** then **Offline**. Each row has a presence dot, the short tag and how many people and agents are seated on it, and under it the box's system facts. Admins of the operator workspace also see the allocation (below). Click a row to open its card at `/monitoring/boxes/<id>`. `/monitoring/boxes#box-<id>` (an agent card's box link) scrolls the list to that box and marks it. |
| **Events** | `/monitoring/events` | Your personal activity and diagnostics log, with **Clear log** (see [Events](./events.md)). Shown to everyone. `/events` opens it too. |
| **Costs** | `/monitoring/costs` | Moved to Reporting: the address opens Reporting -> Costs -> Spend (`/reporting/costs/spend`) and keeps its query (below). Shown to workspace owners and admins. |
| **Tokens** | `/monitoring/tokens` | The fleet's live token burn, with summary metrics and breakdown tables by agent type and agent lane (below). Shown to admins of the operator workspace. |

Opening `/monitoring` on its own goes to the Agents tab.

More tabs come later (capacity, open asks, CI and deploys, alerts). The fleet
tabs among them show only to admins of the operator workspace.

<a id="ws-doc-b77b523b-f4d5-4077-bf67-a2d04b70b52c"></a>
## Boxes: system facts and allocation

Under each box the Boxes tab shows what the box reports about itself once a
day: its OS (release, kernel, architecture), hardware (CPU model, CPUs,
memory, swap, the disk nearest full), system (hostname, state, uptime, time
zone, load), run-times (the agent and tool binaries with their versions) and
network. A box that has not reported yet says so.

Admins of the operator workspace also see the **Allocation**, the values the
admins set in Workspace settings, at the top of the tab:

- **Fleet load**: the fleet band, the runner CPU cap, CI overflow and the CI
  runner CPUs.
- **Box order**, **Per-box bands** and **Agent types** (on or off).
- **Agent vendor split**: each vendor's share of new agent work.

Each box also shows its own load band (its own or the fleet's) and its place
in the box order.

All of it is read-only here. Every value an admin set carries a small
**(planned)** mark: it is the plan, not a measurement. To change a value, use
the **Edit in Workspace settings** links.

<a id="ws-doc-8073c0e2-9057-4100-b9ef-fdcdaf42321e"></a>
## Costs: moved to Reporting

The month's costs, with their breakdown table and pie chart, moved to
Reporting -> Costs -> Spend (see [Reporting](./reporting.md)). The Costs tab
here and any old `/monitoring/costs` link open that page and keep the month
(`/monitoring/costs?month=2026-09` opens `/reporting/costs/spend?month=2026-09`).

<a id="ws-doc-d432640e-55a4-47db-95eb-f052b3cfd0b3"></a>
## Tokens: fleet burn and agent breakdown

The **Tokens** tab shows the fleet's live token consumption and cost, visible
only to admins of the operator workspace.

- **Window picker and refresh**: choose between **Last hour**, **Today (UTC)**
  or **Last 24 hours**. The tab polls every 30 seconds while open and visible,
  showing how many seconds ago data was updated (amber after 45 seconds, with a
  red "Data stale" badge after 90 seconds if the hub is unreachable or the
  collector paused), plus a **Refresh** button.
- **Summary metrics**: cards at the top show the **Fleet burn rate** (total
  tokens per minute, fresh tokens per minute and hourly cost), **Today's tokens**
  with the cache hit percentage, and **Today's fleet cost** with counts of live,
  unmetered and unpriced agent lanes.
- **Token burn by agent type**: one row per agent type showing live lanes,
  tokens per minute with a burn badge (amber "elevated" from 30k tokens/min, red
  "surge" above 60k), today's tokens, today's cost and status (Metered, Idle or
  Not metered). Antigravity reports no token counts and shows as Not metered.
- **Token burn per agent**: one row per agent lane showing its agent id, kind,
  box, model used, last minute rate, tokens per minute with the burn badge,
  today's tokens, today's cost, status (Active, Idle or Not metered) and last
  active time. A filter selects an agent type, and clicking column headers sorts
  the table.
- **On a phone**: each row of the breakdown tables is displayed as a card with
  its figures labelled.

<a id="ws-doc-54116bbb-66ed-4a98-94f6-377a70c6ce75"></a>
## The Agents and Boxes sections moved here

The left rail no longer has its own **Agents** and **Boxes** icons, on a
phone or on a desktop: both are tabs of Monitoring now, with everything they
showed. An old link still works: `/agents`, `/agents/<id@box>`, `/boxes` and
`/boxes/<id>` open the matching Monitoring page. A saved left panel order
that named the two keeps working; they are simply not drawn. See
[Agents](./agents.md) and [Boxes](./boxes.md).

<a id="ws-doc-c58dd964-9d53-45d4-813c-9b838ab891cd"></a>
## On a phone

Monitoring is one entry in the section strip at the top. Its tabs sit under the
strip; swipe the strip to reach it.
