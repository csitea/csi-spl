# Markdown tables panel: claude reviewer seat

Epic: SPL-2403
Spec: csi-spl-doc/specs/040-spool-markdown-compat
Issue: SPL-2468 (this seat), plan issue SPL-2466
Plan reviewed: `csi-spl-doc/doc/md/md-tables-panel-plan.md` v0.1, landed at `75f5a42c7`
Seat: claude, `c002-md-tables-panel-seat-claude` (agent c-398@sat)
Task: `dispatch-16f9044c`

**Verdict on v0.1: CHANGE.** The direction is right and every owner point
has a home, but 4 statements about today's code are wrong, the zebra colours
as written are close to invisible on half the cards, the row hover cannot be
seen, and 3 rows have no real red control. Fold the changes in section 4 and
I sign v1.0.

## 1. What I re-measured, and how

Tree: `origin/master` `341c66cba` (the plan's pin). Served: dev
`build.json` -> commit `af0bb602f`, version 2.1.2, the same build the plan
measured.

The dev probe member (`t1`) cannot open the topics of the 7 measured posts:
`/t/d717bf64-…` shows "Empty topic." for it. So I read the table markdown
of posts 4 (`b7599984`) and 7 (`cf81f620`, its first table, 17 rows) with a
read-only `do_spl_db_query` on dev, posted each, unchanged, as the probe
member into dev `t1` `/lobby` (posts `c6c5a509` and `03280911`, tagged
"table panel re-measure (dev only)"), and measured them in headless Chrome:
412x915 and 1280x800, dark and light, n=1 per cell (8 cells). Script,
`results.json`, log and 8 screenshots:
`/var/spool-hub/dispatch/16f9044c/work/seat-claude/` (not in git: the
tables carry workspace text).

| number in the plan | plan | mine | verdict |
|---|---|---|---|
| post 4 natural table width, phone | 492 px | 492 px | agree |
| post 7 natural table width, phone | 484 px | 484 px | agree |
| post 4 table width, desktop | 774 px | 774 px | agree |
| post 7 wrapped cells, phone / desktop | 85/85, 80/85 | 85/85, 80/85 | agree |
| post 4 wrapped cells, phone / desktop | 24/24, 0/24 | 24/24, 0/24 | agree |
| zebra today (`tbody tr` background) | `rgba(0,0,0,0)` | `rgba(0,0,0,0)`, every row, both themes | agree |
| header background | `rgb(10,20,36)` dark, `rgb(220,231,246)` light | same | agree |
| cell padding | `0.25em 0.6em`, about 3.5 px | 3.74 px x 8.98 px at 14.96 px | agree |
| phone overflow, post 4 / post 7 | 166 px / 158 px | 100 px / 92 px | **depends on the view**: see below |

The overflow difference is the container, not the table: in a topic view the
plan measured a 380 px card and a 326 px `.md-table`; in `/lobby` I measured
a 400 px card and a 392 px `.md-table`. The table widths agree to the pixel.
So "overflow" is a property of (table, view): v1.0 should name the view of
each number and set targets on the narrowest one, the topic view.

Not re-measured: posts 1, 2, 3, 5, 6; the "over 95% of agent tables omit
alignment delimiters" claim (the plan shows 7 posts, all left-aligned: that
is n=7, not a fleet rate; say "7 of 7 measured" or count it with a query);
the "> 7:1 contrast" claim (computed below, it holds).

## 2. Plan statements checked against the code

Each checked with the command or test shown, on `341c66cba`.

1. **A comment hint is visible text today, not invisible.** The plan calls
   `<!-- table: compact, no-sort -->` "invisible". In the renderer it is not:
   `markdownTree(src, {html: true})` returns the text node
   `"<!-- table: compact, no-sort -->\n"` before the table (an `html_block`
   with no `<table` falls to "its source, as text",
   `csi-spl-wui/src/utils/markdown.mjs:571`), and with `html: false` (a ```md
   fence) a `p` holding the same text. Good news for row 02: that is a ready
   red control. But the plan text must say "shown as text today; row 02
   hides it".
2. **The caption hint collides with spec 137's caption.** `Table: <desc>` is
   already a caption, read from the line directly UNDER a pipe table
   (`markdown.mjs:414-431`). The plan's example puts `Table: [compact, dense]
   ...` ABOVE the table: today that renders as a paragraph. Put under, it
   renders the caption "**Table:** [compact, dense] Performance summary",
   brackets and all. And on a code host it is visible text either way, so
   it is not "portable" in the sense the plan claims. Drop the caption form,
   or define it as "a leading `[...]` in a spec 137 caption is stripped and
   read as hints" and test both positions.
3. **HTML table classes do not pass today.** `htmlTableNodes` builds a
   `table` with no attributes (`markdown.mjs:314`, `el(tag, ... : {})`):
   `<table class="compact no-sort">` comes out as `{"tag":"table","attrs":{}}`.
   The plan reads as if the allow-list exists ("`htmlTableNodes` allows a
   closed set"); it is to be built in row 02. Say so.
4. **HTML tables have no `tbody`.** The same `<table><tr>...` comes out with
   `tr` directly under `table`. A zebra rule on `tbody tr:nth-child(even)`
   never stripes an HTML table. Use `tr:nth-child(even of :not(thead tr))` or
   stripe both shapes, and give row 01's red control an HTML table too.
5. **The bundle ceiling is 155 KB, not 210 KB.** `ci_initial_gzip_kb: 155.0`
   in `csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json:4`.
6. **Table CSS lives in `MarkdownBlock.vue`, not `main.css`.** The table
   rules are the scoped `:deep()` rules at
   `csi-spl-wui/src/components/MarkdownBlock.vue:318-343`.
   `main.css:395-411` is the message card (`.msg`) layout and its SPL-2120
   card shading. Rows 01 and 06
   cite `main.css:411` / `:395`: re-point them, which also changes the R1
   batching (rows 05 and 06 both edit `MarkdownBlock.vue`; they are in
   batches 3 and 4, so still disjoint per batch, but row 01 joins them).
7. **The theme list is 8, not 2.** `variables.css` defines `:root`, `dark`,
   `light` and five `light-*` palettes (lines 116-337). Built from existing
   tokens with `color-mix`, row 01 needs no `variables.css` edit at all;
   with new tokens it needs 8 blocks. Pick one and say which.
8. **The help page has a WUI copy.** `csi-spl-doc/doc/help/how-to-post.md`
   is copied to `csi-spl-wui/src/public/help-md/how-to-post.md` by
   `src/node/help/sync-help.mjs`, and `tests/unit/help-sync.test.mjs` fails
   while they differ. Row 10 must run the sync and list the copy as a site.
9. **The locales are 19, not 3.** `ls csi-spl-wui/i18n/locales` -> 19 files;
   `i18n-parity.test.mjs` refuses a key missing from any. Row 03 lists 3.
   And per the language rule its text gets an agy review last.

## 3. The colours, computed

Card shades are already alternated (SPL-2120, `main.css:411`:
`.msg:nth-child(even of .msg)` paints `--color-row-alt`): measured, the
even card is `rgba(255,255,255,0.06)` dark and `rgba(12,22,38,0.06)` light,
the odd card transparent. A table stripe sits on either. WCAG contrast
ratios between neighbouring rows (tokens read from the live page):

| | odd card vs even card (today) | plan stripe vs base, odd card | plan stripe vs base, even card |
|---|---|---|---|
| dark | 1.12 | 1.08 | **1.02** |
| light | 1.13 | 1.06 | **1.01** |

On every second card the plan's stripe is near 1.0: there is no visible
zebra. The cause is an opaque `color-mix(... , transparent)` of a surface
colour close to the card's own. Fix: a translucent overlay that stacks on
either card, e.g. `background: var(--color-row-alt)` (or a new
`--color-table-stripe` defined as a translucent `--color-fg` mix), so the
stripe is the same step (about 1.12) on both cards. Text contrast holds in
all cases (`--color-fg` on the plan's stripe: 16.3 dark, 15.0 light).

**Row hover is invisible.** The plan's row hover is
`var(--color-surface-hover)`. Hovering a card already paints the whole card
that same colour: measured `rgb(21,37,68)` = `#152544` dark,
`rgb(212,227,246)` = `#d4e3f6` light, exactly `--color-surface-hover`. A row
can only be hovered inside a hovered card, so the row never differs from its
card. Use a step on top of the card hover, or drop row hover (it is not an
owner point).

**Sticky column 0 needs an opaque background.** The plan writes
`background: inherit`; rows and cells measure `rgba(0,0,0,0)` today, so the
sticky cell inherits transparency and scrolled cells show through it. It
needs the card's resolved colour, which differs per card shade and on hover:
the simplest correct form is an opaque `--color-bg`/card base plus the same
translucent stripe layered as a `background-image`. Give row 06 a red
control that reads the sticky cell's computed background at scrollLeft > 0.

## 4. Per row: agree / change / reject

| # | verdict | evidence and the change |
|---|---|---|
| 01 zebra + tokens | **change** | sites: `MarkdownBlock.vue:318-343`, not `main.css:411`; stripe as a translucent overlay (section 3) so it reads on both card shades; stripe HTML tables too (section 2.4); no row hover, or a visible one. Red control is good: add "stripe vs base contrast >= 1.10 on an odd AND an even card, dark and light". |
| 02 hints + HTML classes | **change** | red control exists today: comment shown as text (section 2.1). Target: the comment yields no text node and sets the classes; an unknown token and `class="x" style="..."` yield nothing. Drop or redefine the caption form (2.2). Say both `html: true` and `html: false` paths. |
| 03 i18n keys | **change** | all 19 locales, not 3 (2.9); "verified green" is not a red control: red = parity test fails with the key in `en.json` only. agy review as the last step (language rule). Kind `i18n`, not `simple_coding`. |
| 04 sort helper | **agree** | pure, isolated, testable; add to the target: rows with equal keys keep source order (stable), empty cells sort last in both directions, `-` and an em dash count as empty. |
| 05 sort headers | **change** | `MdNodes` is a stateless `FunctionalComponent` (`MarkdownBlock.vue:200`): sort state needs a small stateful table component; say so. A table with any `colspan` or `rowspan` (HTML tables allow them, `cellAttrs`) is not sortable: reordering rows breaks the spans. The threshold counts BODY rows; the plan's section 2.1 "Rows" counts the header (post 3 is 1 body row, post 6 is 2). Sort is a view change only: Show source and copy keep the author's order. |
| 06 scroll shadows + sticky col | **change** | opaque sticky background with a red control (section 3); `<=820px` matches the existing `main.css:896` breakpoint, good. Target on the topic view, the narrowest (section 1). |
| 07 numeric auto-align | **change** | the target must keep the author's explicit alignment: a column with `:---` stays left. Define "numeric column" (e.g. >= 80% of non-empty body cells parse as numbers by row 04's parser) and test a mixed column (post 7 has IDs like `FR-ML-001`: must not go right-aligned). |
| 08 unit tests | **change** | move each test into the row that adds the behaviour: rulebook C2 (`rounds-rulebook.md:100`) wants the red control verified RED then GREEN, which a tests-only row after the features cannot show. Keep 08 only for the hostile-input sweep. |
| 09 e2e | **change** | same: the e2e for sort lands with row 05, for phone layout with 06. Name it `tests/e2e/<name>.test.mjs` run by `pnpm run test:e2e` (mock bundle, offline); the live proof, if any, is a `*-live.proof.mjs`. |
| 10 docs | **change** | add the WUI copy site and the sync (2.8); kind `specs_and_docs`, not `simple_coding`. Red control: `help-sync.test.mjs` red before the sync, green after. |

## 5. The owner's points

| owner point (t1 `16f9044c`) | in the plan | verdict |
|---|---|---|
| sortable by columns (`451b147a`) | 3.2, rows 04-05 | in; fix row 05 as above |
| alternating colours (`451b147a`) | 3.1, row 01 | in, but invisible on even cards as written: fix row 01 |
| up to the existing style and theme (`451b147a`) | tokens only, 3.1 | in; must cover all 8 palettes (2.7) |
| customizable, per table (`9950023b`, `ced916e0`) | 3.4 tiers 1-2, row 02 | in for authors. Gaps: CSS for `compact`, `dense`, `no-zebra`, `stacked`, `scroll` is in no row's sites or target; tier 3 (reader density toggle in settings) has no row. Either add them to rows 01/06 with targets or mark tier 3 "not in this round". |

## 6. Signature

**Signed: plan v1.0 at `81404325d`.** Checked against v1.0, not taken from
the editor's message: every blocking point of section 4 is folded (zebra as
a translucent `var(--color-row-alt)` overlay for pipe and HTML tables with a
>= 1.10 target on odd and even cards; row hover a `--color-fg` 4% overlay,
no longer the card hover colour; opaque sticky column 0; comment hint as row
02's red control; caption hints read under the table per spec 137; 155 KB
budget; table CSS sited in `MarkdownBlock.vue`; 19 locales with the parity
red control and agy last; help copy and `help-sync.test.mjs` in row 10;
stateful sort, body rows >= 3, no sort with colspan/rowspan, view-only
order; numeric detection keeps explicit alignment; topic-view targets;
tier 3 marked a follow-up).

Two residuals, not blocking, for the build lanes:

1. Row 06: `background: var(--color-bg)` on the sticky cell is opaque but
   is the page colour, so on an even (shaded) card, a striped row or a
   hovered card the sticky cell is a different shade from its row. Layer
   the same translucent stripe/hover over the opaque base (for example as a
   `background-image` gradient) and give the red control an even card.
2. Row 09: the e2e still lands as its own tests row after rows 05 and 06.
   Rows 05 and 06 now carry their own red controls, so C2 holds; row 09
   adds browser coverage only.

Note: v1.0's signature table (line 285) listed this seat as signed before
this commit; this commit is the seat's signature.
