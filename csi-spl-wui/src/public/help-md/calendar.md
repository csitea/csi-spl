# Calendar

The **Calendar** section in the left rail opens one sheet: the left rail stays,
and the channel, topic and thread panes close, as in Issues. The sheet has two
columns.

## The year strip

The left column holds 36 small months: the previous year, this year and the
next year, one under the other. It opens on the month you are looking at, and
scrolling stops at the ends of the three years.

- A **dot** under a day means the day has events or issue deadlines you can see.
- A **tinted** day is an official day of your workspace's region. A workspace
  has no region until one is set, so a new workspace shows no tints.
- **Click a day** to show that day in the main view.
- With the keyboard, the strip is one stop: the arrow keys move between days,
  Home and End go to the start and end of the week, and Enter or Space picks.

Dates are written `YYYY-MM-DD` in every language.

## The main view

On a desktop the main view has no header bar. A narrow strip of tabs at its
left edge holds:

- the views **Day**, **3 days**, **Week** and **Month**: each opens on the
  period that holds today. **3 days** shows yesterday, today and tomorrow; a
  day you click in the year strip becomes its middle day. In **Month**, a
  day's number opens that day in Day.
- **Hours**, which shows or hides the hours panel on the right;
- **Today**, the previous and next buttons and the shown dates;
- the **⋯** menu (the trash) at the bottom, and the close button at the top.

The round **+** at the grid's bottom right adds an event. The time grid shows
8 hours at once and opens on 09:00; scroll for the rest of the day. Each event
is tinted in its colour with its title first, so a 30-minute event still reads.

The shown day and view are kept in the address (`/calendar?d=YYYY-MM-DD`, plus
`&v=day`, `&v=3day` or `&v=month`), so a link or a reload opens the same view.

Events are **public** by default: everyone who can open the workspace sees
them. Only the event's owner can make an event **private**.
