# 078: desktop layout, the thread gets the width

**Feature ID**: `078-desktop-wide-thread-layout` · **Milestone**: M3 · **Status**: Planned
**Created**: 2026-10-04 · **Lane**: c-245 (spec only) · **Topic**: 3a74320e-b5b0-44b8-bf1e-6d1b9c84d5ed
**Authority**: this file for the behaviour; `tasks.md` for what is built, with the sha and the check for each item. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing.

Builds on, and does not repeat:
[050 panel collapse](../050-spool-panel-collapse/spec.md) (collapse, unchanged),
[074 operator workspace](../074-operator-workspace/spec.md) (the operator section of the right pane, T008),
`../../doc/md/SPEC-spool-wui-layout.md` §1.2 (dividers: this spec replaces its stale `spool.pane-widths` text),
`../../doc/md/topics-view-retire-proposal.md` (pending owner decision, see §9 Q1).

Evidence base: `../../doc/md/desktop-usability-consensus-20261005.md` L1 + L2 (agreed by c-245 and g-248),
`../../doc/md/desktop-usability-ideas-20261004.md` §3.4, `../../doc/md/desktop-usability-grok-view-20261005.md` A1, A2.

---

## 1. Why, and the owner's ask

Owner go: ea6330ff, spec then build every agreed idea except split view. DoD: ready specs (44ff08f3). Owner posts on this layout, verbatim (relayed by c-002, msg 7f75f5e5):

- `bb2473ac`: "the topic's view should have 2 and not 3 vertical panels ... Because it is confusing ... so the topic view should be the view where one could browse the topics regardless to where they belong and read in full screen the same flow which happens on the 3rd panel in the channel topic reply pnael"
- `73f13491`: "And also the right pane content shoudld be more centred into the screen"
- `b6f35bf4`: "and if one clicks from the channel view - of course the 3rd panel with the content of the channel view should be closed"
- `193d95f7`: "the docs should open so that the explorer like file structure is in the left most panel , the content in the second panel and if there is already a 3rd right most panel it should close"

## 2. Today, measured

Mock bundle, tree `7289ef28` / `c679dd96`, n=1 per row (consensus doc §1).

| # | fact | evidence |
|---|---|---|
| 1 | A topic opens in the narrowest pane: 260 / 788 / **380** px at 1440x900, 260 / 1268 / **380** px at 1920x1080 | both walks; `utils/pane-widths.mjs:10` `TOPIC_DEFAULT = 380`, `assets/css/variables.css:100` `--topic-w: 380px` |
| 2 | At 1440 the 380 px pane truncates the topic title ("Typed at the ter…") and the sender ("H…") | c-245 `topic-open-1440.png` |
| 3 | On Topics (`/`) the same list is drawn twice: middle `pages/index.vue:25-81` and sidebar `ChannelSidebar.vue:423-461`; picking the Topics tab navigates to `/` (`ChannelSidebar.vue:1077-1079`) | g-248 A1; code read |
| 4 | `/t/<id>` is already two panes (list + `TopicPane`) | `tests/unit/topic-view-two-panels.test.mjs` |
| 5 | On desktop a section change never closes the right pane: `routeLeavesTopic` returns false unless `nav.mobile` | `utils/topic-pane.mjs`, `layouts/default.vue:288-298`; g-248 A2: Search, People, Agents, Boxes keep an unrelated topic open |
| 6 | Widths are one set for the whole app: `{sidebar, topic}` as fractions, in `spool.pane-widths` and the account claim `pane_sizes` | `composables/usePaneWidths.ts:23,74,151-169`, `stores/session.ts:48`, `utils/auth-client.mjs:467-469` |
| 7 | Message text has no measure: lines run 1267 px wide at 1920 | `grep -rnE 'max-width:\s*[0-9]+(ch\|em)' src/assets src/components` -> 1 hit, `LogoDialog.vue` only |

## 3. The design

### 3.1 Topics is two panes

On `/` (Topics), the left list is the index and the **middle pane is the thread**: a row click shows that topic, at full middle width, in the same view `/t/<id>` already uses. The right pane does not open on Topics. With no topic selected, the middle shows the index-empty hint ("Pick a topic on the left"), not a second copy of the list. The address carries the selection (`/?topic=<id>`, or `/t/<id>`; see Q2), so Back and a reload keep it.

### 3.2 A section change closes the right pane

On desktop (> 820 px), entering a section page closes the right pane, whatever it holds (live topic, channel topic, operator console). Sections: `SECTION_PAGES` in `utils/section-strip.mjs:10-22` plus `/search`. Back (popstate) keeps today's rule: Back never closes the pane. Moving between channels and DMs does not count as a section change: the pane closes there only by today's rules.

### 3.3 The right pane is a share of the screen

The right pane's **default** width is 40 % of the space right of the left pane, clamped to the existing `TOPIC_MIN` (280) and `TOPIC_MAX_RATIO` (0.65), and leaving `MAIN_MIN` (360). That is about 470 px at 1440 and 660 px at 1920. A width the user drags still wins. `--topic-w` follows the computed default instead of a fixed 380 px.

### 3.4 Widths are kept per view

Dragged widths are stored per view: `channel` (channels and DMs), `issues`, `help`, `docs`, plus `default`. The stored shape grows from `{sidebar, topic}` to `{default: {sidebar, topic}, <view>: {...}}`. An old flat value reads as `default`, so nobody loses a width. Account copy and browser copy keep today's precedence (`hydrate()`).

### 3.5 Message text has a readable measure

A message card's body is capped at about 100 characters (`max-width: 100ch` on the body, see Q4), and the card's action buttons sit at the end of the capped card rather than at the far pane edge. Code blocks keep their own wrapping and the no-x-scroll rule.

## 4. User stories

| ID | Priority | Role | Story | Benefit |
|---|---|---|---|---|
| **US1** | **P1** | Member on a desktop | On Topics, click a topic and read it in the wide middle pane, with the list once on the left | the owner's 2-pane Topics (bb2473ac); no duplicate list |
| **US2** | **P1** | Member | Leave a conversation for People, Search, Docs or another section and see that section only, with no stale topic on the right | owner b6f35bf4, 193d95f7 |
| **US3** | **P1** | Member on a wide screen | Open a topic in a channel and get a right pane wide enough for its title and sender | 73f13491; no truncation at 1440 |
| **US4** | **P2** | Member | Set a wider thread pane in channels and a narrower one in Issues, and have each remembered | widths fit each view |
| **US5** | **P2** | Member on 1920+ | Read messages at a comfortable line length | readability |

## 5. Functional requirements

| ID | Description | Status |
|---|---|---|
| **FR-001** | On `/` at > 820 px, a topic row click shows the thread in the middle pane; the right pane stays closed on that route | Planned |
| **FR-002** | On `/` with no topic selected, the middle pane shows an empty hint, not the topic list | Planned |
| **FR-003** | The selected topic on `/` is in the address; Back, Forward and reload restore it | Planned |
| **FR-004** | At > 820 px, navigating (not popstate) to a section page or `/search` closes the right pane, whichever section it holds | Planned |
| **FR-005** | Channel-to-channel and channel-to-DM navigation keep today's pane rules | Planned |
| **FR-006** | The right pane's default width is 40 % of the space right of the left pane, clamped by `TOPIC_MIN`, `TOPIC_MAX_RATIO`, `MAIN_MIN`; `--topic-w` uses it | Planned |
| **FR-007** | A dragged width is stored per view (`channel`, `issues`, `help`, `docs`, `default`), in the browser and the account `pane_sizes`; an old flat value reads as `default` | Planned |
| **FR-008** | A message body is capped at the readable measure (Q4) and the card actions follow the capped card | Planned |
| **FR-009** | At ≤ 820 px nothing in this spec changes behaviour (the phone stack is untouched) | Planned |
| **FR-010** | Help `interface-overview.md` §1, §5, §6 describe the new layout and the per-view widths | Planned |

## 6. Acceptance scenarios

| # | Check / test | Proves |
|---|---|---|
| **AC1** | e2e, mock, 1440x900: open `/`, click the first topic row -> `aside.topic` is absent, the middle pane holds that topic's cards, and the sidebar list is the only list of topics on screen | FR-001, FR-002 |
| **AC2** | e2e: on `/?topic=<id>` (or `/t/<id>`), reload -> the same topic is shown; Back -> the previous selection | FR-003 |
| **AC3** | e2e, 1440: open a topic in `#lobby`, then click People, Search (`/search?q=x`), Docs and Boxes in turn -> after each, `aside.topic` is absent | FR-004 |
| **AC4** | e2e: open a topic in `#lobby`, click `#feedback` -> pane behaviour equals today's (`topic-pane-single` stays green) | FR-005 |
| **AC5** | unit (`pane-widths`): default topic width for main widths 1174 and 1654 -> 470 and 662 (± 1), and clamped at 280 / 0.65 / `MAIN_MIN` | FR-006 |
| **AC6** | e2e, 1440, no stored width: open a topic in `#lobby` -> the topic title is not truncated (`scrollWidth <= clientWidth` on the pane title for the mock's longest title) | FR-006, US3 |
| **AC7** | unit: drag-commit in view `issues` leaves `channel` unchanged; a stored flat `{sidebar: .2, topic: .3}` loads as `default` | FR-007 |
| **AC8** | e2e, 1920: the widest message body is ≤ the measure (Q4) in px at the default font level; `no-x-scroll` stays green | FR-008 |
| **AC9** | e2e, 390x844: the existing phone suites (`mobile-*`, `boxes-three-panes`) stay green | FR-009 |

## 7. Overlaps

| with | how |
|---|---|
| topics-view-retire proposal (owner decision pending) | if the owner retires the Topics list, §3.1 / FR-001..003 fall away; §3.2..3.5 stand. Build Phase 2 (Topics) last, after the owner answers (Q1) |
| 074 T008 operator pane (landed `eeecc70d`) | FR-004 closes the operator section too; its rail button reopens it |
| perf plan E28 (`usePaneWidths` resize listener) | Phase 3 touches the same composable: rebase on E28 if it lands first |
| 050 collapse | unchanged; a collapsed pane keeps its stored width |
| c-253 (topic new/total), 079 (unread on the row) | Phase 2 renders topic rows in the middle; keep row markup changes out of this spec |

## 8. Not in scope

Split view (owner ea6330ff: not now). The phone layout. The Topics list's content (clean rows are their own spec, consensus L6). Collapsing with a key (050 Q7: no shortcut).

## 9. Open questions, each with a recommended answer

| # | Question | Recommended answer |
|---|---|---|
| **Q1** | The retire proposal may remove the Topics list. Build §3.1 now? | **Build Phases 1, 3, 4 now; Phase 2 (Topics) after the owner answers the proposal.** The other phases are independent of it |
| **Q2** | Topics address: `/?topic=<id>` or `/t/<id>`? | **`/t/<id>`**: it already renders list + thread (`topic-view-two-panels`), so Topics becomes "the `/t/` view with nothing selected" and one code path serves both |
| **Q3** | Does a section change also close the operator console? | **Yes.** The right pane belongs to what you are doing; its rail button reopens it in one click |
| **Q4** | The measure: 80, 100 or 120 characters? | **100ch** on the body: prose stays readable, and logs and tables lose less than at 80 |
| **Q5** | 40 % default: of the space right of the left pane, or of the window? | **Right of the left pane**: it stays right when the sidebar is collapsed or dragged |

## 10. Version log

| Version | Change | Author |
|---|---|---|
| v0.1 | First spec from the consensus (L1 + L2): Topics two panes, close on section change, proportional default, per-view widths, readable measure | c-245 |

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T22:00:00Z -->
