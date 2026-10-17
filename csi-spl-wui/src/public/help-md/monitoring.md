# Monitoring

The **Monitoring** section in the left rail (the pulse-line icon) is one place
to watch the workspace's agents and boxes. It opens on its **Agents** tab.

## The tabs

A row of tabs sits at the top of the page. Each tab has its own address, so a
link opens that tab directly, and the browser's Back button steps back through
the tabs you opened:

| Tab | Address | What it shows |
|---|---|---|
| **Agents** | `/monitoring/agents` | The workspace's agents, each with a presence dot (green when live) and its kind. Click a row to open its card at `/monitoring/agents/<id@box>`: its kind, whether it is online, the box it runs on, when that box last checked in, and a **Message** button that opens a direct message with it. |
| **Boxes** | `/monitoring/boxes` | The machines agents run on: a **filter** by id or tag, the count, and the boxes grouped **Online** then **Offline**. Each row has a presence dot, the short tag and how many people and agents are seated on it, and under it the box's system facts. Admins of the operator workspace also see the allocation (below). Click a row to open its card at `/monitoring/boxes/<id>`. |
| **Costs** | `/monitoring/costs` | What the setup costs each month, with a breakdown table and a pie chart (below). Shown to workspace owners and admins. |
| **Tokens** | `/monitoring/tokens` | The fleet's live token burn, with summary metrics and breakdown tables by agent type and agent lane (below). Shown to admins of the operator workspace. |

Opening `/monitoring` on its own goes to the Agents tab.

More tabs come later (capacity, open asks, CI and deploys, alerts). The fleet
tabs among them show only to admins of the operator workspace.

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

## Costs: monthly breakdown and pie chart

The **Costs** tab shows what the setup costs each month, visible to workspace
owners and admins (members with permission to read costs).

- **Month picker**: choose the current month (marked "so far", with the number
  of completed days) or any of the 11 months before it. Future months cannot
  be selected.
- **Cost breakdown**: one row per cost part (source, project or vendor, and
  kind), showing amounts in USD and EUR, percentage share of the month, list
  price where recorded, and marks for costs entered by hand or estimated,
  followed by a total row. Sources without data say "No cost data yet for
  <source>".
- **Pie chart**: shows slices for parts exceeding 1 % of the month's total,
  with the remainder grouped under "Other". If no cost data is recorded for the
  month, no chart is drawn.
- **On a phone**: each cost part is displayed as a card with its figures
  labelled under its name.

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

## The Agents and Boxes sections moved here

The left rail no longer has its own **Agents** and **Boxes** icons, on a
phone or on a desktop: both are tabs of Monitoring now, with everything they
showed. An old link still works: `/agents`, `/agents/<id@box>`, `/boxes` and
`/boxes/<id>` open the matching Monitoring page. A saved left panel order
that named the two keeps working; they are simply not drawn. See
[Agents](./agents.md) and [Boxes](./boxes.md).

## On a phone

Monitoring is one entry in the section strip at the top. Its tabs sit under the
strip; swipe the strip to reach it.
