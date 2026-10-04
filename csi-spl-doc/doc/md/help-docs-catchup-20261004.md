# Help docs catch-up — 2026-10-04

Inventory for the help pages in `csi-spl-doc/doc/help/`, checked against the
code on `origin/master` (the web app and the `spool` command). A row is a
user-visible feature from `git log origin/master --since=2026-10-02T19:00Z`,
or an older gap found while reading every help page. Internal CI, refactors
and infra with no screen are not rows.

**State before** is how the pages read at the start of this pass:
`missing` (not written), `stale` (written, but the screen does something
else), `ok` (already matches the code).

| feature or gap | commit sha (or "older") | help page | state before |
|---|---|---|---|
| Boxes: three panes, daily facts, and Now | de6f975f, 751ccd61, f9ee4359 | boxes.md | ok |
| Shift + A archives the focused topic in Topics | 08ed0a42 | keyboard-shortcuts.md | ok |
| Shift + letter acts on the selected message (desktop) | c9060637 | keyboard-shortcuts.md | ok |
| Docs: explorer beside the document, icon under Help | a6ea337e, a4121da7 | (no page; not in index) | missing |
| Help is two panes; the icon rail stays; a phone is one pane | 3ff50244 | interface-overview.md | missing |
| An id the tab has not opened yet still becomes a link | 43effb6f | message-actions-and-formatting.md | ok |
| A topic or message id is named and opens in place | 249ef183 | message-actions-and-formatting.md, omnibox-and-navigation.md | ok |
| A commit hash in a message links to this instance's repository | e3e7db2d | message-actions-and-formatting.md | missing |
| The topic page is the list and the thread; the channel sidebar hides | acf8ba65 | message-levels-and-topics.md | stale |
| Keyboard shortcuts can be turned off; Shift + ? lists the keys; j / k move | c9060637, b28227be | keyboard-shortcuts.md (keys listed); user-settings.md (no switch) | stale |
| Hide a topic-view reply from the flow (menu, Shift + H, swipe left) | ae534d85, 741f5a53 | keyboard-shortcuts.md has the key; the gesture and the thicker line are unwritten | missing |
| A membership can end on a date (Access until) | 5d0db71a | user-settings.md (Members) | missing |
| A pending invite shows whether and when the mail went out | 7af4ccab | user-settings.md (Members) | missing |
| A DM about a topic is headed "about #channel / topic"; the channel copy says "via DM" | 52cd6b73 | channels-and-direct-messages.md | missing |
| Mentioning a person does not also open a poke DM; an agent's poke names the topic | 46786a47 | channels-and-direct-messages.md | missing |
| A message names the responsible seat when one is assigned | f48f765f | message-actions-and-formatting.md | missing |
| Phone: swipe a topic card left to archive, right to open its menu | edf172ab, 4855ae5d | archive.md, interface-overview.md | missing |
| Phone: swipe a topic-view reply left to hide it on this device | 741f5a53 | message-actions-and-formatting.md | missing |
| Release notes open from the version stamp, and at /releases/<ref> | a2e8c3c9 | release-notes.md is the writer rule only; not linked from index | missing |
| Workspace settings → Performance | 4896d07f | user-settings.md | ok |
| Workspace settings → Vendor split | 066f67d2 | user-settings.md | ok |
| Flow is Mine (default) or All, with mention / reply / DM chips | dbafa68e | channels-and-direct-messages.md §4 | stale |
| Flow's number is the theme grey; Channels and Direct messages use red numbers for the same unread set | dacaa717, 54d9c616 | channels-and-direct-messages.md, interface-overview.md | missing |
| Unread on a channel, DM or topic row comes from that same Flow set | 07d03506 | channels-and-direct-messages.md | stale |
| A thread line's menu says "Open in direct msg view" or "Open in channels view" | c7c61df2 | message-actions-and-formatting.md | stale |
| A reused agent id draws "New holder since …" in its conversation | 6ccac25f | channels-and-direct-messages.md | missing |
| Phone omnibox: drag to top, bottom or the bottom-right; Small / Medium / Large | 8db43a95, b4b26563 | omnibox-and-navigation.md, interface-overview.md | stale |
| The phone layout starts at 820 px, not 640 px; the composer docks at the bottom | older (SPL-990) plus the rows above | interface-overview.md §8 | stale |
| The left rail is ten sections, Archive pinned last; Help, Docs and Workspace settings are links under the icons | older, plus Docs a6ea337e | index.md, interface-overview.md | stale |
| New agent ids are c- / g- / a- / q- plus three digits; older CLE- / GRK- / AGY- / QWN- ids still display | older (spec 061; legacy writes ended 2026-10-03T20:59:59Z) | agents.md and the id examples on index, getting-started, channels, omnibox, agent-collaboration, global-search, message-actions | stale |
| Interests are edited on Settings → Profile | older | people.md ok; user-settings.md Profile omits the field | stale |
| Time zone is Settings → Appearance | older | how-to-post.md names it; user-settings.md Appearance omits it | stale |
| Events columns are When, Error id, Source, Status, Message, Page; the older button is Load older; the clear button is Clear log | older | events.md | stale |
| The install script takes the spool command from the newest stable release and builds only as a fallback | eb57b5a7 | connect-an-agent.md §7 | stale |
| Fleet load target (instance setting; `spool fleet-load`) | 3743415c | — | left: operator-workspace admins only, no member screen |
| Shift + H focus mode | — | — | left: still being built (c-243) |
| Archived mark on a row | — | — | left: still being built (g-245) |
| Link previews | — | — | left: still being built (c-226) |
| getting-started, issues, global-search operators, how-to-post, boxes, archive actions (Open / Unarchive / Delete) | older | those pages | ok, apart from the rows above |

Checked on `origin/master` at the time of this file. The code wins where a
commit subject and a screen disagree.
