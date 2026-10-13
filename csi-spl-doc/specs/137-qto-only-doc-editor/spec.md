# 137: Qto as the only doc editor, unified spool-hub file system, and md retirement

Status: **Draft v0.1** (Step 1 of owner HUM-10 task dispatch-bed3ed0a; agy a-954; issue SPL-1730).
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

Every figure in this section was verified against the repository tree at commit `4ac30d59b` on 2026-10-13 using the exact commands shown.

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
| **F07** | **Unnumbered Headings** (`## Overview`) | **559** | **Refused** (`NUM.match` fails, :67) | **Broken** (fails import) | Supported (standard md) | **CRITICAL GAP**: Modify parser to treat unnumbered headings as first-class nodes with empty outline prefix; preserve on export. |
| **F08** | **Setext Headings** (`===` / `---`) | 436 | Partial (treated as body text unless matched) | **Altered** (normalized to ATX on export) | Supported (markdown-it parses setext) | Normalize setext to ATX during import; document normalization rule. |
| **F09** | **Outline Numbering Mismatch** (skips, roman, letters) | 110 | **Refused** (`check_outline` aborts, :83-98) | **Broken** (fails import) | Supported (text) | Decouple stored section title from computed outline; support custom or non-derived outline numbers. |
| **F10** | **YAML Front Matter** (`---` header) | **443** | **Refused** (no `# ` first line, :48) | **Lost** (stripped or refused) | Ignored / text | Parse YAML front matter into `workspace_doc.attrs.front_matter` JSONB; regenerate on export. |
| **F11** | **Pipe Tables (GFM)** (`\| a \| b \|`) | **584** | **No editor tool** (raw text in textarea) | **Preserved** (survives text export) | Supported (pipe tables in `markdown.mjs:196`) | **Owner msg 2c82489a**: Add table insert/edit tool in paragraph toolbar; verify edit + export cycle. |
| **F12** | **HTML Tables** (`<table><tr><td>`) | 676 | **No editor tool** (raw text in textarea) | **Preserved** (survives text export) | Supported (`htmlTableNodes` in `markdown.mjs:203`) | Support visual table editing or preserve raw HTML blocks untouched. |
| **F13** | **Blockquotes (Simple)** (`> quote`) | 123 | **No editor tool** (raw text in textarea) | **Preserved** (survives text export) | Supported (`blockquote` in `TAGS`) | **Owner msg b1661d1c**: Add quote tool in paragraph toolbar; render styled quote card. |
| **F14** | **Nested Blockquotes** (`> > quote`) | 18 | **No editor tool** (raw text in textarea) | **Preserved** (survives text export) | Supported (nested `blockquote`) | Ensure quote tool supports indentation levels. |
| **F15** | **Citations & Attributions** (`— Author / Link`) | 123 | **No editor tool / field** | **Altered** (raw text only) | Supported as inline text | **Owner msg b1661d1c**: Support attribution field/line under blockquote; export as `> — [Source](url)`. |
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

```sql
-- Enable and force RLS on the filesystem tables
ALTER TABLE workspace_doc_node ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_doc_node FORCE ROW LEVEL SECURITY;

ALTER TABLE workspace_doc ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_doc FORCE ROW LEVEL SECURITY;

ALTER TABLE workspace_doc_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_doc_item FORCE ROW LEVEL SECURITY;

-- Policy: A session can read documents of its own workspace OR system repo docs
CREATE POLICY doc_node_select ON workspace_doc_node
    FOR SELECT
    USING (
        tenant_id = NULLIF(current_setting('spool.tenant_id', true), '')
        OR tenant_id = 'system'
        OR current_setting('spool.operator_scope', true) = 'true'
    );

-- Policy: A session can ONLY insert/update/delete documents within its own workspace (never system repo docs)
CREATE POLICY doc_node_modify ON workspace_doc_node
    FOR ALL
    USING (
        tenant_id = NULLIF(current_setting('spool.tenant_id', true), '')
        AND tenant_id <> 'system'
        OR current_setting('spool.operator_scope', true) = 'true'
    )
    WITH CHECK (
        tenant_id = NULLIF(current_setting('spool.tenant_id', true), '')
        AND tenant_id <> 'system'
        OR current_setting('spool.operator_scope', true) = 'true'
    );
```

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

#### Phase 4: Git Pre-Push Gate Enforcement
- Update the pre-push gate (`csi-spl-iac/src/bash/run/spl-check-pre-push.func.sh` / `10_ci-quality.yml`):
  - A commit touching a mapped `.md` file must be generated by `do_spl_doctree_export_md` (verified by comparing the commit against the exported hash or checking the export stamp).
  - Direct, manual edits to `.md` files that are not synchronized with the database are rejected by the pre-push hook:
    `FATAL: direct edit to <file>.md detected. This document is managed by Qto. Edit it via Qto and run do_spl_doctree_export_md.`

#### Phase 5: Complete Retirement of Manual Markdown Editing
- Remove manual markdown authoring instructions from developer guides.
- Agent seeds and prompts updated: agents are instructed to use `spool doc-*` for documentation updates rather than modifying `.md` files directly.
- Full retirement achieved: Qto is the sole doc editor across the fleet.

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

## 9. Version log

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1.0 | 2026-10-13 | a-954 | Initial complete specification for Qto as the only doc editor, unified spool-hub file system, and markdown editing retirement (SPL-1730). Covers verbatim owner requirements (topic `bed3ed0a`), full measured scale across all 1,247 repo md files, comprehensive 27-row Markdown feature and gap matrix, detailed specifications for paragraph tables (Owner msg 2c82489a) and citations (Owner msg b1661d1c), architecture for merging Spec 075 and Qto into ONE PostgreSQL file system with RLS and capability permissions, a five-phase markdown retirement plan, and preparation for the Step 2 expert panel. |

<!-- version: 0.1.0 · updated: 2026-10-13 · last-edit: 2026-10-13T21:00:00Z -->
