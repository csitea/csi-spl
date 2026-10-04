# Desktop WUI usability: the consensus list, 2026-10-05

Topic: t1 `3a74320e-b5b0-44b8-bf1e-6d1b9c84d5ed`. Owner HUM-10, 7d842610:
*"you should build a consensus with at least one grok agent participating in
this discussion"*. The owner has already picked starter ideas 1, 2, 3, 4, 5,
7, 8, 9 and 10 (ea6330ff); split view (#6) is not now.

This list merges two independent walks of the desktop shell, each written
before the author read the other's:

| view | doc | sha | how measured |
|---|---|---|---|
| claude (c-245) | `desktop-usability-ideas-20261004.md` | `2ca50627`, `97d81cf3` | mock bundle, tree `7289ef28`, 1440x900 + 1920x1080, 10 tasks, n=1 each |
| grok (g-248) | `desktop-usability-grok-view-20261005.md` | `29ab0d9d` | mock bundle, tree `c679dd96`, 1440x900, one fresh profile, n=1 |

It changes no code and is not a spec. The spec lanes start after the owner
answers.

## 1. How the verdicts were reached

- **agreed**: both docs back the idea and the change, with evidence.
- **disputed**: the docs disagree; both views are given, one line each.
- **one view**: only c-245's doc covers it. g-248 was asked for verdicts on
  these (msg to g-248 on this task) and declined: its brief was the view doc
  only (reject e7d6cb8f). These items are **not** agreed. The orchestrator
  can place a lane for the grok verdicts if the owner wants them first.
- An idea from one doc that the other author accepts here is **agreed**.
  g-248's A2, A3 and A7 are in this group: c-245 accepts them on g-248's
  evidence and the owner posts cited.

## 2. The list

| # | idea | status | what both walks found |
|---|---|---|---|
| L1 | **Layout: the thread gets the width** (starter #5 + c-245 3.4 + g-248 A1) | agreed | Both measured the same split at 1440: 260 / 788 / **380** px, so a topic opens in the narrowest pane. g-248: on Topics the five rows are drawn twice, left and middle. c-245: at 1920 the pane is still 380 px while message lines run 1267 px wide, and at 1440 it truncates the title and the sender. Owner bb2473ac (Topics should have 2 panes, not 3) and 73f13491. Change: Topics shows the list once and the thread in the wide pane; elsewhere the right pane defaults to a share of the screen, widths are kept per view, and message text gets a readable measure. Resize and collapse already exist (`PaneDivider.vue`, 050), so no spec should re-add handles |
| L2 | **A section change closes the right pane** (g-248 A2) | agreed | g-248: Search, People, Agents and Boxes keep an unrelated topic open on the right (n=1 each). Owner b6f35bf4 and 193d95f7 ask for the 3rd pane to close on a section change. Ships with L1 |
| L3 | **One unread model, shown on the row** (starter #1) | agreed | g-248: the title `(1)`, the DM rail `1` and the Flow rail `1` agree, but the topic row that holds the unread item has no mark. c-245: opening the item cleared all three together (n=1). Owner 92c4b3e8, da315c54. Change: the row wears the number, the title is the sum of the rows, and Flow's number is that same sum or is labelled as something else. A follow-up of c-253 (topic new/total), not a parallel lane |
| L4 | **Drafts per place + a composer target chip** (starter #7 + g-248 A3) | agreed | Both measured the draft lost on reload. c-245: a draft typed in `#feedback` was still in the box on `#alerts`, one Enter from the wrong channel. g-248: the destination is named only by the placeholder, which typing erases, and `.composer-target` was empty in every view. Change: one draft per channel, DM and topic, kept across reloads, with a mark on the row; a chip that names the destination while you type. Also mobile (with c-246's offline send queue) |
| L5 | **Command palette + section and pane keys** (starters #3, #4 + g-248 A8 + c-245 3.2) | agreed | Both measured: `Ctrl+K` opens nothing; `Shift+?` lists message actions only, with no section or pane keys. c-245: 35 Tab stops to the first card, no skip link, focus jumps panes after a shortcut (owner 55ad15bc, 8b1a5cc5). Change: `Ctrl+K` goes to a section, channel, topic, person, doc or setting and runs the actions the overlay lists; it is **not** a second composer (`/` already composes and searches). Keys to move between panes and sections; a shortcut keeps focus in its pane; the overlay lists every key. No new Shift+letter message actions |
| L6 | **Clean list rows** (g-248 A5 + c-245 3.13) | agreed | Both measured raw markdown in rows (`Welcome to **#lobby**`). c-245: every row starts `Topic:`, in both lists. g-248: rows print a clock only, while the card for the same message says 2026-09-18. Change: plain text of the opening line, no `Topic:` prefix, a date when the message is not from today. Also mobile (c-246 §3.13) |
| L7 | **"3 replies", not "3 >>"** (g-248 A7) | agreed by both walks, **but returned to the owner** | g-248: the thread control reads `0 >>` / `3 >>` with no word. c-245 accepted. Found while writing spec 082: the owner already decided this control, `MessageCard.vue:135` "SPL-982 (owner, topic 8296eeec): exactly \"3 >>\", no word". Not built; asked in spec 082 §9 Q4 |
| L8 | **Next unread** (starter #2) | agreed, **after L3** | Both say *change*: the "New messages" divider exists (`seat-divider` -> 4 in `LiveFeed.vue`). c-245: no key or button goes to the next unread place, 2 clicks through Flow each time. g-248: in this five-topic fixture there was nowhere to jump, and a key needs the row mark from L3 as its target. Build it after L3 |
| L9 | **Density: compact rows, padding only** (starter #9) | agreed, **late** | c-245: one-line cards 73 px apart at 1440. g-248: a topic row is 99 px; the pane looks empty because rows are drawn twice (L1), not because type is large. Both: padding only, the 5 font levels stay, after L1. Name it apart from the existing *List density* (the clip) |
| L10 | **Bulk actions** (starter #8) | **disputed** | c-245: keep, late. 10 topics cost 20 actions and no multi-select exists (grep -> 0). g-248: drop for now. Archive is already a key, and a selection on a list drawn twice would not show which copy you picked; bring it back once L1 ships and a tenant has more than a screen of topics |
| L11 | **Hover previews** (starter #10) | **disputed** | c-245: keep the narrow form only, hovering an id or spec reference inside a message body (owner 145297d8), after c-226 (link previews) lands. g-248: drop. The row already shows the opening line and one click opens the thread; a preview of an off-screen link target is "a different, smaller idea" this mock gave no case for. **Both drop the general row hover** |
| L12 | **Window identity for two screens** (c-245 3.7) | one view | Every tab is titled `(1) spool-hub`; no pop-out topic window; no cross-tab sync (`BroadcastChannel` grep -> 0). The owner should confirm a pop-out is not the split view they deferred |
| L13 | **Accessibility baseline** (c-245 3.11) | one view | No skip link; the placeholder is 4.0:1 (AA needs 4.5:1); an axe pass in e2e. Focus rings are present (17 `focus-visible` rules). g-248 independently noted rail labels are `display: none`, titles only (A8) |
| L14 | **Search ergonomics** (c-245 3.8) | one view | 8 keys of `/search ` prefix per query; no recent searches; no search-this-channel key |
| L15 | **Web Push to a closed browser** (c-245 3.14, from c-246 §3.2) | one view | Alerts need an open tab (`PushManager`/VAPID grep -> 0). L effort, a store migration and a new secret. Also mobile |
| L16 | **Offline reading + instant first screen** (c-245 3.15, from c-246 §3.11) | one view | `sw.js` caches the shell only. L effort; overlaps 066 / 070 on timing. Also mobile |
| — | **Split view** (starter #6) | not now | owner ea6330ff |

Count: 16 ideas. **9 agreed**, **2 disputed**, **5 one view**.

## 3. Proposed build order

The two docs put different ideas first. c-245 ranked the palette first; g-248
put the layout first, because the row marks, drafts, density and bulk
selection all land on a list that should exist once. c-245 accepts that
dependency argument. The layout also carries the most owner posts (bb2473ac,
73f13491, b6f35bf4, 193d95f7).

| step | ideas | why here | effort |
|---|---|---|---|
| 1 | L1 + L2 | everything after it lands on this layout | M |
| 2 | L3 | the row mark is the target for L8 and fixes the owner's count complaint; with c-253 | M |
| 3 | L4 | the two ways a reply goes wrong, felt on every send | S..M |
| 4 | L5 | the biggest saving in clicks and keys (T1, T6, T7, T8) once the layout is stable | M |
| 5 | L6 + L7 | small, visible, same files as L1 (rebase on c-253) | S |
| 6 | L8 | after L3 gives it a target | S |
| 7 | L13 | cheap, and the axe gate protects steps 1..6 | S |
| 8 | L12, L14 | small; single view, so owner confirmation first | S |
| 9 | L9 | padding only, after L1 | S |
| 10 | L10, L11 | disputed: owner call on form and timing | M, S |
| 11 | L15, L16 | L effort, shared with the mobile list, one spec each for both | L |

## 4. For the owner

1. **L10 bulk actions** and **L11 hover previews**: keep (c-245, late or
   narrow) or drop for now (g-248)? Both are in your pick, so they stay
   unless you drop them.
2. **L12..L16** have one view. Build on that, or have a grok lane review them
   first?
3. **L12 pop-out window**: does it count as the split view you deferred?

<!-- last-edit: 2026-10-04T21:42:52Z -->
