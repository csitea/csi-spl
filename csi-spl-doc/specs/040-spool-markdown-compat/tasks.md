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
| T008 | One marker: the owner picks the `md` fence or `{{wiki}}`; remove the other, or route `{{wiki}}` through `markdownTree` | — | Open (owner) |
