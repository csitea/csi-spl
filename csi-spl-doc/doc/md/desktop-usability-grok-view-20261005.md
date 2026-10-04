# Desktop usability, an independent view

**Status: VIEW.** One walk of the desktop shell, then a review of the nine
ideas already picked. Nothing here is a spec, and nothing in the shell was
changed.

The walk was done before this review was written. The nine ideas are answered
in part B only.

## How it was measured

| field | value |
|---|---|
| tree | `c679dd9698e07d27be3b7b5d879d79f9010b85f5` (origin/master at the walk) |
| when | 2026-10-04T21:07Z |
| app | local mock, `NUXT_PUBLIC_USE_MOCK=1`, the e2e dev server (`nuxi dev`) |
| viewport | 1440×900, confirmed `innerWidth` 1440 and `innerHeight` 900, dark theme |
| session | one fresh browser profile. Corner control was the sign-in entry (`user-menu-signin`, label "Sign in"). The tenant still rendered |
| n | 1 profile, 1 pass over Topics, one topic, one channel, search, Flow, People, Agents, Boxes. A second pass opened the four-message thread and a full navigation to People |

Limits of this session, so they are not findings:

- Settings was not opened. The corner control was sign-in, not an account menu.
- Issues, Help and Docs never settled on screen. One Issues click collapsed the left list to the icon rail while the Topics page was still painting; that was not held long enough to call it a fault.
- Light theme was not switched.
- A drag of the pane border, then a reload, was not completed. A later load stayed on "Loading Spool…" for 45 seconds and the shell never came back (n=1, dev server).
- The mock has five topics. Counts below are that fixture, not a busy tenant.

Dev-server noise (`/build.json` 404, one stale dependency response) is not treated as a product fault.

## Part A. What I would change

### A1. Show the topic list once, and give the thread the wide pane

**Problem.** On Topics the same five rows are drawn twice. The thread, which is why the row was opened, sits in the narrow column.

**Evidence.** At 1440×900 the shell is a 58 px top bar, a 48 px icon rail, a 260 px side list, and a center pane of 1174×842 with no topic open. Opening a topic (one click on the row; the address stays `/`) splits the center into 788 px and a 380×842 thread pane. The side list and the center list both still show all five rows. The four-message topic ("Review the spool WUI scaffold…") is highlighted in both lists, and the thread pane holds four cards, newest first. A one-message topic puts a single sentence in that 380 px column and leaves both lists up. A topic row is 99 px tall, so the 842 px pane fits about eight rows. This tenant has five, shown twice, and the rest of the pane is empty.

**Idea.** The left list is the index. The wide pane is the thread. Opening a row replaces the center, it does not add a third copy. Close the thread to get the index back, in the wide pane, once.

**Effort.** M.

### A2. A section change clears the topic that was open

**Problem.** The thread you opened stays on the right after you leave the conversation. Search, People, Agents and Boxes then show three unrelated things.

**Evidence.** Search for `scaffold` lands on `/search?q=scaffold`. The side list says "2 results, in the left panel." The center is that one sentence and empty space. The right pane is still "Typed at the terminal…", which is not one of the two hits. Flow, with its tab selected, keeps `#lobby` in the center and that same topic on the right (`/channel/lobby?topic=…`). People (`/people`) lists four members in the side list, the center says "Select a person to see their card.", and the right pane is still that topic. Agents and Boxes do the same. n=1.

**Idea.** The right pane belongs to the conversation. Entering Search, People, Agents, Boxes, Issues, Help or Docs closes it. The wide pane shows the thing the section is for: the hits, the person, the box. The side list can stay the index.

**Effort.** S for closing the pane. M if Search and People move their results into the wide pane in the same change.

### A3. The composer says where the message will go, after you start typing

**Problem.** The only name of the destination is the placeholder of a one-line field in the top bar. Typing replaces it. A topic can be open on the right that the field is not answering.

**Evidence.** The field is 842×36 at y=7. Empty, on Topics, the placeholder is "Message Topics — Enter sends · Shift+Enter adds a line · /search to search everything". With a topic open it becomes "Reply — Enter sends · Shift+Enter adds a line · /search to filter". On `#lobby` it is "Message #lobby — …". On People it is "Type /search and a query, e.g. /search from:…". The target line under the field (`.composer-target`) was empty in every one of these. Shift+R moved focus into the field and left it empty. The right pane did not gain a "replying to" label.

**Idea.** A chip that stays while you type: the channel, the topic title, or "new topic". The chip is the destination. The placeholder can go back to being a hint.

**Effort.** S.

### A4. A half-written reply survives the reload, per topic

**Problem.** The text exists only in the live field. Leave the document and it is gone. Nothing on the topic row says a draft exists.

**Evidence.** The field was set to "half-written reply about the scaffold". It was still there after a rail click that stayed on `/`. After a reload the field was empty. A full load of `/people` also showed an empty field. n=1. No draft mark appeared on a row.

**Idea.** Keep the text per topic in the browser, restore it when that topic is the target, and put a small mark on the topic row. Clear it when the message sends.

**Effort.** M.

### A5. Topic rows should not show markdown source, and a clock is not a date

**Problem.** The index and the thread disagree about the same message. The index shows the raw marks and a time of day. The thread shows rendered text and a calendar date.

**Evidence.** The oldest topic row reads `Welcome to **#lobby**. This is the lde mock feed.` The same message in `#lobby` renders the channel name in bold. Every topic row prints a clock only (`13:07` on this profile). The thread card for that row prints the calendar date `2026-09-18` and "sent 395h". The row looks like an afternoon message. The card says it is more than two weeks old. n=5 rows, all clocks, no dates.

**Idea.** The row title is the plain text of the opening line. If the message is not from today, the row prints the date. The clock stays for today.

**Effort.** S.

### A6. The unread "1" has to be on the row that opens it

**Problem.** Three places agree there is one unread item, and the list you scan does not mark which row it is.

**Evidence.** The document title is `(1) spool-hub`. The Direct messages rail count is `1`. The Flow rail count is `1` (neutral, not the red count). Channel unread marks: 0. Topic unread marks: 0. The topic list includes "Direct ping — mock DM." with "2 messages" and no unread mark. Opening the four-message thread showed no new-messages divider. n=1 fresh profile, so nothing had been marked read by a person.

**Idea.** The row that carries the unread item wears the number. The title's `(1)` is the sum of those row numbers. Flow's number is that same sum, or it is labelled as something else so it cannot be read as a second total. No new counter.

**Effort.** M.

### A7. "3 >>" should say replies

**Problem.** The way into a thread is a glyph that does not say what it is.

**Evidence.** In `#lobby` the three cards end in `0 >>`, `3 >>` and `0 >>`. The card with `3 >>` is the one whose topic pane holds four messages (the opening one plus three). A reader can learn the glyph. The screen does not teach it.

**Idea.** The control reads the count and the word, for example "3 replies". Zero can stay quiet, or read "Reply".

**Effort.** S.

### A8. A go-to key for the ten sections

**Problem.** The rail is ten icons and no labels. The keys that exist act on a message. Nothing opens a section.

**Evidence.** Ten rail tabs, each 47 px, titles only on the `title` attribute. The text labels are `display: none`. At 900 px they all fit, including Archive at y=525, plus Help, Docs and the gear. `/` focuses the omnibox (measured). Ctrl+K, with the body focused, opened no dialog and left the address on `/` (n=1). Shift+? opened "Keyboard shortcuts": twelve message actions (Hide, Reply, Edit, Archive, Open, parent, link, copy, kind, topic, move, delete), a second Archive line for the focused topic, then j/k, the same help key, `/` and Esc. No "next pane", no "Channels", no "Issues". With a single card focused, j left focus on that card; movement across a longer feed was not measured.

**Idea.** One chord opens a short list of sections, topics and people, and runs the actions the overlay already names. It does not become a second composer. `/` already composes and searches. The overlay gains the new keys and drops nothing that already works.

**Effort.** M.

## Part B. The nine picked ideas

Summary of the walk against the list. Split view was not in the nine and is not reviewed.

| # | idea | verdict |
|---|---|---|
| 1 | One unread model everywhere | keep |
| 2 | Jump to the first unread | change |
| 3 | Command palette (Ctrl+K) | keep |
| 4 | Keyboard-first navigation | change |
| 5 | Resizable, remembered panes | change |
| 7 | Drafts that survive | keep |
| 8 | Bulk actions | drop |
| 9 | Density setting | change |
| 10 | Hover previews | drop |

**1. One unread model. Keep.** The title, the Direct messages icon and the Flow icon all say 1, and the topic row for the direct message says nothing (A6). That is the bug this idea names. Build the mark on the row, and make the title the sum of the rows. Do not add a fourth number while those three are being pulled into line.

**2. Jump to the first unread. Change.** The four-message thread opened at the top, newest first, with no divider, and every card was on screen. There was nowhere to jump. A jump earns its place when the first unread card is outside the pane. Build it after the row in idea 1 actually carries a number, so the key has a target. The "older / newer unread" pair can wait for a thread longer than this fixture.

**3. Command palette. Keep.** Ctrl+K did nothing. `/` already focuses a field that sends and searches. The hole is the ten unlabelled sections (A8). The palette should jump to a section, a topic or a person, and offer the actions the shortcut overlay already lists. It should not be a second place to type a message.

**4. Keyboard-first navigation. Change.** Message keys already exist and the overlay lists them (A8). More Shift+letter actions repeat the row menu. The missing keys are the pane and the section. Extend the overlay with those. Leave the message keys as they are.

**5. Resizable, remembered panes. Change.** Dividers are already on screen: with a topic open the columns were 260, 788 and 380. This session did not finish a drag followed by a reload, so remembered widths are not claimed either way. What was measured is the opposite problem: the topic pane stays open on Search, People, Agents and Boxes (A2). Remember a width per section if it is not already stored. Do not remember one topic across every section. A spec that only adds drag handles repeats the shell.

**7. Drafts that survive. Keep.** The text died on reload and on a full load of another page, and no row showed a mark (A4). Store it per topic. The mark belongs on the single list from A1, or it will show twice.

**8. Bulk actions. Drop.** The topic list had no checkbox (n=1, five rows). Archive is already a key on the focused row. A selection on a list that is drawn twice would not tell you which copy you selected. Bring it back when the list exists once and a tenant has more than a screen of topics.

**9. Density setting. Change.** A row is 99 px, so about eight fit in the 842 px pane. Today the pane looks empty because five rows are drawn twice, not because the type is large. A compact row is worth having after A1, as padding only, leaving the font steps alone. It is not one of the first three.

**10. Hover previews. Drop.** The row already shows the opening line and the message count. One click opened a four-message thread. Search already prints a snippet in the side list. A hover of the same sentence stacks a card on top of a pane that is already there. A preview of a link whose target is not on screen is a different, smaller idea. This mock did not contain one (n=1), so it is not a reason to build the general hover.

## Part C. Build these three first

1. **One index, the thread in the wide pane, and that pane closes when the section changes** (A1 and A2). Every later idea sits on this layout. A palette, a density step, a bulk action and a hover all get easier when the list exists once and the wide pane is the work.

2. **The unread number on the row you open** (picked idea 1, measured in A6). The title, Flow and the Direct messages icon already share a 1. The row does not. The jump key (idea 2) waits until that row exists.

3. **A draft that survives, and a composer chip that names the target** (picked idea 7, plus A3). The field is one line at the top of every section. Losing the text on reload, and losing the destination the moment you type, are the two ways a reply goes wrong. Both are smaller than a new navigation model, and both are felt on every send.

Ideas 3 and 4 (the palette, the section keys) are the right fourth. They are not first: `/` and the message keys already cover composing and acting on a card. Ideas 8, 9 and 10 wait.
