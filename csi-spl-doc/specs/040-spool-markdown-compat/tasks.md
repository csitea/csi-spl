# Spec 040 — tasks

| Task | What | FR | Status |
|---|---|---|---|
| T001 | `utils/markdown.mjs`: markdown-it, html off, safe links (1c099b52); now an allow-listed node tree (`markdownTree`, `TAGS`, `ATTRS`, `safeHref`) with `treeToHtml` / `renderMarkdown` as the escaped string form (5ea0874f) | FR-MD-001, FR-MD-003 | Implemented |
| T002 | `components/MarkdownBlock.vue`: renders the tree with `h()`, Show source toggle, token colours, rem sizes, table scroll wrapper; routed from `MessageBody.vue` via `isMarkdownLang` (`code-blocks.mjs`) | FR-MD-001, FR-MD-002, FR-MD-004, FR-MD-008 | Implemented |
| T003 | `tests/unit/markdown.test.mjs`: tag detection through `parseBody`, tables / lists / headings / emphasis, safe links, CONTROL raw HTML / `javascript:` never markup | FR-MD-001, FR-MD-003 | Implemented |
| T004 | `markdown.show_source` / `markdown.show_rendered` in all 19 locales | FR-MD-004 | Implemented |
| T005 | Issues right pane: comments through `MessageBody`; a rendered view of the description (`hasMarkdownBlock`) under its textarea | FR-MD-005 | Implemented (5ea0874f) |
| T006 | Lazy engine chunk, images never fetched, `tests/unit/markdown-hostile.test.mjs` with two controls | FR-MD-003, FR-MD-006, FR-MD-007 | Implemented (5ea0874f) |
| T007 | `tests/e2e/markdown-live.proof.mjs`: 19/19 on dev and prd | FR-MD-001..008 | Implemented (6756c28f) |
| T008 | One marker: the owner picks the `md` fence or `{{wiki}}`; remove the other, or route `{{wiki}}` through `markdownTree` | — | Superseded (SPL-975: no marker needed; a ```md fence and {{wiki}} both still render) |
| T009 | `looksLikeMarkdown` / `markdownSource` (code-blocks.mjs), `markdownTree(src, { breaks, html })` + `htmlTableNodes` (markdown.mjs), MarkdownBlock bare mode, MessageBody routing; `tests/unit/markdown-unfenced.test.mjs` | FR-MD-010..012 | Implemented (19813340) |
| T010 | `IssueDescription.vue`: rendered view, click / Enter / `e` edits, save on blur, visible error | FR-MD-013 | Implemented (19813340) |
| T011 | `doc/help/how-to-post.md` and the pointers to it (MCP schema, spawn seed, desk / issue action help, help docs, CLAUDE.md) | FR-MD-014 | Implemented |
