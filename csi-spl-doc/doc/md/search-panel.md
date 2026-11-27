# The search panel: results left, the hit right

SPL-6675, epic SPL-1292, spec [100 search index](../../specs/100-search-index/spec.md)
and [197](../../specs/197-universal-search-results/spec.md) v1.2 (its
"list left, preview right" panel). The owners' words: HUM-10, t1 bcfd15e1,
msgs b996a06b, aa7dd3cf, 2f0259cc, 6cb72656, 86f0ab8f, 22c8a872; HUM-5,
topic ea3ea4a3, msgs 6b9a0898 and 03ddd1e7, poll c3e059ea.

## 1. What the reader sees

1. A search typed in the Omnibox (`/search <q>`, `/search:<q>`, `/s <q>`)
   opens the **search panel**: its own column that slides open beside the
   icon rail. The page stays where it was. There is no results page: an old
   `/search?q=<q>` link opens the panel on the home page and leaves that
   address at once.
2. While the panel is open, the section's own left list (the channels, the
   people, an issue's epics) is hidden; it keeps its width and comes back as
   it was when the search closes.
3. The panel opens at 48 % of the window, between 380 px and 65 %. Its
   divider resizes it; the width is kept in this browser under
   `spool.us-pane-w`, apart from the left list's.
4. **Preview**: a click on a hit, or `ArrowUp` / `ArrowDown` (`Home`, `End`)
   resting on one, shows the hit on the right, alone: a calendar entry is
   the calendar at that day with the entry marked and no months strip and no
   dialog; a message is its channel or direct message at that message. The
   list stays, and the next hit swaps only the right side. The first preview
   is one history entry; the next ones replace it. The keys stay on the
   list while a message hit's place focuses its own line, so `Enter` right
   after an arrow opens the hit just previewed.
5. **Open**: `Enter`, `Shift+O`, a double-click or the row's **Open** opens
   the hit for real: the panel closes and the section's own left pane is
   back. A calendar entry opens its dialog with the months strip beside it.
   A message or file hit opens as its card's **Open in channels view** does:
   Channels (or Direct messages) left, its topic at the top of the middle,
   the card at the top of the right pane.
6. **Close**: the panel's X, `Esc` in the list, or a section picked on the
   rail closes the search the same way and takes its line out of the
   Omnibox.
7. On a phone the panel covers the page under the top bar and the section
   strip: the strip stays on top, as at every level of a section (SPL-3785),
   and a section picked there closes the search (SPL-6702). It holds for a
   panel opened in a background tab, and for a strip that appears or changes
   size after the panel opened. A tap shows the
   hit over it (there is no room beside the list for a preview) and Back
   brings the list back, its scroll and chosen hit kept.

## 2. Calendar hits

`type:calendar` (`type:cal`) lists only real entries, nearest upcoming
first: the entries that have not ended, by start; then the past ones, the
latest first. Week-number markers that an imported or connected calendar
sends ("Week 48", "Week 48 of 2026", "W48", "KW 48", "Viikko 48", ...; a title
that is only the week) are not listed; "Week 48 sprint planning" is. The hub
answers the calendars section oldest first from a year back, a page at a
time, so the WUI reads the section to its end (at most 10 pages) before it
orders it (`csi-spl-wui/src/utils/search-calendar.ts`).

## 3. Where it lives

| part | file |
|---|---|
| the column, its width and divider | `csi-spl-wui/src/components/SearchPanel.vue`, `src/utils/search-panel.ts` |
| the list, preview and open | `csi-spl-wui/src/components/SearchSidePanel.vue`, `SideHitList.vue` (search mode) |
| a bare search's help | `csi-spl-wui/src/components/SearchPanelHelp.vue` |
| open / closed state | `csi-spl-wui/src/stores/search.ts` (`panelOpen`, `openPanel`, `closePanel`) |
| the left list hidden meanwhile | `csi-spl-wui/src/components/ChannelSidebar.vue` (`searchShut`) |
| the calendar alone, the entry marked | `csi-spl-wui/src/pages/calendar.vue`, `CalendarMainView.vue`, `src/composables/useCalendarDeepLinks.ts` |
| the old address | `csi-spl-wui/src/pages/search.vue` (opens the panel, then `/`) |

Tests: `csi-spl-wui/tests/e2e/search-panel.test.mjs`,
`csi-spl-wui/tests/unit/search-calendar.test.mjs`.

## 4. Not yet

- The hub's own `upcoming` order and marker filter (spec 197 HOW, row C1)
  would spare the WUI the extra page reads; until then the WUI does both.
- The help page `doc/help/global-search.md` is a Qto export; its text about
  `/search?q=` and the results page is updated in its Qto doc, not here.
- There is no `/us` command and no dark-launch flag: the owner chose `/s`
  for everyone, dev then prd (HUM-10, t1 bcfd15e1, poll ad7ec9ec, answer
  msg 06a64b3a); spec 197 v1.2.3 follows this build.
