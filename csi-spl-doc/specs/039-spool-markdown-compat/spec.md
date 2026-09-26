# Spec 039 — Markdown compatibility

Owner, 2026-09-26 (prd #spool-hub-devel, topic 070843ba): "the display of the
issues, msgs etc. should recognize some kind of start and stop wiki tag /
template code and then know to convert standard markdown ... so that tables,
lists etc. regular markdown should be doable ... registered under a new
feature called markdown compatibility".

Status vocabulary: `../README.md` §2.3.

## 1. Requirements

| ID | Requirement | Status |
|---|---|---|
| FR-MD-001 | The START / STOP tag is a fence whose language is `md` or `markdown` (```` ```md ```` … ```` ``` ````). Everything between them renders as standard markdown: headings, bold / italic / strikethrough, ordered and bullet lists, tables, block quotes, links, inline and fenced code. | Implemented (T001, T002) |
| FR-MD-002 | Text outside such a block renders exactly as before (Slack-style code, mentions, links). | Implemented (T002) |
| FR-MD-003 | Raw HTML inside a block is shown as text and never runs; links are http, https and mailto only and open in a new tab with `rel="noopener noreferrer nofollow"`. | Implemented (T001, T003) |
| FR-MD-004 | A block can be flipped to its source text ("Show source") and back. | Implemented (T002) |
| FR-MD-005 | Every surface that renders a message body through `MessageBody.vue` gets it (messages, topics, and issues where they use it). | Partial: messages and topics; the issues views are another lane's and render through it only if they use MessageBody |

## 2. Decisions

- One syntax, not a second parser: message bodies already split fences
  (`utils/code-blocks.mjs`); a fence language picks markdown vs code.
- Library: `markdown-it` 14 with `html: false`, `linkify: true` (no raw HTML
  path exists, so no sanitizer is needed after it).
- Not in v1: task-list checkboxes, footnotes, embedded images from URLs,
  a wiki-style `:::md` tag (on request).
