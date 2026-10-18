# Qto reading panel: claude reviewer seat

Plan reviewed: [qto-reading-panel-plan.md](../qto-reading-panel-plan.md) v0.1,
sha `7cc0239763fbdfc9dea8d14baa55629e5ac40050` (on origin/master).
Epic SPL-2403, issue SPL-2494, task `dispatch-a1b42c34`.

**Seat verdict on v0.1: CHANGE.** The direction is right and both owner points
are in. Two facts in the plan are wrong enough to mislead the build lanes (the
phone breakpoint, and the cause of the short lines on `/docs`), and one red
control is already green on master. Each change below carries its evidence.

## 1. What I re-measured

Run under: dev, served build `a28394183e9ce81091ceca96d01f2f17d2ba6816`,
WUI v2.1.7 (`/build.json` read 2026-10-18), which is the plan's pinned
baseline commit. Headless Chrome 154 driven by puppeteer-core, signed out,
n = 1 page load per viewport. Page: `/docs/DEPLOY.md` (long public runbook).
Phone = 412x915 CSS px, DPR 2.625, mobile + touch; desktop = 1280x800.

| # | number in the plan | my measurement | verdict |
|---|---|---|---|
| M1 | phone top chrome 111 px | `header.top-bar` 0..58 + `.feed-header` 58..111 = **111 px** | agree |
| M2 | phone bottom chrome 73 px | `form.composer` (fixed) 842..893 = 51 + `footer.status-strip` (fixed) 893..915 = 22, so **73 px** | agree |
| M3 | phone text height 731 px, 79.9 % | after scrolling the doc (scroller `.feed-body.docs-page`, 111..915) the band between header and composer is 111..842 = **731 px = 79.9 %** | agree, steady state only |
| M4 | (not in plan) | first screen: the Folders button sits at 127..171 and the doc starts at **183**, so 183..842 = **659 px = 72.0 %** before the first scroll | add |
| M5 | DEPLOY tables overflow 350 px and 314 px | table `scrollWidth - 412` = **350, 314**; but every table's parent has `overflow-x: auto` and the page `scrollWidth` is **412**: the tables already scroll inside their box, the page never scrolls sideways | number agrees; not a defect on master |
| M6 | phone words/line 5.6 on DEPLOY | **4.5** (mean over the 35 `p`/`li` blocks longer than 60 chars, words / distinct line tops) | change: different cause, see 2.2 |
| M7 | desktop top chrome 115 px, text width 861 px, bottom 0 | `.feed-header` 58..115 = **115 px**; first paragraph **861 px** wide; the composer is in the top bar (6..52), **0 px** at the bottom | agree |

Not re-measured: the Qto view `/workspace/docs` numbers (235 px top chrome,
604 px text). That page needs a signed-in member and I used no login. I read
its code instead (2.4, 2.5); the 235 px figure is unverified by this seat.

## 2. Findings the plan misses or gets wrong

### 2.1 The phone breakpoint is 820 px, not 600 px

`composables/useMobileStack.ts:48`: `stack.isMobile` is true at **<= 820 px**
(`MOBILE_STACK_QUERY`), and `-doc-headbar.ts` sets `inHead = !isMobile`. The
sticky in-document bar and the 56 px FAB (`WorkspaceDocsPage.vue:368`,
`@media (max-width: 820px)`) both apply up to 820 px. Every "<= 600 px" in the
plan (sections 1.1, 2.2, 3.1, rows 01, 02, 04) should read "<= 820 px
(`useMobileStack`)", or a 601..820 px tablet keeps the old layout.

### 2.2 On `/docs`, the short lines come from line breaks, not indentation

`pages/docs.vue:134` renders a repo doc with `<MarkdownBlock bare>`, and
`MarkdownBlock.vue:94` turns `bare` into `breaks: true`: every newline of the
source becomes a `<br>`. Repo docs are hard-wrapped near 80 columns, so on a
412 px screen each source line ends early and leaves a ragged half line.
Measured on dev, phone: `/docs/DEPLOY.md` has **52 `<br>` in 19 of its 22
paragraphs**; `/docs/csi-spl-doc/doc/help/getting-started.md` (a Qto export,
unwrapped source) has **0**. The same `bare` call is in
`components/workspace-docs/WorkspaceRepoDoc.vue:18` (a repo doc opened in the
Qto tree). The plan's 44 px indent applies to the Qto outline view
(`WorkspaceDocView.vue:1269`), not to `/docs`, whose paragraphs start at x = 6.

### 2.3 The phone composer is the only search box

At 412 px the docked composer reads "Type /search and a query"; there is no
`/search` field in the phone top bar (the plan's 3.1 sketch draws one).
Hiding the dock on docs routes removes search from the reading screen.

### 2.4 The "four rows" are one wrapping header

`WorkspaceDocsPage.vue:18-54` is ONE `<header class="feed-header wsdocs-head">`
holding the back chevron, the `Documents` heading (`ws_doctree.title`, shown
whenever a document is open), the FAB, the picker and the Outline/Grid pair;
`WorkspaceDocsPage.vue:312` gives it `flex-wrap: wrap`, which is what stacks
them. Row 01 is mostly a CSS change in that one file.

### 2.5 The toolbar overlap is ordinary sticky behaviour

`.wsdoc__bar` (`WorkspaceDocView.vue:1018`) is `position: sticky` and in
flow: at rest it sits above the first line, and while scrolling it covers the
text passing under it, as any sticky bar does. I could not open that view
signed out, so the "first line clipped at rest" claim is unverified here. Its
real cost is the 45 px row it adds below the header, which row 04 removes.

### 2.6 The TOC drawer (overlap 4) has no row

Section 2.2 of the plan lists it (`WorkspaceDocView.vue:1271-1283`, `88vw`,
no backdrop) but no row in 4.1 fixes it.

### 2.7 Most i18n keys already exist

`en.json` already has `ws_doctree.print_doc`, `ws_doctree.toc`,
`ws_doctree.menu.export_md`, `ws_doctree.new_doc`, `ws_doctree.doc_label`,
`ws_doctree.view_doc` and `ws_doctree.view_grid` (lines 2582..2662). Icon
buttons in one strip reuse them as `aria-label`s.

## 3. Verdict per row

| row | verdict | what to change |
|---|---|---|
| 01 single stripe | **change** | Breakpoint <= 820 px (2.1). Target: the `.wsdocs-head` flex row stops wrapping (2.4) and the `[data-test=ws-docs-heading]` "Documents" heading is not shown while a document is open (keep it `sr-only` for screen readers). Red control: at 412x915 on the mock bundle with a document open, `.wsdocs-head` height >= 88 px and the heading visible on master; <= 46 px and heading height 0 with the fix; `.wsdocs-fab` not `position: fixed`. Also run it at 800 px. |
| 02 bottom dock | **change** | Do not hide search (2.3). Either collapse the dock to a search icon in the stripe, or hide it while scrolling down and show it on scroll up or tap. Fix the sites: `layouts/default.vue:61-73` is the desktop dock ("a phone never docks here"); the phone sites are `MessageComposer.vue:1079-1115` and `MobileStatusStrip` at `layouts/default.vue:99-103`. `MessageComposer` serves every route: the red control also checks a channel route keeps its dock (non-regression). |
| 03 i18n keys | **change** | List the new keys first (2.7: most exist). If any are new, this row lands BEFORE rows 01/04/05 (a batch 0), since those rows render them and `i18n-parity` needs all 19 locales; parallel in batch 1 it races row 01. If none are new, drop the row. Red control: name the keys and grep them, not the generic parity run. agy reviews the locales last (language rule). |
| 04 toolbar + indent | **change** | Breakpoint <= 820 px. Red control on what is real (2.5): at 412 px `[data-test=ws-doc-bar]` is a 45 px row inside `.wsdoc` on master; with the fix it lives in the stripe and `.wsdoc__doc` `padding-inline-start` <= 16 px. Keep a reachable tap target for the `.wsdoc__dots` menu (it opens item actions); long-press alone hides it from new readers. Add the TOC backdrop with tap-to-close (2.6), same file. |
| 05 `/docs` viewer | **change** | Drop the table red control: it is green on master (M5). Add: (a) render repo docs without `breaks` so soft newlines join (`pages/docs.vue:134`, `WorkspaceRepoDoc.vue:18`, a prop on `MarkdownBlock.vue` that keeps chat messages unchanged); red control: `/docs/DEPLOY.md` has 52 `p br` on master, 0 with the fix. (b) Fold the Folders button into the header row: the doc starts at 183 px on master (M4), target <= 111 px. |
| 06 e2e test | **agree, with** | Thresholds at both 412 and 800 px; words/line >= 8 only after row 05(a), else it measures the line breaks; run on the mock bundle CI uses; desktop 1280 checks keep top chrome <= 115 px and text width 861 px (M7). |

## 4. The owner's two points

- `< Documents` row removed on a phone: in, row 01. Made measurable above
  (heading hidden while a document is open, header <= 46 px).
- Icons in one thin strip: in, rows 01 and 04. Batch 1 builds the stripe and
  batch 2 moves the three tools into it, so between the two pushes the phone
  still shows the 45 px bar. Row 04 depends on the `#wsdocs-head-tools`
  target that row 01 reshapes; the editor may prefer one lane for both.

## 5. Every row: red control and measurable target

| row | red control | measurable target |
|---|---|---|
| 01 | yes | yes (<= 46 px) |
| 02 | yes | yes (dock height on a docs route), needs the non-regression check |
| 03 | generic only | no: needs the key list |
| 04 | yes, after the 2.5 rewrite | yes (padding <= 16 px) |
| 05 | table part is green on master | yes once (a) and (b) are added |
| 06 | yes | yes |

## 6. Signature

| version | verdict | signed by |
|---|---|---|
| v0.1 | CHANGE (sections 2 and 3) | claude seat, c-430@sat |
