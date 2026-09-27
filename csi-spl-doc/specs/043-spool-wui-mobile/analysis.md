# 043 Analysis: today's WUI at phone and small-tablet widths

Posted in prd t1 topic `c397d781` by CLE-35022 (message `a657ea12`, 2026-09-27 08:18Z), then the comparison with AGY-3501 and the decisions. Kept here as posted, apart from the heading levels.


**Run:** prd e2e (build v0.9.7, trunk f9e87b07), headless Chrome with touch emulation, n=1 per width, 8 routes plus flows. Nothing was typed or sent. Screenshots at 390 px are attached.

## 1. The shell (owner model: one panel at a time)
| check | 360 | 390 | 430 | 768 | 820 |
|---|---|---|---|---|---|
| sidebar = rail + list | 72 (18+54) | 72 (20+53) | 72 (22+51) | 72 (38+34) | 260 (41+219) |
| rail tab tap size | 17 px | 19 px | 21 px | 37 px | 40 px |
| channel/DM names readable | no | no | no | no | yes |
| middle panel width | 288 | 318 | 358 | 696 | 554 |
| topic pane on open | 280 over feed at x=80 | 280 at x=110 | 280 at x=150 | 380 overlay | 380 overlay |
| topic close button | 32x32 | 32x32 | 32x32 | 32x32 | 32x32 |
| browser Back after opening a topic | leaves the page | same | same | same | same |
| horizontal page scroll | none | none | none | none | none |

- **broken:** three columns squeezed onto a phone. The list shows `#` and avatars only, so you cannot tell channels apart. The topic pane covers most of the feed but leaves a 72 to 150 px strip of it showing. Opening a topic adds no history entry, so Back leaves the page.
- 820 px still renders the full desktop layout (260 + 554 + a 380 overlay).

## 2. Composing (the biggest gap)
| check | 360-430 | 768-820 |
|---|---|---|
| composer visible in a channel | **no**: it sits in the top bar behind the search icon | yes, in the top bar (234-286 px wide) |
| after tapping search | a top overlay 121-165 px tall; text box 176-246 px wide; attach 42x54; send 42x42 | - |
| composer at the bottom, above the keyboard | no | no |
| viewport meta | `width=device-width, initial-scale=1` (no `viewport-fit=cover`, no `interactive-widget`) | same |

## 3. Messages
| check | 360 | 390-820 |
|---|---|---|
| message menu button | 32x32 | 32x32 |
| emoji button | 32x32; the picker did not open | 32x32; the picker (333x213) fits |
| card header | wraps to 3 rows (name, then time+emoji+open, then the menu) | 2-3 rows |
| hover-only controls (opacity 0) | 3: the card-clip modes (titles, rows, full) | same |
| controls under 44 px, #lobby | 136 of 162 (47 under 24 px) | 138 of 162 at 390 |

## 4. Pages
| page | phones (360-430) | 768 / 820 |
|---|---|---|
| Issues | 8-column table; 106-130 controls sit off-screen to the right inside the table; sort headers 36x20; the keyboard-hint line (C / J / K) takes 3 rows; the left list shows only "0/1" counts | 31 / 54 controls off-screen |
| Issue detail | fixed 380 px overlay (at <= 1100 px), not full screen | same |
| Settings | 7 tabs wrap to 4 rows; profile e-mail breaks every ~7 characters in a 2-column grid | fine |
| Search, Events, Archive | readable; same squeezed shell | fine |
| Top bar | language box clipped to "Eng"; theme 32x32; tenant switcher 63x22 | ok |
| User menu | opens in view (272 px) | ok |

## 5. The most-used desktop functions on a phone today
| function | today | owner model |
|---|---|---|
| choose a section (DMs, Channels, Issues, Topics, Flow, Events, Archive) | 17-21 px icons | level 1, full width, names shown |
| open a channel or DM | names hidden | level 1 row, then level 2 |
| read a feed | 288-358 px wide | level 2, full width |
| send a message | hidden behind search | pinned at the bottom of levels 2 and 3 |
| open a topic or thread, reply | partial overlay; Back leaves the page | level 3, full screen, Back returns to level 2 |
| react, message menu (edit, delete, kind, copy link) | 32 px buttons | 44 px, long-press or a visible menu button |
| attach a file | only inside the search overlay | in the bottom composer |
| search | search icon, then the overlay | keep the icon in the level 1/2 header |
| issues: list, sort, filter, open, edit | table overflows; detail is an overlay | level 2 card list, level 3 full-screen detail |
| settings, profile, language, theme | usable but wraps | own full-width pages |
| switch tenant | 63x22 select | level 1 header |
| keyboard shortcuts (/, e, Del, J/K, C, Ctrl+Enter) | no touch equivalent | a visible button per action; hide the hint lines |
| drag: pane dividers, rail order, card grip | mouse only | none on phones (rail order stays in Settings) |

## 6. Compared with Slack mobile
Slack shows one full-width screen at a time: Home (sections and lists), then a channel, then a thread. Each screen has a back arrow top-left, and a right swipe or the OS Back goes back too. The composer is pinned at the bottom above the keyboard, a long-press on a message opens the reactions and actions, and there is a bottom tab bar. The owner's model matches Slack's stack. The one real open question is whether we add a bottom tab bar (see the discussion that follows).


## Where we agree
- Three columns do not fit a phone. The 72 px rail hides every channel and DM name, and Issues is unusable.
- The composer is missing on phones: it lives in the top bar behind the search icon. It must be pinned at the bottom of the chat (levels 2 and 3), above the keyboard.
- The topic pane needs a full-screen view with a back arrow, and Back must work.
- 32 px menu and emoji buttons, and controls that only appear on hover, need 44 px targets or a long-press.
- The viewport meta needs `viewport-fit=cover` and safe-area padding, and inputs need a 16 px font so iOS does not zoom.

## Where we differ (measured beats read)
| claim | AGY (read from code) | CLE (measured, prd 0.9.7) |
|---|---|---|
| topic pane on a phone | 100 % wide (360) or 380 px wide (390) | **280 px** at 360-430, leaving a 72-150 px strip of the feed; 380 px only at 768 and 820 |
| 820 px | desktop layout | agree: it is desktop now, and the plan moves it into the one-panel stack |
| Back after opening a topic | not measured | **leaves the page**: opening a topic adds no history entry |
| iOS zoom on focus | reported | not measured (my browser was Chrome) |

AGY adds the notch/safe-area point and the <16 px input-zoom point; both are now in the plan.

## Discussion, and what I decided (you said to work autonomously)
| question | options | decision |
|---|---|---|
| how sections are chosen | a bottom tab bar (Slack) vs your level-1 panel | **your level 1**: a full-width screen with the sections as a row of 44 px icon+label tabs across the top, and the chosen section's list (names shown) below it. No bottom tab bar, because it would duplicate level 1. |
| tablets 600-820 px | two panes side by side vs one | **one panel**, the same stack as phones (M1). Above 820 px nothing changes. |
| moving between levels | slide vs instant | a 200 ms slide from the right (none with reduced motion). Back, a right swipe and browser Back all go up one level. |
| message actions | hover toolbar vs long-press vs the menu button | a **44 px menu button stays visible**, and a long-press opens the same menu as a bottom sheet. Reactions go in that sheet. |
| composer | top bar vs bottom | **bottom** on levels 2 and 3; the top bar keeps search only. |
| dropped on phones | - | drag dividers, drag-to-reorder the rail (still in Settings), the keyboard-hint lines, the version hover card |

The plan with 5 lanes (M1-M5, already started by CLE-001) is being written as spec 043. I verify each lane at 360/390/430/768/820 + 1440 and post a scoreboard here every 20-30 min.
