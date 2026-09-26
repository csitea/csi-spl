# Spec 039 — tasks

| Task | What | FR | Status |
|---|---|---|---|
| T001 | `utils/markdown.mjs`: `isMarkdownLang`, `renderMarkdown` (markdown-it, html:false, safe links) | FR-MD-001, FR-MD-003 | Implemented |
| T002 | `components/MarkdownBlock.vue` (render + Show source toggle, table/list styles on radius tokens) wired into `MessageBody.vue` | FR-MD-001, FR-MD-002, FR-MD-004 | Implemented |
| T003 | `tests/unit/markdown.test.mjs`: tag detection through `parseBody`, tables/lists/headings/emphasis, safe links, CONTROL raw HTML / javascript: links never become markup | FR-MD-001, FR-MD-003 | Implemented |
| T004 | `markdown.show_source` / `markdown.show_rendered` in all 19 locales | FR-MD-004 | Implemented |
| T005 | Issues views render descriptions through MessageBody / MarkdownBlock | FR-MD-005 | Planned (issues lane) |
