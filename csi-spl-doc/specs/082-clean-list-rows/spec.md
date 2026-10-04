# 082: clean list rows

**Feature ID**: `082-clean-list-rows` · **Milestone**: M3 · **Status**: Planned
**Created**: 2026-10-04 · **Lane**: c-245 (spec only) · **Topic**: 3a74320e-b5b0-44b8-bf1e-6d1b9c84d5ed
**Authority**: this file for the behaviour; `tasks.md` for what is built, with the sha and the check for each item. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing.

Builds on, and does not repeat:
[034 topic gist](../034-spool-topic-gist/spec.md) (a topic's short title, when one exists),
[062 flow per-user counts](../062-flow-per-user-counts/spec.md) (Flow rows),
[078 desktop layout](../078-desktop-wide-thread-layout/spec.md) (the Topics list is drawn once).

Evidence base: `../../doc/md/desktop-usability-consensus-20261005.md` L6 (agreed by c-245 and g-248); ideas doc §3.13; grok view A5; mobile list `../../doc/md/mobile-usability-ideas-20261004.md` §3.13 (**also mobile**).

**Consensus L7 ("3 replies" instead of "3 >>") is not specced here.** The code records an owner decision for exactly that control: `src/components/MessageCard.vue:135`, *"SPL-982 (owner, topic 8296eeec): exactly "3 >>", no word; the name ("3 replies - Open topic") stays on aria-label and title"*. Neither walk knew it. It goes back to the owner as §9 Q4; nothing changes until then.

---

## 1. Why, and the owner's ask

Owner go: ea6330ff. The Topics list is the index a person scans; today its rows show markup and a repeated label, and their times hide the date.

## 2. Today, measured

| # | fact | evidence |
|---|---|---|
| 1 | Every Topics row starts with `Topic:`, in the sidebar and the middle list | both walks (`topics-1440.png`); `"list_title": "Topic: {text}"` in all 19 `i18n/locales/*.json` (`grep -l '"list_title"' i18n/locales/*.json \| wc -l` -> 19) |
| 2 | Rows show raw markdown: `Welcome to **#lobby**. …` | both walks; `topicOpening` (`src/utils/view-api.mjs:47-52`) only collapses whitespace and cuts to 100 characters |
| 3 | The row title is built twice, the same way: `topicRowTitle` in `src/pages/index.vue:161-164` and in `src/components/ChannelSidebar.vue:832-835` | code read |
| 4 | Desktop rows print a clock only (`formatTs` -> `isoClock`), so a row from 2026-09-18 reads like today; the card for the same message prints the date | grok view A5 (n=5 rows); `src/pages/index.vue:158` `rowTime`, `src/utils/channel-feed.mjs:234` |
| 5 | Phone rows already show a date when not today (`formatMsgListTs`, `phoneCardTime`) | `src/utils/channel-feed.mjs:261,289` |
| 6 | No markdown-to-plain helper exists | grep for `strip`, `plain`, `toPlain` in `src/utils` finds only bidi and code-view helpers |
| 7 | In a 212 px sidebar the prefix pushes titles onto an extra line | `topics-1440.png`: 4 of 5 sidebar rows wrap to 2..4 lines |

## 3. The design

1. **Plain text.** A row title is the opening line as plain text: markdown marks removed (emphasis, code ticks, link syntax keeps its text, headings, list bullets, block quotes), mentions and channel names kept as text. Where a topic has a gist (034), the gist is used.
2. **No `Topic:` prefix** in lists that are already Topics lists (the Topics sidebar and middle list). Other uses of `topic.list_title` (page headers, pickers) are out of scope (Q2).
3. **A date when it is not today.** Desktop rows use the same list-time rule as phone rows: clock for today, `MM-DD HH:MM` this year, the full date before that.
4. **One builder.** Both lists call one `rowTitle(subject, gist)`.
5. **Flow rows** (Phase 2) use the same plain-text helper for their text line.

## 4. User stories

| ID | Priority | Role | Story | Benefit |
|---|---|---|---|---|
| **US1** | **P1** | Member | Scan the Topics list and read titles, not markup or a repeated label | faster scanning; fewer wrapped lines |
| **US2** | **P1** | Member | See that a topic is two weeks old from its row | the row and the card agree (A5) |
| **US3** | **P2** | Member | Read Flow entries without markup | the same rule everywhere |

## 5. Functional requirements

| ID | Description | Status |
|---|---|---|
| **FR-001** | A pure `plainText(md, max)` removes markdown marks and keeps the text; `rowTitle` uses the gist when present, else `plainText(opening, 100)` | Planned |
| **FR-002** | Topics sidebar rows and Topics middle-list rows show `rowTitle(...)` with no `Topic:` prefix | Planned |
| **FR-003** | Desktop Topics rows show the list-time rule (clock today, `MM-DD HH:MM` this year, date before) | Planned |
| **FR-004** | `index.vue` and `ChannelSidebar.vue` share one builder | Planned |
| **FR-005** | (Phase 2) Flow row text uses `plainText` | Planned |
| **FR-006** | Screen readers hear the same plain title (no "asterisk asterisk") | Planned |

## 6. Acceptance scenarios

| # | Check / test | Proves |
|---|---|---|
| **AC1** | unit (`plain-text`): `Welcome to **#lobby**.` -> `Welcome to #lobby.`; `` `x` `` -> `x`; `[docs](https://example.com)` -> `docs`; `> quote` -> `quote`; `# Title` -> `Title`; 120 characters -> 100 + `…` | FR-001 |
| **AC2** | e2e, mock, 1440: on `/`, no sidebar or middle Topics row text starts with `Topic:` and none contains `**` | FR-002, FR-006 |
| **AC3** | e2e: the mock's 2026-09-18 topic row shows `09-18` (or the full date in another year); a topic from today shows only `HH:MM` (fixture with a today timestamp) | FR-003 |
| **AC4** | unit: `topicRowTitle` no longer exists in `index.vue` / `ChannelSidebar.vue` (`grep -c topicRowTitle` -> 0 in both) | FR-004 |
| **AC5** | e2e (Phase 2): a Flow entry with `**bold**` shows `bold` | FR-005 |
| **AC6** | existing tests asserting `list_title` (`topic-page-header`, `born-topics`, `sidebar-tabs`, `merge-topic`, `id-links`, `parent-level`, `move`) are updated only where they assert a Topics list row; the rest stay green unchanged | scope (Q2) |

## 7. Overlaps

| with | how |
|---|---|
| c-253 (topic new/total, running), 079 T005, 080 T004 | all touch Topics row templates: rebase on whichever landed; this spec changes only the title and time text |
| 078 Phase 2 | the middle list may go; FR-002 then applies to the sidebar only |
| `topics-view-retire-proposal.md` | if the Topics list is retired, `plainText` and the time rule still serve Flow and search rows |
| c-246 mobile §3.13 | the same idea; this spec covers both |

## 8. Not in scope

Changing "3 >>" (owner SPL-982, see Q4). Page headers and pickers that use `topic.list_title`. Generating gists (034).

## 9. Open questions, each with a recommended answer

| # | Question | Recommended answer |
|---|---|---|
| **Q1** | Strip markdown in the client, or have the hub send a plain subject? | **Client**, in one pure helper: no API change, and it also serves Flow and search rows |
| **Q2** | Drop `Topic:` everywhere `topic.list_title` is used? | **Only in the two Topics lists**: elsewhere (pickers, headers) the label tells a topic from a channel |
| **Q3** | Keep the time at all on desktop rows? | **Yes**, with the date rule: the age of a topic is what the row is scanned for |
| **Q4** (owner) | Both walks proposed "3 replies" for the reply control, but your SPL-982 decision (topic 8296eeec) set exactly "3 >>". Keep "3 >>"? | **Keep "3 >>"**: it is your decision, and the words are already on its `aria-label` and tooltip. Only change it if you say so |

## 10. Version log

| Version | Change | Author |
|---|---|---|
| v0.1 | First spec from the consensus (L6): plain row titles, no `Topic:` prefix, dated row times, one builder, Flow rows; L7 returned to the owner (SPL-982) | c-245 |

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T22:45:00Z -->
