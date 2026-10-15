# 137: Qto as the only doc editor, unified spool-hub file system, and md retirement

Status: **Consensus v0.2** (Step 2 panel consensus folded; agy a-965; issue SPL-1743).
Authority: this file for the architecture and technical requirements; `tasks.md` for the phased build tasks.
Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing (`../README.md` §2.4).
Topic: `bed3ed0a-dd34-46b9-a7ea-a8c89c5f596c` (HUM-10, prd t1, msgs 25579adb, ae9d80a4, 0e9d17b5, 2c82489a, b1661d1c).

Builds on, and does not repeat:
- [002 box-agent messaging](../002-box-agent-messaging/spec.md) (local folder spool, CLI + MCP contracts)
- [003 message bus](../003-spool-message-bus/spec.md) (the hub, store, viewer API, RLS)
- [005 WUI](../005-spool-wui/spec.md) (Nuxt 3 web interface, theme variables, layout)
- [022 top-bar & global search](../022-spool-wui-top-bar-search/spec.md) (Omnibox `/search` mode, grouped results)
- [025 workspace RBAC](../025-spool-tenant-rbac/spec.md) (roles, permissions, entry gates)
- [026 workspace from identity](../026-spool-tenant-from-identity/spec.md) (single API host, identity resolution)
- [040 markdown compat](../040-spool-markdown-compat/spec.md) (allow-listed node tree, `markdown.mjs`, `MarkdownBlock.vue`)
- [075 docs section](../075-docs-section/spec.md) (repo markdown explorer, GCS hosting, `/docs` route)
- [113 workspace docs Qto](../113-workspace-docs-qto/spec.md) (outline and grid over one tree: `workspace_doc`, `workspace_doc_item`, `workspace_doc_rev_log`, rdb `0157`)
- [114 workspace doc privacy and sharing](../114-workspace-doc-privacy-sharing/spec.md) (private by default, tenant isolation, share grants)
- [120 Qto doc tree](../120-qto-doc-tree/spec.md) (workspace file explorer, nested set `workspace_doc_node`, 10,000 doc cap)
- [135 work process](../135-work-process/spec.md) (issue workflow, lane integration rules)

`<BASE_DOMAIN>`, `<tenant>`, `<workspace_id>`, `<human_id>`, `<org>`, `<app>`, and `<env>` are placeholders. No estate value appears as a literal to copy.
Per the owner's wording rule, this specification uses the term **workspace** throughout the narrative, requirements, user stories, and acceptance scenarios; the term **tenant** appears strictly when citing existing code identifiers, database columns, shell functions, terraform resources, or API headers.

---

## 0. Owner asks and follow-ups (verbatim, HUM-10, t1 topic bed3ed0a)

The owner established the architectural goals and follow-up requirements in prd workspace `t1`, topic `bed3ed0a-dd34-46b9-a7ea-a8c89c5f596c`, verbatim:

| msg | text |
|---|---|
| `25579adb` | "what should we achieve to use the qto as the primary input for the md documentation generation, if we want to support all md files and renderers features" |
| `ae9d80a4` | "first a proper listing of all of the features which md files support - and what are we missing in the qto interface for those ... than a proper panel of experts on how to fill in those gaps ... the aim is after those gaps are filled in to leave only the qto editor and retire the md files editing .." |
| `0e9d17b5` | "and of course to combine the 2 sections .. so that there will be one spool-hub file system with proper tenant segregation and later on complex permissions ..." |
| `2c82489a` | "the qto docs should support tables in the paragraphs as well .." |
| `b1661d1c` | "the qto docs should support citates" |

What they bind:
- **B1 (msg 25579adb & ae9d80a4)**: Qto becomes the **primary input** for all documentation. Markdown files in the repository become generated export artifacts; manual `.md` file editing is systematically retired.
- **B2 (msg ae9d80a4)**: An exhaustive inventory of every Markdown feature supported by CommonMark, GitHub Flavored Markdown (GFM), and the existing codebase must be catalogued against current Qto editor capabilities, round-trip fidelity, and renderer support.
- **B3 (msg 0e9d17b5)**: The split between the Docs section (spec 075 repo docs) and Qto (specs 113/120/114 workspace docs) is eliminated. Both merge into **ONE unified spool-hub file system** backed by PostgreSQL with strict Row-Level Security (RLS) tenant segregation and an extensible capability model for future complex permissions.
- **B4 (msg 2c82489a)**: Qto paragraphs must support interactive table authoring and editing in the UI, full round-trip export fidelity, and live verification on production.
- **B5 (msg b1661d1c)**: Qto paragraphs must support blockquotes and structured citations (quotes with author/link attribution), rendering in the theme style and exporting cleanly as standard Markdown blockquotes (`> `).
- **B6 (msg ae9d80a4)**: A five-seat expert panel (Claude, Grok, Mistral, Agravity, Qwen) convenes in Step 2 to achieve consensus on gap closure designs before implementation lanes are launched.

---

## 1. Ground truth & measured scale (checked on origin/master)

Every figure in this section was verified against the repository tree at commit `4ac30d59b` on 2026-10-13 using the exact commands shown (updated at `1466560e8` on 2026-10-14: 1,257 total `.md` files; 1,158 under `csi-spl-doc/`, 99 outside).

### 1.1 Repository scale

| Scope | Command | Count |
|---|---|---:|
| All Markdown files in repository | `git ls-files '*.md' \| wc -l` | **1,247** |
| Markdown files under `csi-spl-doc/` | `git ls-files 'csi-spl-doc/*.md' \| wc -l` | **1,148** |
| Markdown files outside `csi-spl-doc/` (root, modules, workflows) | `git ls-files '*.md' ':!:csi-spl-doc/*.md' \| wc -l` | **99** |
| Non-Markdown files under `csi-spl-doc/` (images, scripts, SQL, configs) | `git ls-files 'csi-spl-doc/**' \| grep -v '\.md$' \| wc -l` | **55** |

### 1.2 Feature distribution across the 1,247 repository Markdown files

| Feature | Detection pattern / command | Files | % of repo docs |
|---|---|---:|---:|
| **ATX Headings: h1 (`# `)** | `git grep -lE '^# ' -- '*.md'` | **805** | 64.6% |
| **ATX Headings: h2 (`## `)** | `git grep -lE '^## ' -- '*.md'` | **979** | 78.5% |
| **ATX Headings: h3 (`### `)** | `git grep -lE '^### ' -- '*.md'` | **439** | 35.2% |
| **ATX Headings: h4 (`#### `)** | `git grep -lE '^#### ' -- '*.md'` | **17** | 1.4% |
| **ATX Headings: h5 (`##### `)** | `git grep -lE '^##### ' -- '*.md'` | **0** | 0.0% |
| **ATX Headings: h6 (`###### `)** | `git grep -lE '^###### ' -- '*.md'` | **0** | 0.0% |
| **Setext Headings (`===` / `---`)** | Python multi-line regex `^[a-zA-Z0-9].*\n(?:={3,}\|-{3,})$` | **436** | 35.0% |
| **Unnumbered Headings (`## Title`)** | Headings matching `^#{1,6}\s+[^0-9\s]` | **559** | 44.8% |
| **Outline Numbering Mismatch** | Headings where numbering skips levels or fails `1.1.1` derived form | **110** | 8.8% |
| **Front Matter (YAML header)** | First line equals `---` | **443** | 35.5% |
| **Code Fences (` ``` ` or `~~~`)** | `git grep -lE '^(```\|~~~)' -- '*.md'` | **278** | 22.3% |
| **4-Backtick Fences (` ```` `)** | `git grep -lE '^````' -- '*.md'` | **2** | 0.2% |
| **Mermaid Diagrams (` ```mermaid `)** | `git grep -lE '^```mermaid\b' -- '*.md'` | **6** | 0.5% |
| **Pipe Tables (`\| Header \|`)** | `git grep -lE '^\s*\|.*\|.*\|' -- '*.md'` | **584** | 46.8% |
| **HTML Blocks & Tags (`<tag>`)** | `git grep -lE '<[a-zA-Z][^>]*>' -- '*.md'` | **676** | 54.2% |
| **Blockquotes (`> `)** | `git grep -lE '^\s*>\s+' -- '*.md'` | **123** | 9.9% |
| **Nested Blockquotes (`> > `)** | `git grep -lE '^\s*>\s*>\s+' -- '*.md'` | **18** | 1.4% |
| **Task Lists (`- [ ]`, `- [x]`)** | `git grep -lE '^\s*[-*+]\s+\[[ xX]\]' -- '*.md'` | **104** | 8.3% |
| **Footnotes (`[^1]` / `[^1]: `)** | `git grep -lE '\[\^[^\]]+\]' -- '*.md'` | **17** | 1.4% |
| **Relative Links (`[text](../path.md)`)**| Regex `\]\((?!https?://\|mailto:\|#\|/t/)[a-zA-Z0-9_./-]+\.md[^\)]*\)` | **172** | 13.8% |
| **Fragment / Anchor Links (`[text](#id)`)**| `git grep -lE '\]\(#[a-zA-Z0-9_-]+\)' -- '*.md'` | **5** | 0.4% |
| **HTML Comments (`<!-- ... -->`)** | Regex `<!--[\s\S]*?-->` | **379** | 30.4% |
| **Last-Edit Markers (`<!-- version: ... -->`)**| `git grep -lE '<!--\s*version:.*last-edit:.*-->' -- '*.md'` | **271** | 21.7% |
| **Markdown Images (`![alt](src)`)** | `git grep -lE '!\[[^\]]*\]\([^)]+\)' -- '*.md'` | **5** | 0.4% |

### 1.3 Reality check on existing import/export tooling

Testing the current import script (`csi-spl-orc/src/bash/run/spl-doctree-md.py` via `split`) against all 1,247 Markdown files:
- **Compatible with current Qto import**: **378 files (30.3%)**
- **Refused by current Qto import**: **869 files (69.7%)**

Primary failure modes in `spl-doctree-md.py`:
1. **Unnumbered headings refused (:67-68)**: 559 files fail because `NUM.match` fails. Headings such as `## Overview`, `## Architecture`, `### Goals` cause fatal exit.
2. **Missing top-level `# ` title (:48-49)**: 200 files fail because the document begins with YAML front matter, a setext heading, or an introductory table.
3. **Outline mismatch (:83-98)**: 110 files fail because section numbers skip levels (e.g. going from `## 1.` to `#### 1.1.1` without `### 1.1`), use alphanumeric outline schemes (`A.`, `B.`, `Appendix 1`), or roman numerals.
4. **Headings deeper than `####` refused (:64-65)**: `spl-doctree-md.py` aborts if heading level exceeds 3 (`####`).
5. **Headings pushed down on export (:100-120)**: `compose` prepends `#` to every heading to nest them under `# <title>`, pushing `####` to `#####`, and `######` cannot be pushed down without breaking Markdown syntax.
6. **Code fence toggling is naive regex (:30, :38)**: `FENCE = re.compile(r"^(```|~~~)")` toggles on any 3-character fence, failing to track 4-backtick blocks or nested code fences.
7. **Body whitespace stripped (:55)**: `body = "\n".join(s["body"]).strip()` strips intentional leading and trailing formatting lines.
8. **Restricted path scope (`spl-doctree-export-md.func.sh:69-73`)**: Rejects any file not matching `csi-spl-doc/*.md`, locking out 99 files in the repo root and submodules.
9. **Non-transactional import (`spl-doctree-import-md.func.sh:66-69`)**: Sequentially invokes `do_spl_desk_doctree add` for each section. If section 15 of 30 fails, sections 1..14 remain committed in the database, leaving an orphaned partial document.
10. **Test harness stub gap (`csi-spl-orc/src/bash/tests/doctree-export-md.tst.sh`)**: The test suite runs against a Python stub of `spool`, completely bypassing the compiled Go binary export logic in `cmd/spool/doctree_export.go`.

### 1.4 Reality check on WUI renderer (`csi-spl-wui/src/utils/markdown.mjs`)

Inspection of `markdown.mjs` (lines 35-97, 161-167, 196-211) reveals:
- **No plugins**: Uses bare `MarkdownIt('default')` with `html: false` (or allow-listed `html: true` for whole messages).
- **Images rendered as links (:161-166)**: `![alt](src)` does not produce an `<img>` tag; it renders as an `<a>` link labelled with the alt text.
- **HTML allow-list strictly limited (:203-211)**: Only permits `table`, `thead`, `tbody`, `tr`, `th`, `td` and a handful of inline formatting tags (`strong`, `em`, `code`, `br`, `p`, `ul`, `ol`, `li`). All other tags (`details`, `summary`, `kbd`, `span`, `div`) are stripped.
- **Missing GFM / CommonMark extensions**: No Mermaid rendering plugin, no footnote plugin, no task list plugin, no auto-heading ID generation.

---

## 2. Exhaustive Markdown feature matrix & gap analysis

The table below catalogs every Markdown feature, its prevalence in the repository, its current status in the Qto editor (`WorkspaceDocView.vue`), round-trip fidelity through `spl-doctree-md.py` / `spool doctree export`, renderer status in `markdown.mjs`, and the required engineering remedy.

| # | Feature & Syntax | Repo Files | Qto Editor Status | Round-Trip Export Fidelity | WUI Renderer Status | Gap & Engineering Remedy |
|---|---|---:|---|---|---|---|
| **F01** | **ATX Headings: h1 (`# `)** | 805 | Supported (document title or root node) | Preserved | Supported (`h1` in `TAGS`) | Support documents that lack an explicit h1 by deriving title from filename or front matter. |
| **F02** | **ATX Headings: h2 (`## `)** | 979 | Supported (level-1 section node) | Preserved | Supported (`h2` in `TAGS`) | Support unnumbered h2 headers (see F07). |
| **F03** | **ATX Headings: h3 (`### `)** | 439 | Supported (level-2 section node) | Preserved | Supported (`h3` in `TAGS`) | Support unnumbered h3 headers. |
| **F04** | **ATX Headings: h4 (`#### `)** | 17 | Supported (level-3 section node) | Preserved | Supported (`h4` in `TAGS`) | Ensure export heading shift does not truncate at depth 6. |
| **F05** | **ATX Headings: h5 (`##### `)** | 0 | **Refused** (rejected by `spl-doctree-md.py:65`) | **Broken** (fails import) | Supported (`h5` in `TAGS`) | Allow arbitrary tree depth in Qto item model; map depth >= 5 cleanly to h5/h6. |
| **F06** | **ATX Headings: h6 (`###### `)** | 0 | **Refused** (rejected by `spl-doctree-md.py:65`) | **Broken** (fails import) | Supported (`h6` in `TAGS`) | Map depth >= 6 cleanly; do not prepend extra `#` if level reaches 6. |
| **F07** | **Unnumbered Headings** (`## Overview`) | **559** | **Refused** (`NUM.match` fails, :67) | **Broken** (fails import) | Supported (standard md) | **CRITICAL GAP (P-Q1 Choice A)**: Store `attrs.numbered = false` in `workspace_doc_item.attrs` (zero SQL migrations). Outline derivation (`workspace_docs_read.go`) and exporters (`doctree_export.go`, `-doctree-export.ts`) suppress outline prefix when false and skip unnumbered siblings; parser preserves on export. |
| **F08** | **Setext Headings** (`===` / `---`) | 436 | Partial (treated as body text unless matched) | **Altered** (normalized to ATX on export) | Supported (markdown-it parses setext) | Normalize setext to ATX during import; document normalization rule. |
| **F09** | **Outline Numbering Mismatch** (skips, roman, letters) | 110 | **Refused** (`check_outline` aborts, :83-98) | **Broken** (fails import) | Supported (text) | Decouple stored section title from computed outline; support custom or non-derived outline numbers. |
| **F10** | **YAML Front Matter** (`---` header) | **443** | **Refused** (no `# ` first line, :48) | **Lost** (stripped or refused) | Ignored / text | **(Correction 4)**: Parse YAML front matter into the root item's `attrs.front_matter` JSONB (`workspace_doc_item` where `parent_id IS NULL`, zero SQL migrations); regenerate on export. |
| **F11** | **Pipe Tables (GFM)** (`\| a \| b \|`) | **584** | **No editor tool** (raw text in textarea) | **Preserved** (survives text export) | Supported (pipe tables in `markdown.mjs:196`) | **Owner msg 2c82489a (P-Q3 Choice A)**: Toolbar button (`ws-doc-insert-table`) in `WorkspaceDocView.vue` inserts pipe table skeleton into textarea; renders in `MdRun`; verified round-trip through `workspace_doc_item.body` -> `spool doctree export`. |
| **F12** | **HTML Tables** (`<table><tr><td>`) | 676 | **No editor tool** (raw text in textarea) | **Preserved** (survives text export) | Supported (`htmlTableNodes` in `markdown.mjs:203`) | Support visual table editing or preserve raw HTML blocks untouched. |
| **F13** | **Blockquotes (Simple)** (`> quote`) | 123 | **No editor tool** (raw text in textarea) | **Preserved** (survives text export) | Supported (`blockquote` in `TAGS`) | **Owner msg b1661d1c (P-Q4 Choice A)**: Toolbar button (`ws-doc-insert-quote`) in `WorkspaceDocView.vue` inserts blockquote template with attribution line; render styled quote card in CSS. |
| **F14** | **Nested Blockquotes** (`> > quote`) | 18 | **No editor tool** (raw text in textarea) | **Preserved** (survives text export) | Supported (nested `blockquote`) | Preserved in textarea body; renderer supports nested `blockquote`. |
| **F15** | **Citations & Attributions** (`— Author / Link`) | 123 | **No editor tool / field** | **Altered** (raw text only) | Supported as inline text | **Owner msg b1661d1c (P-Q4 Choice A)**: Attribution line (`> — [Source](url)`) stored in markdown body; styled via CSS (`blockquote p:last-child`) in `MarkdownBlock.vue`. |
| **F16** | **Code Fences: 3-backtick / tilde** | 278 | Partial (rendered in `MdRun`, edited in textarea) | **Preserved** | Supported (`pre`, `code` in `TAGS`) | Preserve language tag and syntax highlighting across edit and export. |
| **F17** | **Code Fences: 4-backtick / nested** | 2 | **Broken** (regex flip toggles inside fence, :38) | **Altered / Corrupted** | Supported (markdown-it handles 4-backtick) | Fix fence parser in import/export to track fence length and matching closing fence. |
| **F18** | **Mermaid Diagrams** (` ```mermaid `) | 6 | **No editor preview** | **Preserved** (raw text) | **Missing** (rendered as raw code block) | Integrate client-side Mermaid renderer in `MarkdownBlock.vue` for diagram visualization. |
| **F19** | **Task Lists (GFM)** (`- [ ]`, `- [x]`) | 104 | **No interactive toggle** (plain text) | **Preserved** | **Missing** (no markdown-it-task-lists) | Add task list plugin to `markdown.mjs`; enable interactive checkbox toggles in WUI. |
| **F20** | **Footnotes** (`[^1]` and `[^1]: text`) | 17 | **No editor support** | **Preserved** | **Missing** (no markdown-it-footnote) | Add footnote plugin to `markdown.mjs`; render bottom footnote anchors. |
| **F21** | **Relative Markdown Links** (`../path.md`) | 172 | **No editor link picker** | **Preserved** | Partial (rewritten by `docs.mjs` in 075) | Update link rewriter to route to unified `/docs/...` paths across both repo and workspace items. |
| **F22** | **Fragment / Anchor Links** (`#section-id`) | 5 | **No editor tool** | **Preserved** | Partial (no slug anchor generation) | Add heading slugifier in WUI renderer so `#heading-name` anchor jumps work. |
| **F23** | **Markdown Images** (`![alt](url)`) | 5 | Partial (Qto uses `<figure>` model with `img_name`) | **Altered** (Qto forces custom figure syntax) | **Altered** (rendered as `<a>` link, not `<img>`) | Unify Qto figure model with standard `![alt](url)` markdown images; support repo-relative image paths. |
| **F24** | **HTML Comments** (`<!-- ... -->`) | 379 | **No editor tool** | **Preserved** in body text | Dropped (hidden in DOM) | Preserve comments during parse and export; do not strip from item bodies. |
| **F25** | **Last-Edit Markers** (`<!-- version: ... -->`) | 271 | **No editor support** | **Preserved** in body text | Dropped (hidden in DOM) | Automatic stamp generator on save/export; maintain compliance with repo rule §2.6. |
| **F26** | **Inline Typography** (bold, italic, code, del) | 1,247 | Textarea editing | **Preserved** | Supported (`strong`, `em`, `code`, `s`) | Maintain CommonMark inline formatting standard. |
| **F27** | **GitHub Alerts / Callouts** (`> [!NOTE]`) | 15 | **No editor tool** | **Preserved** | Partial (rendered as plain blockquote) | Add callout styling (`[!NOTE]`, `[!WARNING]`, `[!TIP]`, `[!IMPORTANT]`, `[!CAUTION]`) in CSS. |

---

## 3. Owner follow-ups: tables and citations in Qto editor

### 3.1 Tables in paragraphs (Owner msg 2c82489a)

Owner HUM-10 stated: *"the qto docs should support tables in the paragraphs as well .."*

#### 3.1.1 Analysis of current implementation
1. **Renderer**: In `csi-spl-wui/src/utils/markdown.mjs`, the renderer already includes `table`, `thead`, `tbody`, `tfoot`, `caption`, `tr`, `th`, `td` in `TAGS` (line 45), supports pipe table parsing via markdown-it default rules, and includes `htmlTableNodes` (lines 196-211) for allow-listed HTML tables.
2. **Qto Paragraph Viewer**: In `WorkspaceDocView.vue` (lines 125, 362-371), paragraph runs render through `<MdRun :text="r.text" />`, which delegates to `MarkdownBlock`. Therefore, if a paragraph body contains a valid Markdown pipe table, it renders as a styled HTML table in the document read view.
3. **The Missing Capabilities**:
   - **No editor toolbar button**: The paragraph toolbar (lines 162-174) contains only one button: `Insert picture` (`pickPic`). There is no button to insert or configure a table.
   - **No visual table helper**: A user must manually type markdown pipes (`|---|---|`), which is error-prone on keyboards and mobile.
   - **No export verification**: Neither `doctree-export-md.tst.sh` nor `workspace-doctree.test.mjs` verifies that a paragraph containing a table survives an edit, database save, and `spool doctree export` cycle.
   - **No live proof**: Never tested or proven live on production workspace `t1`.

#### 3.1.2 Specification for Qto table support
- **Paragraph Toolbar Button**: Next to `Insert picture`, add:
  ```html
  <button
    type="button"
    class="wsdoc__tool wsdoc__tool--label"
    data-test="ws-doc-insert-table"
    :disabled="busy"
    @click="insertTable(it)"
  >
    <UiIcon name="table" :size="16" /><span>{{ t('ws_doctree.insert_table') }}</span>
  </button>
  ```
- **Insert Behavior**:
  - Clicking `insert_table` opens a lightweight popover or inserts a standard 3-column, 2-row pipe table skeleton at the current cursor position:
    ```markdown
    | Header 1 | Header 2 | Header 3 |
    |---|---|---|
    | Cell 1 | Cell 2 | Cell 3 |
    ```
- **Export Invariant**: Tables must round-trip through `workspace_doc_item.body` -> `spool doctree export` -> `spl-doctree-md.py compose` without column corruption, escaped pipe loss, or newline stripping.
- **Verification**: A dedicated unit test and an end-to-end proof in prd workspace `t1`.

---

### 3.2 Citations and blockquotes (Owner msg b1661d1c)

Owner HUM-10 stated: *"the qto docs should support citates"*

#### 3.2.1 Architectural interpretation
In editorial systems and technical documentation, a citation comprises two elements:
1. **The Quotation**: The quoted passage or excerpt, typically rendered as a blockquote (`> ` in Markdown).
2. **The Attribution / Source Line**: The speaker, author, publication, date, or hyperlinked source (e.g. `— Owner HUM-10, topic bed3ed0a` or `— RFC 9110 §4.2`).

#### 3.2.2 Analysis of current implementation
1. **Renderer**: `blockquote` is present in `TAGS` in `markdown.mjs:43`. Markdown-it parses `> quote` lines into `<blockquote>` elements.
2. **Qto Paragraph Viewer**: When rendered, `blockquote` gets standard browser styling, but lacks dedicated blockquote visual treatment (accent left border, muted italic typography, distinct citation footer).
3. **The Missing Capabilities**:
   - **No quote tool in editor**: No toolbar action to format selected text or insert a quote block.
   - **No citation data model**: No structured way to capture the quote author or URL source.
   - **No export convention**: No standard convention for exporting citations so that the source line stays bound to the blockquote.

#### 3.2.3 Specification for Qto citation support
- **Paragraph Toolbar Button**: In `WorkspaceDocView.vue`, add:
  ```html
  <button
    type="button"
    class="wsdoc__tool wsdoc__tool--label"
    data-test="ws-doc-insert-quote"
    :disabled="busy"
    @click="insertQuote(it)"
  >
    <UiIcon name="quote-right" :size="16" /><span>{{ t('ws_doctree.insert_quote') }}</span>
  </button>
  ```
- **Insert & Edit Behavior**:
  - Inserts a blockquote template with attribution line:
    ```markdown
    > Quoted passage here.
    > 
    > — [Author or Document Title](https://...)
    ```
- **Visual Styling (`WorkspaceDocView.vue` & `MarkdownBlock.vue`)**:
  - `blockquote`: Left border `3px solid var(--spl-border-focus, #3b82f6)`, background `var(--spl-bg-subtle, rgba(0,0,0,0.02))`, padding `8px 16px`, font-style `italic`.
  - Citation line (`> — ...` or `<cite>`): Rendered in font-style `normal`, text-size `0.875rem`, color `var(--spl-text-muted)`, aligned right or indented.
- **Export Invariant**: Export output must preserve the `>` prefix and the attribution line across the Go export pipeline.

---

## 4. The merge: one spool-hub file system

Owner HUM-10 stated (msg 0e9d17b5):
> *"and of course to combine the 2 sections .. so that there will be one spool-hub file system with proper tenant segregation and later on complex permissions ..."*

### 4.1 Unifying the Docs section (spec 075) and Qto (specs 113/120/114)

#### 4.1.1 The current split
Today the system exposes two completely disjoint document systems:
1. **Spec 075 (The Docs Section)**:
   - Route: `/docs` in WUI (`ChannelSidebar.vue` entry "Docs").
   - Backed by: A single Google Cloud Storage bucket (`csi-spl-<env>-docs`) per environment, uploaded during deployment.
   - Hierarchy: Read from a deployed `tree.json` index.
   - Mutability: Strictly read-only in the application; edited solely by modifying `.md` files in git.
2. **Specs 113 / 120 / 114 (Workspace Docs / Qto)**:
   - Route: `/w/:workspace/docs` or document viewer modals.
   - Backed by: PostgreSQL database tables (`workspace_doc`, `workspace_doc_item`, `workspace_doc_node`, `workspace_doc_rev_log`, rdb `0157`, `0165`).
   - Hierarchy: A nested set tree (`lft`, `rgt` in `workspace_doc_node`).
   - Mutability: Interactive read-write outline and grid editor for members and automated agents.

This separation confuses users (two different "Docs" concepts), duplicates navigation trees, and keeps codebase documentation tied to git commits rather than the live hub database.

#### 4.1.2 The unified file system architecture
In the merged architecture, **PostgreSQL is the single source of truth for ALL documents**, fulfilling the owner's decision in Spec 113 §0 (msg 4e385cf9: *"the answer is a - because later on we could generate the files to b level"*).

The Qto nested set tree (`workspace_doc_node`) becomes the file system for the entire application, holding both repository documentation and workspace documentation under a unified logical namespace:

```
/ (Spool-Hub File System Root)
├── repo/                                  # Repository documentation (former Spec 075)
│   ├── README.md                          # Root project documentation
│   ├── DEPLOY.md
│   ├── csi-spl-doc/
│   │   ├── doc/
│   │   │   ├── md/                        # Runbooks, guides, operational docs
│   │   │   └── help/                      # User-facing help docs
│   │   └── specs/                         # Architectural git-specs
│   │       ├── 075-docs-section/
│   │       ├── 113-workspace-docs-qto/
│   │       ├── 120-qto-doc-tree/
│   │       └── 137-qto-only-doc-editor/
│   └── modules/                           # Module READMEs (api, wui, iac, orc, cnf)
│       ├── csi-spl-api/
│       └── csi-spl-wui/
└── workspace/                             # Workspace documentation (Specs 113/120)
    ├── architecture/                      # Team-created folders and documents
    │   └── system-overview
    ├── runbooks/
    │   └── on-call-rotation
    └── projects/
        └── q4-deliverables
```

### 4.2 Tenant segregation via Row-Level Security (RLS)

The owner requires *"proper tenant segregation"* (msg 0e9d17b5). The multi-tenant architecture must guarantee that:
1. Workspace documents belonging to workspace `X` are **completely invisible and inaccessible** to workspace `Y`.
2. Repository documentation (`/repo/...`) is globally accessible (read-only) to all valid workspaces without duplicating rows.
3. Access controls are enforced by the database engine itself via PostgreSQL Row-Level Security, not solely in application code.

#### 4.2.1 Data model & composite foreign keys
Every document entity carries `tenant_id`:
- `workspace_doc_node` (id, tenant_id, lft, rgt, parent_id, kind, name, title, description, ...)
- `workspace_doc` (id, tenant_id, title, rev, ...)
- `workspace_doc_item` (id, tenant_id, doc_id, parent_id, ord, title, body, attrs, ...)
- `workspace_doc_rev_log` (tenant_id, doc_id, rev, op, actor, created_at)

To prevent foreign key checks from bypassing RLS (as discovered and proven in Spec 113 §2.2 and Spec 114 §2.1), composite foreign keys include `tenant_id`:
```sql
CONSTRAINT fk_workspace_doc_item_doc
    FOREIGN KEY (tenant_id, doc_id)
    REFERENCES workspace_doc (tenant_id, id)
    ON DELETE CASCADE;

CONSTRAINT fk_workspace_doc_item_parent
    FOREIGN KEY (tenant_id, doc_id, parent_id)
    REFERENCES workspace_doc_item (tenant_id, doc_id, id)
    ON DELETE RESTRICT;
```

#### 4.2.2 RLS Policy definition for the unified file system
We establish a dedicated reserved system tenant: `system` (or `_repo`). Repository documentation nodes belong to `tenant_id = 'system'`. Workspace documentation nodes belong to their respective workspace `tenant_id` (e.g. `'t1'`, `'engineering'`).

As verified during panel review (Correction 1), Row-Level Security, `FORCE ROW LEVEL SECURITY`, and composite tenant foreign keys are already live on `workspace_doc_node`, `workspace_doc`, `workspace_doc_item`, and `workspace_doc_rev_log` (rdb `0157`, `0165`). The runtime session GUCs are `app.tenant_id` and `app.rls_scope = 'operator'` (not the draft `spool.*` GUCs).

To provide universal read access to repository docs while maintaining strict tenant isolation, a single permissive `FOR SELECT` policy is added per table for `tenant_id = 'system'`:

```sql
-- Permissive SELECT policy: all workspaces can read system repo docs
CREATE POLICY doc_node_select_repo ON workspace_doc_node
    FOR SELECT
    USING (tenant_id = 'system');

CREATE POLICY doc_select_repo ON workspace_doc
    FOR SELECT
    USING (tenant_id = 'system');

CREATE POLICY doc_item_select_repo ON workspace_doc_item
    FOR SELECT
    USING (tenant_id = 'system');

CREATE POLICY doc_rev_log_select_repo ON workspace_doc_rev_log
    FOR SELECT
    USING (tenant_id = 'system');
```

Writes remain strictly governed by the existing policies:
- A standard workspace session (`app.tenant_id = '<id>'`, `app.rls_scope` unset) can only modify rows where `tenant_id` matches its session tenant. Since `tenant_id = 'system'` is distinct, standard sessions cannot modify repo docs (Invariant I2).
- An operator session (`app.rls_scope = 'operator'`) can insert, update, or delete across all tenants, enabling authorized CI and administration pipelines to maintain repository documentation.

#### 4.2.3 Isolation invariants
- **Invariant I1 (Cross-tenant blindness)**: A session authenticated to workspace `t2` querying `workspace_doc_node` receives 0 rows matching `tenant_id = 't1'`.
- **Invariant I2 (System immutability)**: A standard workspace session cannot update, insert, or delete nodes under `tenant_id = 'system'`. Only an operator session (`spool.operator_scope = 'true'`) or a CI synchronization pipeline can modify system repository documentation.
- **Invariant I3 (Integrity under RLS)**: All tree operations (moves, inserts, renumbering) execute strictly within the bounds of the session's active `tenant_id`.

---

### 4.3 Permission model: simple today, extensible for complex permissions later

The owner mandated: *"... and later on complex permissions ..."* (msg 0e9d17b5). The architecture must not require a disruptive database rewrite when granular permissions (folder ACLs, secret specs, agent-only edit locks) are introduced.

#### 4.3.1 Layered permission architecture

```
+------------------------------------------------------------------------------------+
|                               PERMISSION RESOLUTION ENGINE                         |
+------------------------------------------------------------------------------------+
                                          │
        ┌─────────────────────────────────┴─────────────────────────────────┐
        ▼                                                                   ▼
+────────────────────────────────---------------+   +────────────────────────────────---------------+
|           LAYER 1: TENANT BASELINE            |   |         LAYER 2: CAPABILITY ACLS              |
|             (Active Immediately)              |   |          (Extensible Future)                  |
+────────────────────────────────---------------+   +────────────────────────────────---------------+
| - Workspace membership (RBAC)                 |   | - Explicit node capability grants             |
| - Roles: product_owner, admin, developer, ... |   | - Subject: user, agent, role, or public       |
| - Read: all workspace members & agents        |   | - Action: read, edit, manage, share           |
| - Write: developer, admin, owner, agent       |   | - Inherited down nested set subtree           |
| - Fallback when no Layer 2 ACL exists         |   | - Evaluated before Layer 1 fallback           |
+────────────────────────────────---------------+   +────────────────────────────────---------------+
```

#### 4.3.2 Layer 1: Workspace RBAC (Active Baseline)
- Based on Spec 025 (`tenant_rbac`):
  - Roles: `product_owner`, `biz_owner`, `admin`, `developer`, `tester`, `agent`.
  - Permissions:
    - `docs.read`: Allowed for all authenticated workspace roles.
    - `docs.write`: Allowed for `product_owner`, `biz_owner`, `admin`, `developer`, and `agent` (testers have read-only access).
    - `docs.admin`: Allowed for `admin` and `product_owner` (can permanently purge nodes).

#### 4.3.3 Layer 2: Extensible Capability ACLs (Future-Ready Schema)
To accommodate future complex permissions without altering table structures, `workspace_doc_node` includes an extensible JSONB column `acl` (or references table `workspace_doc_acl`):

```sql
CREATE TABLE workspace_doc_acl (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   text NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    node_id     uuid NOT NULL REFERENCES workspace_doc_node (id) ON DELETE CASCADE,
    subject     text NOT NULL, -- 'user:<id>', 'agent:<id>', 'role:<name>', 'workspace:*'
    action      text NOT NULL CHECK (action IN ('read', 'edit', 'manage', 'share')),
    effect      text NOT NULL DEFAULT 'allow' CHECK (effect IN ('allow', 'deny')),
    created_at  timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_doc_acl_node ON workspace_doc_acl (tenant_id, node_id);
```

**Permission Evaluation Rule**:
1. If an explicit `deny` matches the caller's identity or role on the node or any ancestor folder (`ancestor.lft <= node.lft AND ancestor.rgt >= node.rgt`), access is **denied**.
2. If an explicit `allow` matches, access is **granted**.
3. If no ACL entries exist for the node or its ancestors, access **falls back to Layer 1 (Workspace RBAC)**.

This guarantees that today's simple system functions seamlessly, while fine-grained corporate permissions, confidential document grants, and agent-restricted specs can be activated on demand simply by inserting ACL rows.

---

## 5. Retirement plan for Markdown files editing

Owner HUM-10 mandated (msg ae9d80a4):
> *"the aim is after those gaps are filled in to leave only the qto editor and retire the md files editing .."*

### 5.1 The target state
- **The Database is the Source of Truth**: The PostgreSQL Qto file system (`workspace_doc_node`, `workspace_doc`, `workspace_doc_item`) is the primary authoring and storage location for all documentation.
- **The Qto UI and Spool CLI/MCP are the Only Authoring Tools**:
  - Humans author and edit documents via the WUI Qto editor (`WorkspaceDocView.vue`).
  - Automated AI agents author and edit documents via `spool doc-*` CLI verbs and MCP tools (`spool_doc_read`, `spool_doc_write`, `spool_doc_item_add`).
- **Markdown Files are Strictly Derived Exports**:
  - Markdown files in the git repository (`csi-spl-doc/**`, `README.md`, `DEPLOY.md`) exist solely for offline reading, git diff tracking, and external repository consumers.
  - Every exported `.md` file carries an immutable export stamp on line 2:
    `> Generated from qto doc <doc-id>; edit it there. This file is its export: do_spl_doctree_export_md rewrites it.`
  - Direct editing of `.md` files in a git worktree is blocked by pre-push hooks and CI gates.

### 5.2 Five-Phase Migration Roadmap

```
Phase 1: Gap Closure ──► Phase 2: Bulk Import ──► Phase 3: Export Parity ──► Phase 4: Gate Enforcement ──► Phase 5: Retirement
(Qto editor & parser)   (All 1,247 md files)     (Byte-stable round-trip)   (Pre-push rejects edits)   (Qto sole editor)
```

#### Phase 1: Gap Closure & Parser Upgrade
- Implement interactive table tool in Qto paragraph toolbar (Owner msg 2c82489a).
- Implement blockquote & citation tool in Qto paragraph toolbar (Owner msg b1661d1c).
- Upgrade `spl-doctree-md.py`:
  - Support unnumbered headings (F07, 559 files).
  - Support documents without leading `# ` (F01, F10, 200 files).
  - Support arbitrary outline schemes and depth levels >= 5 (F04-F06, F09).
  - Track multi-character and 4-backtick code fences (F17).
  - Preserve YAML front matter into JSONB metadata (F10).
- Make `spl-doctree-import-md.func.sh` fully transactional (run inside a single transaction or rollback on failure).
- Remove the `csi-spl-doc/*.md` path restriction in `spl-doctree-export-md.func.sh` so all repository `.md` files can be exported.

#### Phase 2: Bulk Import of Repository Documentation
- Execute automated import of all 1,247 Markdown files into the `system` tenant of the database.
- Populate `csi-spl-doc/doc/md/qto-docs.tsv` mapping every repository `.md` path to its unique `doc_id`.
- Verify tree hierarchy integrity using `do_spl_doc_tree_check`.

#### Phase 3: Byte-Stable Export Parity
- Run `do_spl_doctree_export_md` across all 1,247 mapped documents.
- Verify that `git diff` produces zero unintended textual or whitespace drift (apart from the standardized "Generated from qto doc" header).
- Run repo test gates to ensure all module tests remain green.

#### Phase 4: Git Pre-Push Gate Enforcement & Legacy Deprecation
- **Deprecate Spec 075 Repo-Edit Path (Correction 2)**: Before activating the gate, retire or disable `PUT /v1/docs/{path}` and the `repodocs.Worker` background git committer for all paths registered in `qto-docs.tsv`, eliminating background commit collisions.
- **Pre-Push Gate (P-Q5 Choice A)**: Update the pre-push gate (`csi-spl-iac/src/bash/run/spl-check-pre-push.func.sh` / `10_ci-quality.yml`):
  - A commit touching a mapped `.md` file must be generated by `do_spl_doctree_export_md` (verified by comparing against export hash or checking export stamp).
  - Direct, manual edits to mapped `.md` files that are not synchronized with the database are rejected by the pre-push hook:
    `FATAL: direct edit to <file>.md detected. This document is managed by Qto. Edit it via Qto and run do_spl_doctree_export_md.`
  - Unmapped documents remain editable until their respective bulk import phase completes.

#### Phase 5: Complete Retirement of Manual Markdown Editing
- Remove manual markdown authoring instructions from developer guides.
- Agent seeds and prompts updated: agents are instructed to use `spool doc-*` for documentation updates rather than modifying `.md` files directly.
- Full retirement achieved: Qto is the sole doc editor across the fleet.

### 5.3 Publishing the export: the Publish button (addendum)

Owner HUM-10 (t1 `2a2a4694`, msg `b04f0ab5`): *"the aim is to slowly make the master storage format of our docs to be qto and the '*.md' files to be published to the github repo , once desired via a pubblish button"*. The `.md` export reaches `master` when a person presses **Publish** in the Qto doc view: the hub exports the doc, gates the bytes and commits them fast-forward under its GitHub App, the presser as author. Owner decisions (poll `72d2b3da`, msg `86c7b888`): any `docs.write` member presses; any workspace doc may be published to a picked path at once, no review (msg `af133e9c`), behind the automatic public-repo guard; a changed repo file is 3-way merged and the result written back into Qto; prd only; no rev in the stamp; Publish and the lane export both write, under one same-rev rule. Design: [publish.md](publish.md); tasks T060..T067 in [tasks.md](tasks.md) §7.

### 5.4 Specs, agent instructions, and our READMEs move to Qto (addendum)

Owner HUM-10 (topic `acc0c5d3-ec8f-4968-9ed9-f25e99d16e0e`, msgs `b0c3bc86`, `4454c883`, `ce0eae22`): specs (`csi-spl-doc/specs/`, 503 .md in 138 specs), agent instructions (~29 files under `csi-spl-orc/src/bash/features/`), and our 21 `README.md` files move to Qto as the master format and editing place, following the same export and publishing rules as `csi-spl-doc/doc`. Detailed design, authoring/ticking lifecycle, import plans, gap handling (G1-G7), public-repo hygiene gate, and required test gates are specified in [§10. Addendum](#10-addendum-specs-agent-instructions-and-our-readmes-move-to-qto-hum-10); phased build tasks T070..T076 are in [tasks.md](tasks.md) §8.

---

## 6. Step 2 expert panel preparation

Owner HUM-10 mandated (msg ae9d80a4):
> *"... than a proper panel of experts on how to fill in those gaps ... the aim is after those gaps are filled in to leave only the qto editor and retire the md files editing .."*

Following the fleet rule (consensus then build, no go), Step 2 convenes a structured panel of experts representing each vendor model.

### 6.1 Panel composition
The panel consists of five designated review seats:
1. `s137-claude`: Claude 3.5 Sonnet / Opus seat.
2. `s137-grok`: Grok 2 / 3 seat.
3. `s137-mistral`: Mistral Large / Codestral seat.
4. `s137-agy`: Antigravity (Google DeepMind) seat.
5. `s137-qwen`: Qwen 2.5 Coder seat.

### 6.2 Key questions for the expert panel

The panel will evaluate and rank solutions for the following core technical decisions:

1. **Question P-Q1 (Heading Representation & Unnumbered Headings)**:
   - *Problem*: 559 repo files use unnumbered headings (`## Overview`), but Qto's data model computes outline numbers (`1.1`) from sibling `ord`.
   - *Option A*: Store an explicit `is_numbered` boolean flag on `workspace_doc_item`. If false, outline is empty and title renders bare.
   - *Option B*: Store custom outline strings (`outline_override text NULL`) on `workspace_doc_item`.
   - *Option C*: Normalize all headings to numbered outlines during import.

2. **Question P-Q2 (Repository Docs in the Unified File System)**:
   - *Problem*: How should repo docs sit alongside workspace docs in PostgreSQL?
   - *Option A (Global System Tenant)*: Store repo docs in `tenant_id = 'system'`. RLS policy grants `SELECT` to all tenants, `MODIFY` to operators only. Zero data duplication.
   - *Option B (Per-Tenant Replication)*: Replicate repo doc nodes into every tenant's tree under `/repo`. Independent copies, high storage overhead.
   - *Option C (Virtual Mount)*: Keep repo docs in GCS (Spec 075), but unify the WUI Explorer tree UI to present them in one view.

3. **Question P-Q3 (Table Editor Interface in Qto)**:
   - *Problem*: How should users edit tables in paragraphs (Owner msg 2c82489a)?
   - *Option A (Markdown Pipe Skeleton)*: Toolbar button inserts pipe table markdown into the textarea; user edits plain text with live preview in read mode.
   - *Option B (Grid Modal)*: Toolbar button opens an interactive spreadsheet grid modal (matching Qto's grid view heritage) to edit cells, which compiles to a pipe table on blur.
   - *Option C (Dedicated Table Item Node)*: Create a distinct node kind `kind = 'table'` in `workspace_doc_item` with JSONB cells.

4. **Question P-Q4 (Blockquote & Citation Data Model)**:
   - *Problem*: How should blockquotes and citations be stored (Owner msg b1661d1c)?
   - *Option A (Standard Markdown Body)*: Store as `> quote\n> — Source` in `body`. Renderer styles it based on regex/tag detection.
   - *Option B (Structured Item Attributes)*: Store quote text and citation metadata in `workspace_doc_item.attrs = { quote: text, author: name, url: link }`. Export compiles to markdown blockquote.

5. **Question P-Q5 (Retirement Gate & Drift Prevention)**:
   - *Problem*: How strictly should CI enforce the retirement of `.md` editing?
   - *Option A (Hard Pre-Push Gate)*: Pre-push hook rejects any branch touching `.md` unless matching database export hash.
   - *Option B (CI Auto-Commit)*: CI runs `do_spl_doctree_export_md` and auto-commits any drift back to master.
   - *Option C (Advisory Warning)*: CI warns if `.md` was edited by hand without database update.

### 6.3 Expert panel outcome & consensus (SPL-1743)

On 2026-10-14, the expert panel convened across 4 placed review seats:
- `s137-claude` ([`panel/claude.md`](panel/claude.md), `6216915b8`): Decisions A A A A A, plus 5 tasks.md corrections.
- `s137-grok` ([`panel/grok.md`](panel/grok.md), `d999a070f`): Decisions A A A A A, plus 5 tasks.md corrections.
- `s137-mistral` ([`panel/mistral.md`](panel/mistral.md), `e33014485`): Decisions A A B A A (substantive agreement on A for P-Q3).
- `s137-agy` ([`panel/agy.md`](panel/agy.md), `06373720f`): Decisions A A A A A, plus 5 tasks.md corrections.
- `s137-qwen`: Not placed (no qwen CLI available on sat; primary box over its load gate). The panel proceeded with 4 seats.

The complete consensus rationale, weighing of Mistral's P-Q3 vote, and 5 verified corrections are documented in [`panel/consensus.md`](panel/consensus.md).

**Summary of Adopted Decisions**:
1. **P-Q1**: Choice **A** — `attrs.numbered = false` stored in existing JSONB `attrs` (no migration); outline derivation and exporters omit outline prefix when false.
2. **P-Q2**: Choice **A** — Single reserved `system` tenant with permissive `FOR SELECT` RLS policies and operator-only writes.
3. **P-Q3**: Choice **A** — Paragraph toolbar button (`ws-doc-insert-table`) inserting Markdown pipe-table template into textarea; interactive grid modal can follow as client-side enhancement.
4. **P-Q4**: Choice **A** — Standard Markdown blockquotes (`> passage`) and trailing attribution lines (`> — [Source](url)`) in body; styled via CSS in `MarkdownBlock.vue`.
5. **P-Q5**: Choice **A** — Hard pre-push and CI quality gate scoped strictly to files registered in `qto-docs.tsv`, phasing in as import progresses.

---

## 7. Functional requirements & acceptance matrix

### 7.1 Functional requirements

| ID | Description | Milestone / Phase | Status |
|---|---|---|---|
| **FR-001** | **Exhaustive Markdown Inventory**: Full matrix of CommonMark, GFM, and repo markdown features catalogued with exact checked repo counts. | Step 1 | **Implemented** (this spec) |
| **FR-002** | **Unnumbered Heading Support**: Qto parser and data model support unnumbered headings (`## Overview`) without failing import or corrupting outline hierarchy. | Step 2 / Phase 1 | Planned |
| **FR-003** | **Deep Heading Support**: Qto parser and data model support headings deeper than `####` (h5, h6, and arbitrary tree depths). | Step 2 / Phase 1 | Planned |
| **FR-004** | **Interactive Table Tool**: Qto paragraph toolbar includes table insertion tool; tables render properly in read mode and survive export round trip. | Step 2 / Phase 1 | Planned (Owner msg 2c82489a) |
| **FR-005** | **Citation & Blockquote Tool**: Qto paragraph toolbar includes quote/citation tool; renders styled quotation card with author/link attribution; exports cleanly as `> `. | Step 2 / Phase 1 | Planned (Owner msg b1661d1c) |
| **FR-006** | **Front Matter Preservation**: YAML front matter is parsed into JSONB metadata on import and accurately regenerated on export. | Step 2 / Phase 1 | Planned |
| **FR-007** | **Robust Fence Parser**: Code fence parser correctly tracks 4-backtick blocks and nested code fences without premature toggling. | Step 2 / Phase 1 | Planned |
| **FR-008** | **Transactional Import**: `do_spl_doctree_import_md` executes atomically; failure of any section rolls back completely without leaving partial docs. | Step 2 / Phase 1 | Planned |
| **FR-009** | **Full Repository Path Scope**: `do_spl_doctree_export_md` admits any `.md` file in the repository (not restricted to `csi-spl-doc/*.md`). | Step 2 / Phase 1 | Planned |
| **FR-010** | **Unified Spool-Hub File System**: Merge Spec 075 repo docs and Spec 113/120 workspace docs into a single PostgreSQL nested set hierarchy. | Step 2 / Phase 2 | Planned (Owner msg 0e9d17b5) |
| **FR-011** | **RLS Tenant Segregation**: Multi-tenant isolation enforced via PostgreSQL RLS with composite FKs; private workspace docs strictly isolated. | Step 2 / Phase 2 | Planned (Owner msg 0e9d17b5) |
| **FR-012** | **Extensible Capability Permissions**: Extensible ACL schema (`workspace_doc_acl`) established, defaulting to workspace RBAC while supporting future granular rules. | Step 2 / Phase 2 | Planned (Owner msg 0e9d17b5) |
| **FR-013** | **Bulk Repository Import**: All 1,247 repository `.md` files imported into the database file system and mapped in `qto-docs.tsv`. | Step 2 / Phase 3 | Planned |
| **FR-014** | **Byte-Stable Export**: `do_spl_doctree_export_md` regenerates all mapped `.md` files with byte stability and zero unintended diffs. | Step 2 / Phase 3 | Planned |
| **FR-015** | **Markdown Edit Retirement Gate**: Pre-push hook and CI quality gate reject manual `.md` file modifications in favor of Qto exports. | Step 2 / Phase 4 | Planned (Owner msg ae9d80a4) |

### 7.2 Acceptance criteria

| # | Scenario | Verification Method | Pass Criteria |
|---|---|---|---|
| **AC-01** | Feature Inventory Accuracy | Run check commands from §1 on origin/master | All counts match or exceed verified numbers (1,247 md files, 584 tables, etc.). |
| **AC-02** | Paragraph Table Insertion | Click "Insert Table" in `WorkspaceDocView.vue` in prd `t1` | Table skeleton is inserted; renders in `MdRun`; survives export via `spool doctree export`. |
| **AC-03** | Paragraph Citation Insertion | Click "Insert Quote" in `WorkspaceDocView.vue` in prd `t1` | Quote block and attribution line inserted; renders in styled blockquote; exports as `> `. |
| **AC-04** | Unnumbered Heading Import | Run `do_spl_doctree_import_md` on document with `## Overview` | Import succeeds; document tree created; export reproduces unnumbered heading. |
| **AC-05** | Deep Heading Import | Run `do_spl_doctree_import_md` on document with `##### Subheading` | Import succeeds; node created at depth 5; export preserves heading level. |
| **AC-06** | Tenant Isolation Verification | Query `workspace_doc_node` under tenant `t2` | 0 rows returned for tenant `t1` workspace docs; `system` repo docs visible read-only. |
| **AC-07** | RLS Write Protection | Attempt to `INSERT` into `workspace_doc_node` with `tenant_id = 'system'` as workspace session | PostgreSQL RLS violation (HTTP 403 / SQL error); modification rejected. |
| **AC-08** | Transactional Rollback | Plant intentional error in section 5 during import | Script exits with error; 0 orphaned items exist in database for the doc. |
| **AC-09** | Bulk Export Parity | Run `do_spl_doctree_export_md` on all imported repo docs | `git diff` shows only the added "Generated from qto doc" headers; 0 content corruption. |
| **AC-10** | Pre-Push Retirement Rejection | Manually edit a mapped `.md` file and attempt `git push` | Pre-push hook refuses push with diagnostic message directing author to Qto. |

---

## 8. Not in scope

- WYSIWYG rich text binary formats (DOCX, ODT): Markdown and Qto outline structures remain the standard interchange format.
- Real-time collaborative typing / Operational Transformation (OT) / CRDT: Document saves remain atomic and rev-locked per Spec 113.
- Arbitrary binary file storage in database tables: Binary assets and images continue to use the files bucket (`050-gcs-files`) via `/v1/files/`.

---

## 10. Addendum: Specs, agent instructions, and our READMEs move to Qto (HUM-10)

Owner order: HUM-10, t1 #refactoring topic `acc0c5d3-ec8f-4968-9ed9-f25e99d16e0e`, poll `c0398592`, answer msg `b0c3bc86` (17:1xZ 2026-10-15): of our docs not in Qto, move **1. specs** (`csi-spl-doc/specs/`, 503 .md in 138 specs) and **6. agent instructions** (~30 files: `csi-spl-orc/src/bash/features/spawn-agents/assets/{commands,skills}/**`, `spool-install/assets/claude/claude-md/*.md`, `spool-install/assets/agy/rules/*.md`, `graft/assets/**`, `gc/gc-prompt.md`, `dispatch/brief-dispatcher.tpl.md`). Then (msg `4454c883`, same topic): **4. our own README.md files** too (21: the root README.md and each part's README.md, e.g. `csi-spl-api/`, `csi-spl-orc/`, `csi-spl-wui/`, `csi-spl-orc/src/bash/features/*/README.md`). NOT third-party ones (`csi-spl-doc/.specify/extensions/git/README.md`) and NOT test fixtures (`csi-spl-orc/src/bash/tests/fixtures/**`).
Rule (spec 137, owner msg `b04f0ab5`): Qto becomes the master format and the editing place; the repo `.md` is the export (`Publish` / the lane export), as for `csi-spl-doc/doc` (T030B, c-129).

### 10.1 Specs: authoring, ticking, and the no-direct-md-edit guard

#### 10.1.1 Reality check: spec lifecycle today
- **Spec-Kit authoring**: Initial specs and plans are structured under `csi-spl-doc/.specify/` (`scripts/bash/common.sh:5`, `memory/constitution.md:20`), creating feature specifications under `csi-spl-doc/specs/<NNN>-<slug>/` with `spec.md` and `plan.md`.
- **Task generation (`/spec-kit-tasks`)**: The agent skill (`csi-spl-orc/src/bash/features/spawn-agents/assets/skills/spec-kit-tasks/SKILL.md:47`) parses `FEATURE_DIR/spec.md` and `plan.md` to produce `FEATURE_DIR/tasks.md`.
- **Panel seats**: Structured multi-vendor panels (`csi-spl-doc/specs/README.md:39`, `csi-spl-doc/specs/137-qto-only-doc-editor/spec.md:528-536`) convene review seats (claude, grok, mistral, agy, qwen) that write individual reviews in `panel/<seat>.md` and finalize `panel/consensus.md`.
- **Ticking tasks with a sha**: Implementation lanes update task statuses in `tasks.md` from `Planned` to `Implemented` citing commit SHAs and test proofs (`csi-spl-doc/specs/README.md:32-38`, `csi-spl-doc/specs/137-qto-only-doc-editor/tasks.md:23,34,35`).
- **Direct markdown editing**: All four operations currently execute by directly reading and writing `.md` files in local git worktrees.

#### 10.1.2 Target state: Qto as master for specs
1. **Primary authoring in Qto**:
   - The Qto document under `/repo/specs/<NNN>-<slug>/` in the `system` tenant (`fs=repo`) is the master document. Direct manual editing of `.md` files in git is retired.
   - Lanes and humans authoring or updating specs write directly into Qto using the WUI editor (`WorkspaceDocView.vue`), CLI (`spool doctree edit <doc_id> --item <item_id> --field body`), or MCP tools (`spool_doc_write`).
   - `/spec-kit-tasks` reads the spec item tree via `spool doctree read` (or `spool_doc_read` MCP) and writes the generated task items into the `tasks` Qto doc under the spec folder.
   - Panel review seats write their review evaluations into the spec's `panel/` Qto sub-documents (`/repo/specs/<NNN>-<slug>/panel/<seat>`).
   - Implementation lanes ticking tasks edit the corresponding task item in the `tasks` Qto doc, updating status to `Implemented` and adding the commit SHA, proof command, and pass results.
2. **How the export reaches master before build lanes read it**:
   - Before an implementation lane is spawned to execute tasks, the updated spec and `tasks.md` must be exported and committed to `master`. Build lanes check out `origin/master` and read spec/task markdown files offline without requiring live PostgreSQL access.
   - The export reaches master via one of two paths:
     a. **Publish Button (interactive / UI)**: A human or agent with `docs.write` presses Publish in Qto (`publish.md:95-103`), executing a fast-forward commit to GitHub master via the GitHub App (`internal/github/repo.go:124`, `publish.md:124-147`).
     b. **Lane Export (`do_spl_doctree_export_md` / T066 recorded writer)**: A lane runs `ENV=prd TENANT_ID=t1 QTO_DOC=<id> ./run -a do_spl_doctree_export_md` (`csi-spl-orc/src/bash/run/spl-doctree-export-md.func.sh:31-67`), which generates the byte-stable `.md` with the standardized header stamp (`> Generated from qto doc <id>; edit it there.`), records the `lane_export` row, stages the explicit pathspec, and pushes via `do_spl_push_master`.
3. **No-direct-md-edit guard**:
   - Every mapped spec `.md` file listed in `qto-docs.tsv` is protected by the pre-push gate (T040, `check-pre-push.func.sh:35`).
   - A lane attempting to edit `csi-spl-doc/specs/**.md` directly via git without updating Qto is blocked by the pre-push hook:
     `FATAL: direct edit to csi-spl-doc/specs/... detected. This document is managed by Qto. Edit it via Qto and run do_spl_doctree_export_md.`
   - `spl-doctree-import-md.func.sh:41-43` similarly guards against git overwrites of mapped exports.

---

### 10.2 Agent instructions: loading paths, staleness, and fleet rules governance

#### 10.2.1 Reality check: agent instruction loading paths today
Agent instructions comprise ~29 critical markdown files that are loaded directly by installers, refresh actions, and spawn scripts on `origin/master`:
- `csi-spl-orc/src/bash/features/spool-install/assets/claude/claude-md/*.md` (8 files: `00-title.md`, `05-agents-run-as-agent-user.md`, `07-permission-mode-bypass.md`, `10-push-and-deploy.md`, `20-spawn-an-agent.md`, `25-stay-in-your-lane.md`, `27-lane-issue-and-docs.md`, `30-cross-lane-findings.md`):
  - Concatenated by `spool-install/steps/y4-claude-config.sh:6-9` and `y4-claude-config.py:151` (`fragments("claude-md", "md")`) into `~/.claude/CLAUDE.md`.
  - Rendered by `y8-vibe-agents.sh:35` and `y8-vibe-agents.py:18-24` into `~/.vibe/AGENTS.md` for Mistral seats.
  - Fragment `25-stay-in-your-lane.md` extracted by `y9-vendor-lane-rule.sh:27` into `~/.gemini/config/rules/25-stay-in-your-lane.md` and `~/.qwen/QWEN.md`.
- `csi-spl-orc/src/bash/features/spool-install/assets/agy/rules/30-exit-after-accepted.md` (1 file): installed into `~/.gemini/config/rules/`.
- `csi-spl-orc/src/bash/features/spawn-agents/assets/commands/*.md` (9 files: `agy-spawn.md`, `claude-spawn.md`, `grok-spawn.md`, `mistral-spawn.md`, `qwen-spawn.md`, `riname.md`, `signed-prompt.md`, `spawn-an-agent.md`, `tmux-close-window.md`): installed into `~/.claude/commands/` and adopted by `y5-adopt-skills.sh:21`.
- `csi-spl-orc/src/bash/features/spawn-agents/assets/skills/*/SKILL.md` (6 files: `agent-msg`, `exit-clean`, `kill-your-self`, `paste-html-into-chrome`, `spec-kit-tasks`, `tmux-color`): installed into `~/.claude/skills/` and `~/.gemini/config/skills/` by `y5-adopt-skills.sh:21` and refreshed by `spl-skills-refresh.func.sh:105`.
- `csi-spl-orc/src/bash/features/graft/assets/**` (`skills/graft/SKILL.md`, `agy-rules/graft.md`): installed by `spool-install/install.sh` and `graft-install.sh`.
- `csi-spl-orc/src/bash/features/gc/gc-prompt.md` (1 file): loaded by GC agent launcher (`gc-spawn.sh`).
- `csi-spl-orc/src/bash/features/dispatch/brief-dispatcher.tpl.md` (1 file): loaded by dispatch rotation brief generator (`spl-dispatch-rotate.func.sh`).

#### 10.2.2 Currency and staleness rules
1. **Export must be current before install or spawn**:
   - `spool-install`, `spawn-agents`, and `spl-skills-refresh` execute purely against the local filesystem checkout. They do NOT make network calls to PostgreSQL at runtime to fetch instructions.
   - Any modification to an agent instruction document in Qto MUST be published and landed on `master` prior to executing `spool-install` or spawning agents that depend on the rule.
2. **What happens on a stale export**:
   - If a rule is edited in Qto but not exported:
     - The Qto UI displays the status chip `Changed since publish (N revs)` (`publish.md:237`).
     - Agents spawned on boxes continue executing the last landed worktree rules (guaranteeing deterministic, crash-safe behavior).
     - If an unexported rule creates drift between the git tree and installed copies or pinned facts, `do_check_fleet_rules_drift` (`csi-spl-orc/src/bash/run/check-fleet-rules-drift.func.sh:50-55`) fails in the pre-push hygiene gate:
       `FAIL fleet rules drift: two sources disagree (above); fix the copy that is not the home named in fleet-rules-index.md`.
     - The pre-push drift gate prevents pushing any commit when fleet rules disagree across sources.
3. **Who may edit**:
   - Fleet rules are governed by the strict "One home per rule" doctrine (`csi-spl-doc/doc/md/fleet-rules-index.md:15-25, 29-52`).
   - Only authorized roles holding `docs.write` in the `system` tenant (orchestrator seat `c-001`, system administrators, owner) may edit agent instruction documents in Qto.
   - Edits must occur exclusively in the rule's designated single home (e.g. `20-spawn-an-agent.md` for agent ceiling, data rule, language rule; `25-stay-in-your-lane.md` for lane boundary; `27-lane-issue-and-docs.md` for lane issues).
   - When a home document is exported and published, any pointers in other files are synchronized, verified by running `do_check_fleet_rules_drift`.

---

### 10.3 Import plan per group: workspaces, folders, qto-docs.tsv, and gaps

#### 10.3.1 Owner rule for every import (msg ce0eae22)
> *"A bug met while importing an .md into Qto PAUSES that file's import: file the bug, a lane fixes it so the import works, then the Qto doc is created and the import continues. Never import a degraded copy, never hand-edit the .md to dodge the bug."*

This rule is binding for all three import groups. When an `.md` file is refused by `spl-doctree-md.py split`:
1. That file's import is immediately **PAUSED**.
2. A tracked issue is filed defining the parser/tooling gap.
3. A build lane resolves the gap in `spl-doctree-md.py` / `spool doctree` tooling.
4. Once the fix lands and tests pass, the file's import resumes and the Qto doc is created.
5. Under NO circumstances is an `.md` file hand-edited to bypass an import check, nor is a degraded copy imported.

#### 10.3.2 Gap catalog (G1 through G7)
- **G1 (Heading outline dot)**: `## 1. Title` dropped the dot to become `## 1 Title`. RESOLVED by SPL-1900 (`049bc0840`, T012c) via `attrs.outline_dot`.
- **G2 (Spacing and indentation fidelity)**: Trimmed bodies lost leading indent, tight headings, and blank lines. RESOLVED by SPL-1900 (`049bc0840`, T012c) via verbatim line storage and `attrs.tight` / `attrs.tight_end`.
- **G3 (Section 0 refusal)**: Documents starting with `## 0 ...` (e.g. `## 0 Scope`, `## 0 Owner asks`) fail `check_outline` (`spl-doctree-md.py:187-190`) because Qto sibling numbering begins at 1 (`section '0 ...' would become 1 in the qto doc`). Blocks 78 specs, 39 doc pages, 2 agent skills (`exit-clean`, `kill-your-self`).
- **G4 (Outline numbering mismatch / skip)**: Documents where section numbers jump (e.g. `1.5` under `1` without `1.1-1.4`, or `3.3.1` under `3.3`) fail `check_outline`. Blocks 20 specs, 10 doc pages, 1 README (`spawn-agents/README.md`), 1 command (`signed-prompt.md`).
- **G5 (Level skip & missing `# ` title line)**: Documents jumping heading depths (e.g. `#` to `###`) or headless fragments lacking a top-level `# ` (e.g. `05-agents-run-as-agent-user.md` through `30-cross-lane-findings.md` in `claude-md/`). Blocks 29 specs, 7 claude-md fragments.
- **G6 (Relative images)**: Documents containing `![alt](../../img/...)` or `![alt](./img/...)`. Qto stores images via `<figure>` / GCS files; relative repo file paths are not resolved in Qto editor. Blocks `system-guide.md` and image-carrying specs.
- **G7 (Preamble-only documents)**: Documents containing a preamble but zero heading sections. RESOLVED by SPL-1909 (`1a253050d`, `54d08f21b`) by importing as root item body.

#### 10.3.3 Group 1: Agent Instructions (~29 files)
- **Workspace**: `system` tenant (`fs=repo`).
- **Folder**: `/repo/agent-instructions/` with subfolders: `commands/`, `skills/`, `rules/`, `claude-md/`, `dispatch/`, `gc/`.
- **`qto-docs.tsv` mapping**: `<doc_id>\t<relative-path>\trepo` (e.g. `<uuid>\tcsi-spl-orc/src/bash/features/spawn-agents/assets/commands/spawn-an-agent.md\trepo`).
- **Gaps blocking**:
  - 7 claude-md fragments (`05`, `07`, `10`, `20`, `25`, `27`, `30`): Blocked by Gap G5 (headless fragments lacking `# ` title line).
  - `signed-prompt.md`: Blocked by Gap G4 (section `1.5 Where it runs` outline skip).
  - `exit-clean/SKILL.md` and `kill-your-self/SKILL.md`: Blocked by Gap G3 (section `0 When`).
  - **Clean slice (19 files)**: `00-title.md`, `30-exit-after-accepted.md`, 8 commands, 4 skills, `graft/**` md files, `gc-prompt.md`, `brief-dispatcher.tpl.md`.
- **Import order**:
  1. Import 19 clean files immediately.
  2. PAUSE the 10 blocked files per msg `ce0eae22`.
  3. File bug lanes for G3, G4, G5 in `spl-doctree-md.py`.
  4. Resume and import the remaining 10 files once tooling fixes land.

#### 10.3.4 Group 2: Our Own README.md Files (21 files)
- **Workspace**: `system` tenant (`fs=repo`).
- **Folder**: `/repo/readmes/` (with folder hierarchy mirroring repository parts: `root`, `api`, `cnf`, `dat`, `doc`, `iac`, `orc`, `rdb`, `utl`, `wui`).
- **`qto-docs.tsv` mapping**: `<doc_id>\t<relative-path>\trepo` (e.g. `<uuid>\tREADME.md\trepo`, `<uuid>\tcsi-spl-api/README.md\trepo`).
- **Gaps blocking**:
  - **Clean slice (20 files)**: 20 of the 21 READMEs parse and split cleanly today without errors.
  - **Paused slice (1 file)**: `csi-spl-orc/src/bash/features/spawn-agents/README.md` is blocked by Gap G4 (section `3.3.1` outline skip).
- **Import order**:
  1. Import the 20 clean READMEs.
  2. PAUSE `spawn-agents/README.md` until Gap G4 tooling fix lands.
  3. Resume and import `spawn-agents/README.md` with zero degraded copies.

#### 10.3.5 Group 3: Specs (`csi-spl-doc/specs/`, 503 files across 138 specs)
- **Workspace**: `system` tenant (`fs=repo`).
- **Folder**: `/repo/specs/` with subfolders for each numbered spec (`002-box-agent-messaging/`, `003-spool-message-bus/`, ..., `141-invite-display-name/`).
- **`qto-docs.tsv` mapping**: `<doc_id>\tcsi-spl-doc/specs/<path>\trepo`.
- **Gaps blocking**:
  - **Clean slice (382 files)**: 382 spec files pass `split` cleanly and are imported batch-by-batch.
  - **Paused slice (127 files)**: 78 files blocked by G3 (section 0), 20 files by G4 (numbering skip), 18 files by G5 (depth skip), 11 files by G5 (missing `# ` title), plus relative image files (G6).
- **Import order**:
  1. Sequenced after Agent Instructions and READMEs.
  2. Batch imported by spec number (`002` through `141`).
  3. Clean files imported; any file hitting G3-G6 is paused, bugs filed, and resumed after tooling fixes land.

---

### 10.4 Public repository hygiene and the hidden-workspace gate

#### 10.4.1 Public repository baseline
The repository `csi-spl` is open source and public (`csi-spl-doc/specs/044-open-source/spec.md`). In contrast, customer and enterprise workspaces hosted on Spool Hub contain confidential tenant data, internal URLs, and private instructions.
Under Spec 129 (`csi-spl-doc/specs/129-private-git-specs/spec.md:104-180`) and the private overlay system (`SPL-1874`, `csi-spl-orc/src/bash/scripts/oss-gate.py:108-133`), confidential workspace identifiers are replaced with placeholders (e.g. `ws-hidden-01`, `ws-hidden-02`) and resolved only on-demand via the private overlay (`.gcp/.csi/csi-spl-private.yaml`).

#### 10.4.2 The hidden-workspace gate
To guarantee that no private workspace content, internal tokens, or confidential identifiers ever leak into the public GitHub repository via a Qto export:
1. **Target path restriction**: Documents exported to the repository may only write to approved public documentation directories (`csi-spl-doc/specs/`, `csi-spl-doc/doc/`, or valid module README paths). Publishing to arbitrary paths is refused (`publish.md:137-140`).
2. **Automated hygiene scanning**:
   - On Publish (`publish.md:126-147`): `repodocs.Gate` (`csi-spl-api/src/go/spool-hub-api/internal/repodocs/gate.go:104`) automatically executes distribution-hygiene pattern checks and secret scanning over the **WHOLE** document before committing to GitHub.
   - On lane export (`do_spl_doctree_export_md`): checks hygiene rules before replacing the local file in the worktree.
3. **Rejection of private content**:
   - If the text contains private workspace slugs, unmasked tenant names from the private overlay list (`{{private:<list>}}`), customer email addresses, service account keys, internal IP addresses, or proprietary tokens:
     - The export is refused with HTTP 422 `rejected_text` (Publish) or exit code 1 (`do_spl_doctree_export_md`).
     - Diagnostic output reports strictly the violated rule name and line number; the confidential text itself is NEVER echoed or written to logs.
     - The database audit log records status `rejected` with the rule name. Nothing is committed to GitHub.
4. **Author identity cleansing**:
   - Commits generated by Publish or lane exports use the repo's canonical commit identity (CLAUDE.md §5.1, `publish.md:150-155`). User personal emails and internal database nonces are never committed.

---

### 10.5 README files: preservation of folder-page navigation

#### 10.5.1 The folder page requirement
GitHub natively detects `README.md` in any repository directory and renders it as the directory's landing page (e.g. viewing `github.com/csitea/csi-spl/tree/master/csi-spl-api` automatically renders `csi-spl-api/README.md`).
Moving README files to Qto as the authoring master must NOT break this core GitHub navigation behavior.

#### 10.5.2 Path invariant
The exported `.md` file for every README document MUST remain at its exact existing repository path:
`<module-path>/README.md` (e.g. `csi-spl-api/README.md`, `csi-spl-orc/README.md`, root `README.md`).
README files are NEVER aggregated or relocated to a centralized documentation subfolder.

#### 10.5.3 Complete inventory of our own 21 README.md files
Checked on `origin/master` using `git ls-files '*README.md'`:
1. `README.md` (root project overview)
2. `csi-spl-api/README.md` (Go API, MCP, CLI)
3. `csi-spl-cnf/README.md` (environment configuration)
4. `csi-spl-cnf/src/python/conf-validator/README.md` (config validation)
5. `csi-spl-dat/README.md` (data assets)
6. `csi-spl-doc/README.md` (documentation root)
7. `csi-spl-doc/goals/README.md` (project goals)
8. `csi-spl-doc/specs/README.md` (git-spec index and ground rules)
9. `csi-spl-doc/specs/102-agent-lifetime/opinions/README.md` (agent lifetime opinions)
10. `csi-spl-iac/README.md` (infrastructure as code actions)
11. `csi-spl-iac/src/terraform/modules/README.md` (terraform modules)
12. `csi-spl-orc/README.md` (orchestration, lde, infra stack)
13. `csi-spl-orc/src/bash/features/directive/README.md` (directive feature)
14. `csi-spl-orc/src/bash/features/graft/README.md` (graft code index)
15. `csi-spl-orc/src/bash/features/graft/assets/wasm/README.md` (tree-sitter wasm assets)
16. `csi-spl-orc/src/bash/features/mcp-bot/README.md` (mcp-bot feature)
17. `csi-spl-orc/src/bash/features/spawn-agents/README.md` (agent spawning)
18. `csi-spl-rdb/README.md` (relational database schemas)
19. `csi-spl-utl/README.md` (utilities)
20. `csi-spl-wui/README.md` (Nuxt 3 web UI)
21. `csi-spl-wui/src/python/i18n/README.md` (i18n tooling)

Explicitly excluded:
- `csi-spl-doc/.specify/extensions/git/README.md` (third-party vendored spec-kit upstream).
- `csi-spl-orc/src/bash/tests/fixtures/wd-situations/README.md` (test fixture).

---

### 10.6 Test requirements for implementation lanes

Build lanes implementing the migration of specs, agent instructions, and READMEs to Qto must implement two mandatory automated test gates:

#### 10.6.1 Gate 1: Direct Edit Refusal Test
- **Test location**: `csi-spl-orc/src/bash/tests/doctree-export-md.tst.sh` (new sections) and `csi-spl-iac/src/bash/tests/check-pre-push.tst.sh`.
- **Test logic**:
  1. Register a test spec file (e.g. `csi-spl-doc/specs/002-box-agent-messaging/spec.md`) and a test agent instruction file (e.g. `csi-spl-orc/src/bash/features/spawn-agents/assets/skills/exit-clean/SKILL.md`) in `qto-docs.tsv`.
  2. Simulate a lane directly editing the `.md` file in git without updating Qto.
  3. Run the pre-push gate `do_check_pre_push`.
  4. Verify that `do_check_pre_push` fails fast with non-zero exit status, outputting the diagnostic error:
     `FATAL: direct edit to <file> detected. This document is managed by Qto. Edit it via Qto and run do_spl_doctree_export_md.`
  5. Negative control: Edit an unmapped file; verify `do_check_pre_push` passes without refusal.

#### 10.6.2 Gate 2: Export Round-Trip Byte Parity Test
- **Test location**: `csi-spl-orc/src/bash/tests/doctree-export-md.tst.sh` and `csi-spl-api/cmd/spool/doctree_export_test.go`.
- **Test logic**:
  1. For every document registered in `qto-docs.tsv` (specs, agent instructions, READMEs), execute `do_spl_doctree_export_md`.
  2. Execute `git diff --exit-code <path>` (or `cmp -s`).
  3. Verify byte-for-byte identity. The only permitted difference between origin/master original and exported file is the standardized header stamp on line 2:
     `> Generated from qto doc <doc_id>; edit it there. This file is its export: do_spl_doctree_export_md rewrites it.`
  4. Verify that code fences, headings, tables, citations, indentation, and blank line runs round-trip with zero corruption.

---

## 11. Version log

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1.0 | 2026-10-13 | a-954 | Initial complete specification for Qto as the only doc editor, unified spool-hub file system, and markdown editing retirement (SPL-1730). Covers verbatim owner requirements (topic `bed3ed0a`), full measured scale across all 1,247 repo md files, comprehensive 27-row Markdown feature and gap matrix, detailed specifications for paragraph tables (Owner msg 2c82489a) and citations (Owner msg b1661d1c), architecture for merging Spec 075 and Qto into ONE PostgreSQL file system with RLS and capability permissions, a five-phase markdown retirement plan, and preparation for the Step 2 expert panel. |
| v0.2.0 | 2026-10-14 | a-965 | Step 2 panel consensus folded (SPL-1743): P-Q1..P-Q5 decided (A A A A A), 5 verified corrections applied (RLS GUCs corrected to app.tenant_id/app.rls_scope, front matter stored in root item attrs.front_matter, spec 075 repo-edit deprecation tasked, Go export test moved to Phase 1, bulk import decomposed into 4 slices). Tasks marked ready to build with disjoint lane groups. |
| v0.2.1 | 2026-10-14 | c-526 | §5.3 Publish button addendum linked to [publish.md](publish.md) (SPL-1887, owner msg b04f0ab5); tasks T060..T067 Planned. |
| v0.2.2 | 2026-10-14 | c-526 | §5.3: owner decisions on the Publish button folded (poll 72d2b3da, msg 86c7b888); publish.md v0.2.0. |
| v0.2.3 | 2026-10-14 | c-526 | §5.3: no review step for Publish (owner msg af133e9c); publish.md v0.3.0. |
| v0.3.0 | 2026-10-15 | a-577 | Addendum §10: specs (503 files in 138 specs), agent instructions (~29 files), and our 21 README.md files move to Qto as master; authoring, ticking, and export workflow; import plan with gap handling (G1-G7) and pause rule (owner msg ce0eae22); public repo hidden-workspace gate; test requirements (SPL-2030). |

<!-- version: 0.3.0 · updated: 2026-10-15 · last-edit: 2026-10-15T20:30:00Z -->

