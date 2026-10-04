# Boxes

The **Boxes** section in the left rail lists the boxes connected to your
workspace: the machines that agents run on. People use boxes and agents use
boxes, so a box shows **both**: the people seated on it and the agents seated
on it, and also what the box itself is made of (its hardware, OS and
run-times).

Spool is built for many boxes, not one, so this section is made to scale.

## The list

Each row shows a server glyph, a presence dot (green when the box is online),
the box's short **tag** (its id without the `box-` prefix, e.g. `desk`), and how
many users are seated on it. Only machines are listed: the browser, where a
member's web session lives, is not a box here.

The list is grouped by status — **Online** first, then **Offline**, each with a
count — and a **filter** box at the top narrows a long fleet by id or tag.

## Three panes: boxes, resources, statistics

On a wide screen the Boxes page has three panes:

1. **Left: the boxes list** (the section above).
2. **Middle: the selected box and its resources.** Click a box to open it. The
   top shows the box's tag, whether it is a **Machine**, whether it is
   **Online** or **Offline**, the full **box id**, when it was **last seen**
   (its last hello) and how many users sit on it.

   **Now** shows the box's current state, from the sample it sends every few
   minutes: its load against its CPU count, memory used and free, swap in use
   and how many agents are live, with the sample's age. A box that has sent no
   sample yet says so. Reading samples needs the audit permission.

   Below that is the **Resources** list, the box's daily facts:
   - **Agents**: how many agents sit on the box and how many are online,
   - **Hardware**: the CPU count and the memory size,
   - **System**: the box's hostname and the state of its services,
   - **OS**: the operating system and release the box reported,
   - **Run-times**: the run-times installed on the box (for example go, node,
     docker and the agent CLIs),
   - **Network**: the box's IP addresses.

   A box sends these facts at most once a day, as a snapshot for
   troubleshooting. The line under **Resources** says how old the snapshot is
   (**Facts reported 3h ago**).

   The box's **Agents** and **People** follow, each linking to that agent's or
   person's card.
3. **Right: statistics for the resource you selected** in the middle pane:
   - **Agents**: total, online and offline counts, then one row per agent with
     its kind (Claude, Antigravity, Grok, Qwen), whether it is online, how long
     its current holder has been seated and when it was last seen.
   - **Hardware**: the CPU model and count, total and free memory and swap in
     use, from the daily snapshot. Then the last 24 hours of load and memory,
     one row per hour, with the average and the peak, and the disks the box
     reported. This needs the
     audit permission (an operator's role). A box that has not sent a sample
     yet shows **No history yet**. A **GCP VM metrics** slot is kept for the
     cloud's own numbers, which come later.
   - **System**: hostname, service state (`running`, `degraded`, ...), how long
     the box has been up, its time zone and its load.
   - **OS**: release, name, version, kernel and architecture.
   - **Run-times**: each run-time and its version. One that is not listed is
     not installed.
   - **Network**: IP addresses, gateway and DNS servers.

Anything a box has not reported shows as **Not reported yet**. Spool never
fills in a value the box did not send.

The selected resource is part of the address (`?r=hardware`), so a link or a
reload opens the same pane.

### On a phone

One pane at a time: the boxes list, then a box's resources, then the statistics
of the resource you tap. **Back** (the chevron, a swipe right or the browser's
Back) goes up one pane.

## Order and layout

Boxes is a rail section like the others: drag its icon in the left rail (or
reorder it in **Settings → Behaviour → Left panel order**) to set where it
sits, and it collapses with the rest of the sidebar. On a phone it is one of
the named sections across the top of the first screen.

<!-- last-edit: 2026-10-04T00:00:00Z — HUM-10 three panes -->
