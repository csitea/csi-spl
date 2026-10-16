# Monitoring

The **Monitoring** section in the left rail (the pulse-line icon) is one place
to watch the workspace's agents and boxes. It opens on its **Agents** tab.

## The tabs

A row of tabs sits at the top of the page. Each tab has its own address, so a
link opens that tab directly, and the browser's Back button steps back through
the tabs you opened:

| Tab | Address | What it shows |
|---|---|---|
| **Agents** | `/monitoring/agents` | The workspace's agents, each with a presence dot (green when live) and its kind. Click a row to open its card. |
| **Boxes** | `/monitoring/boxes` | The machines agents run on, each with a presence dot, its short tag and how many people and agents are seated on it, and under it the box's system facts. Admins of the operator workspace also see the allocation (below). Click a row to open its card. |
| **Costs** | `/monitoring/costs` | What the setup costs each month, with a breakdown table and a pie chart (below). Shown to workspace owners and admins. |

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

## The Agents and Boxes sections

The **Agents** and **Boxes** sections of the left rail stay where they are for
now. Monitoring shows the same agents and boxes. See [Agents](./agents.md) and
[Boxes](./boxes.md).

## On a phone

Monitoring is one entry in the section strip at the top. Its tabs sit under the
strip; swipe the strip to reach it.
