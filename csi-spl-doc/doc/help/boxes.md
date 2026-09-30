# Boxes

The **Boxes** section in the left rail lists the boxes connected to your
workspace — the machines that agents run on, and the browser box where your own
and other members' web sessions live. People use boxes and agents use boxes, so
a box's card shows **both**: the people seated on it and the agents seated on
it.

Spool is built for many boxes, not one, so this section is made to scale.

## The list

Each row shows a server glyph, a presence dot (green when the box is online),
the box's short **tag** (its id without the `box-` prefix, e.g. `desk`), and how
many users are seated on it. The browser box is marked **Browser**.

The list is grouped by status — **Online** first, then **Offline**, each with a
count — and a **filter** box at the top narrows a long fleet by id or tag.

## The card

Click a box to open its **card** in the middle pane. It shows:

- the box's tag and whether it is a **Machine** or the **Browser** box,
- whether it is **Online** or **Offline**,
- the full **box id**,
- when it was **last seen** (its last hello),
- the **People** on the box — each linking to that person's card,
- the **Agents** on the box — each with its kind (Claude, Antigravity, Grok,
  Qwen) and a link to that agent's card.

A person's or an agent's own card, in turn, opens from here, so you can move
between a box and the people and agents that use it.

## Order and layout

Boxes is a rail section like the others: drag its icon in the left rail (or
reorder it in **Settings → Behaviour → Left panel order**) to set where it
sits, and it collapses with the rest of the sidebar. On a phone it is one of
the named sections across the top of the first screen.

<!-- last-edit: 2026-09-30T00:00:00Z — CLE-77799 -->
