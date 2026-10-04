# 084: compact row spacing

**Feature ID**: `084-compact-row-spacing` · **Milestone**: M3 · **Status**: Planned
**Created**: 2026-10-04 · **Lane**: c-245 (spec only) · **Topic**: 3a74320e-b5b0-44b8-bf1e-6d1b9c84d5ed
**Authority**: this file for the behaviour; `tasks.md` for what is built, with the sha and the check for each item. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing.

Builds on, and does not repeat:
[023 user settings](../023-spool-user-settings-keys/spec.md) §3.5 (Appearance, the five font levels),
[078 desktop layout](../078-desktop-wide-thread-layout/spec.md) (Phase 4 caps the same card rules),
help `../../doc/help/user-settings.md` §4.3 *List density* (the clip: titles / rows / full, unchanged).

Evidence base: `../../doc/md/desktop-usability-consensus-20261005.md` L9 (agreed by c-245 and g-248: padding only, late, after L1); ideas doc §3.9; grok view part B #9.

---

## 1. Why, and the owner's ask

Owner go: ea6330ff (starter #9 "Density setting": "compact / comfortable rows, so a 1440 px screen shows more topics without smaller fonts (fonts stay on the 5 rem levels)").

## 2. Today, measured

| # | fact | evidence |
|---|---|---|
| 1 | One-line message cards sit 73 px apart at 1440x900, font level 3 (menus at y 134, 207, 280 on `/lobby`): about 10 per screen | ideas doc §3.9 (mock, n=1 page, 3 cards) |
| 2 | A Topics row is 99 px tall: about 8 fit in the 842 px pane | grok view part B #9 (n=5 rows) |
| 3 | The card rule is fixed: `.msg { grid-template-columns: 36px minmax(0,1fr); gap: 10px; padding: 8px 4px; }`; avatar default 36 px | `src/assets/css/main.css:328-336`, `src/components/SpoolAvatar.vue:29` |
| 4 | No spacing variables exist (only `--spacing-xs..xl`, `--radius*`, `--tap`) | `src/assets/css/variables.css:12-16,76-80,101` |
| 5 | *List density* (`card-clip`) clips the body to titles / rows / full; it does not change spacing | `src/utils/card-clip.mjs:27-35` |
| 6 | Font size is a browser setting applied as `data-font-size` on `<html>`, mapped to `--font-root` in CSS | `src/utils/font-size.mjs:16-24,56-59`, `src/assets/css/base.css:12` |
| 7 | g-248: the Topics pane looks empty because its rows are drawn twice, not because type is large | grok view A1, part B #9 (fixed by 078 Phase 2) |

## 3. The design

A new Appearance setting, **Row spacing**: *Comfortable* (today, the default) or *Compact*. It is stored per browser like the font size and applied as `data-row-spacing="compact"` on `<html>`. CSS variables carry the difference:

| variable | comfortable (today) | compact |
|---|---|---|
| `--row-pad-y` | 8px | 3px |
| `--row-gap` | 10px | 8px |
| `--row-avatar` | 36px | 24px |
| `--row-list-pad-y` (sidebar / Topics rows) | today's value | about 60 % of it |

In compact, a one-line card puts the time on the header line it already shares (no layout change beyond padding and avatar size). Fonts, tap targets on touch devices (`--tap`) and the *List density* clip are unchanged. At ≤ 820 px the setting is ignored (phones stay comfortable).

## 4. User stories

| ID | Priority | Role | Story | Benefit |
|---|---|---|---|---|
| **US1** | **P2** | Member on a 1440 px screen | Switch to compact and see about a third more cards and rows, at the same font size | starter #9 |
| **US2** | **P2** | Member | Keep comfortable as it is today if I do nothing | no surprise |

## 5. Functional requirements

| ID | Description | Status |
|---|---|---|
| **FR-001** | Appearance gains *Row spacing* (Comfortable default, Compact), stored per browser (`spool-row-spacing`) and applied as `data-row-spacing` on `<html>` before first paint | Planned |
| **FR-002** | Card and list-row spacing read `--row-pad-y`, `--row-gap`, `--row-avatar`, `--row-list-pad-y`; comfortable values equal today's pixels | Planned |
| **FR-003** | Compact changes only padding, gaps and avatar size: no font-size, line-height of body text, or clip change | Planned |
| **FR-004** | At ≤ 820 px the attribute has no effect | Planned |
| **FR-005** | The setting's name does not reuse "density" (help §4.3 keeps *List density* for the clip) | Planned |
| **FR-006** | Help `user-settings.md` §4 gains a *Row spacing* subsection | Planned |

## 6. Acceptance scenarios

| # | Check / test | Proves |
|---|---|---|
| **AC1** | e2e, mock, 1440, font level 3, comfortable: the three `/lobby` card menus are 73 px apart (± 1), unchanged from today | FR-002 (no regression) |
| **AC2** | e2e: compact -> the same three cards are ≤ 56 px apart; the body text's computed `font-size` equals comfortable's | FR-002, FR-003 |
| **AC3** | e2e: compact, reload -> still compact with no comfortable flash (the attribute is set before first paint: check it in the first `DOMContentLoaded`) | FR-001 |
| **AC4** | e2e, 390x844 with compact stored -> card pitch equals comfortable's | FR-004 |
| **AC5** | unit (`row-spacing`): load / save / apply round trip; unknown stored value -> comfortable | FR-001 |
| **AC6** | `no-x-scroll`, `card-edge-inset`, `font-size` suites stay green in both modes | no regression |

## 7. Overlaps

| with | how |
|---|---|
| **078 Phase 4** (message measure) | edits the same `.msg` rules: build this after 078 T006 and rebase on it |
| 078 Phase 2 | removes the duplicated Topics list; compact is worth less until then (consensus: late) |
| card-clip (*List density*) | orthogonal: clip = how much text, spacing = how much air |
| 023 Appearance | one more control on the same page, below Font size |

## 8. Not in scope

Smaller fonts (the five levels stay). A third "cozy" step. Phone spacing.

## 9. Open questions, each with a recommended answer

| # | Question | Recommended answer |
|---|---|---|
| **Q1** | Per browser, or an account preference on the hub (like `message_order`)? | **Per browser**, like font size and *List density*: a 1440 laptop and a 2560 desk screen want different spacing, and it needs no migration |
| **Q2** | Name: "Density", "Compact mode" or "Row spacing"? | **Row spacing**: "density" is taken by the clip setting in help §4.3 |
| **Q3** | Shrink the avatar in compact? | **Yes, to 24 px**: it is the largest fixed height in a one-line card |

## 10. Version log

| Version | Change | Author |
|---|---|---|
| v0.1 | First spec from the consensus (L9): Row spacing comfortable / compact, padding and avatar only | c-245 |

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T23:05:00Z -->
