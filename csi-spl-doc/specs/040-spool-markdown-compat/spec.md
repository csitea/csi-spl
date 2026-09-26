# Spec 040 — Markdown compatibility

Epic SPL-74. Issues: SPL-73 (render), SPL-75 (this spec).
First written as `039-spool-markdown-compat` (1c099b52); renumbered 040
because `039-spool-issues` already owns 039 and code cites "spec 039 §3.4"
for issues.

Owner, 2026-09-26 (prd #spool-hub-devel, topic 070843ba): "the display of the
issues, msgs etc. should recognize some kind of start and stop wiki tag /
template code and then know to convert standard markdown ... so that tables,
lists etc. regular markdown should be doable ... registered under a new
feature called markdown compatibility".

Status vocabulary: `../README.md` §2.3.

## 1. Requirements

| ID | Requirement | Status |
|---|---|---|
| FR-MD-001 | The START / STOP marker is a fence whose language is `md` or `markdown`, any case (```` ```md ```` … ```` ``` ````). Between them, standard markdown renders: headings, bold / italic / strikethrough, ordered and bullet lists, tables (with column alignment), block quotes, horizontal rules, links, inline and fenced code. | Implemented (T001, T002) |
| FR-MD-002 | Text outside such a block renders exactly as before: Slack-style code, mentions, links, file chips. | Implemented (T002) |
| FR-MD-003 | Nothing in a block becomes markup that the author controls. Raw HTML is shown as text. Only allow-listed tags and attributes reach the DOM. A link's href must be an absolute `http`, `https` or `mailto` URL, and every link opens in a new tab with `rel="noopener noreferrer nofollow"`. Any other link shows its text only. | Implemented (T001, T003, T006) |
| FR-MD-004 | A block can be flipped to its source text ("Show source") and back. | Implemented (T002) |
| FR-MD-005 | Messages, topics and the Issues right pane all render it. Issue comments render through `MessageBody`. An issue description that holds a markdown block or a `{{wiki}}` region gets a rendered view under its textarea, and the textarea stays the source. | Implemented (T002, T005) |
| FR-MD-006 | No network from a block. `![alt](url)` renders as a link to the picture, labelled with its alt text, and is never fetched. The deployed CSP `img-src` is `'self' data:`, so a remote image would be blocked anyway. | Implemented (T006) |
| FR-MD-007 | The first render cannot change. The markdown engine is a lazy chunk, loaded only when a page shows a block. The first render (server and client) is the source as plain text, so the prerendered HTML and its CSP hashes stay the same. A chunk that fails to load leaves readable text. | Implemented (T006) |
| FR-MD-008 | Works in all 5 themes (token colours only) and at all 5 font-size levels (`rem` / `em`, never `px`). A wide table scrolls inside the block and never widens the page. | Implemented (T002, T007) |
| FR-MD-009 | Editing a message (the composer / message edit) shows the source, never the rendered form. | Implemented (unchanged: edit works on the raw body) |

### 1.1 SPL-975: markdown without a fence (owner, 2026-09-26, topic 467d6325)

> "an agent should ensure that the markdown understands all of the major
> markdown syntaxes and the agents should receive instructions on how to post
> messages ... by using the markdown will get properly rendered ... html
> tables as well"

This amends FR-MD-001, FR-MD-002 and FR-MD-005. The fence stays a marker
that works; it is no longer needed.

| ID | Requirement | Status |
|---|---|---|
| FR-MD-010 | A body whose text outside ``` blocks holds markdown (`looksLikeMarkdown`) renders whole as markdown: headings, bold / italic / strike, bullet, numbered and nested lists, links, inline code and code blocks, quotes, GFM pipe tables, rules. A single newline is a line break. | Implemented (T009) |
| FR-MD-011 | An HTML `<table>` renders through an allow-list (`htmlTableNodes`): table parts plus a few inline tags; only align / text-align (as `data-align`) and a numeric colspan / rowspan survive; script-like elements are dropped with their content; any other raw tag stays text. | Implemented (T009) |
| FR-MD-012 | A plain body (one line, `**bold**`, a link, a code block) and a body whose markdown is only inside a ```` ```md ```` fence render exactly as before. | Implemented (T009) |
| FR-MD-013 | An issue description is rendered markdown; a click, Enter or `e` opens the editor with the raw text; a click elsewhere saves it; a failed save keeps the editor and says so (`IssueDescription.vue`). | Implemented (T010) |
| FR-MD-014 | Agents are told how to post in ONE place, `doc/help/how-to-post.md`; tool help, seed prompts and action help point to it. | Implemented (T011) |

## 2. Decisions

- **Marker: the `md` fence.** Message bodies already split fences
  (`utils/code-blocks.mjs`), and agents and editors already write the fence,
  so there is no second parser for the start and stop, and an old client
  shows readable text. To SHOW markdown source, tag the fence `text`. To nest
  a ```` ``` ```` block inside, open with four backticks (```` ````md ````).
- **Renderer: markdown-it 14, as tokens, never as an HTML string.**
  `utils/markdown.mjs` runs markdown-it with `html: false`, `linkify: true`
  (bare URLs and emails only, no `fuzzyLink`) and `maxNesting: 20`. It builds
  a tree of plain nodes from an allow-list (`TAGS`, `ATTRS`), and
  `MarkdownBlock.vue` renders that tree with `h()`. The message path keeps
  its guarantee from 013 FR-010 that it has no `v-html`. This is also why no
  HTML sanitizer library is needed: no HTML string is ever built for the
  DOM. `treeToHtml` / `renderMarkdown` are an escaped string form for tests
  only.
- **Bundle.** `MessageBody.vue` takes `isMarkdownLang` from
  `code-blocks.mjs`, never from `markdown.mjs`, so markdown-it stays out of
  the initial graph. Measured with `perf-budget.py bundle` on the generated
  mock bundle (n=1 each): d8a51e18, with markdown-it eager, read
  `ci_initial_gzip_kb` 256.3 (CI job 108377194992). This tree reads 213.6.
  The rest of the overage over the 210 budget predates this spec.
- **The `{{wiki}}` region (d8a51e18, another lane).** A line `{{wiki}}` …
  `{{/wiki}}` renders a hand-rolled subset (headings, lists, quotes, bold,
  italic, links; no tables) through `parseBody` and `MessageRuns.vue`, as
  text interpolation. It is live beside the fence. **Open for the owner:**
  keep one marker. If `{{wiki}}` stays, route its text through the same
  `markdownTree` so both give full markdown and one sanitiser covers both.
- Not in v1: task-list checkboxes, footnotes, embedded images, raw HTML,
  syntax highlighting inside a markdown block's own fences (they render as
  plain `pre`), and a `:::md` form.

## 3. Proof

- Unit: `tests/unit/markdown.test.mjs` (the base render) and
  `tests/unit/markdown-hostile.test.mjs` (37 hostile inputs: script, style,
  iframe, object, svg, `on*=`, `javascript:` in every spelling, `data:`,
  `vbscript:`, `file:`, relative and protocol-relative links, reference
  links, autolinks, images, attribute smuggling, bidi, nesting bombs). The
  suite has two controls, and each turns it red: `v-html` put back into the
  component, and `safeHref` returning its input (18 fails).
- Live: `tests/e2e/markdown-live.proof.mjs`, 19 steps, run against
  d33f8a0d (which carries 5ea0874f): 19/19 on dev (t1) and 19/19 on prd (e2e
  test tenant). Screenshots are in prd #issues, topic 11b128c2.
