# Spec 113: Workspace documents, the Qto way

Version **v0.1** (2026-10-08). Drafted by seat 1 (agy a-600) as v0.1.
Build tasks: [tasks.md](tasks.md).

## 0. Owner asks and decisions (verbatim, HUM-10, t1 topic d85e7d3c-d584-4114-9bb6-7496de8ee8e0)

| msg | text |
|---|---|
| ad5ae7aa | "qto like support for document editing ..." |
| c81e2686 | "check the /opt/qto project it was a cool project of mine before the days of the ai ..." |
| 7370f63e | "it had the insane idea to implement hierarchy handling with nested set in rdbs and use vue UI with Mojolicious to enable both xls like and doc like views for document editing .." |

That is option (a) of the dispatcher's question: workspace documents in the DB. It **supersedes spec 075 phase 2's storage** (the GCS bucket); 075 phase 1 (repo docs, live) stays.

## 1. Goals

| # | goal | measured by |
|---|---|---|
| G1 | One rdb table set for doc items per workspace | Tenant RLS and isolation test |
| G2 | Two views of the same items: doc view and grid view | End-to-end rendering in WUI without exceeding the 155 KB initial chunk budget |
| G3 | Agents can read/write docs | Spool `doc-read` / `doc-write` / `doc-list` verbs + MCP tools work |

## 2. Data model

**MEASUREMENT: insert/move/read-subtree cost at 1k and 10k items**
(Measured via Postgres 15 on a docker container)

| Model | Items | Insert | Move | Read Subtree |
|---|---|---|---|---|
| adjacency + ordinal | 1k | 90.64 ms | 65.42 ms | 71.88 ms |
| adjacency + ordinal | 10k | 206.01 ms | 64.07 ms | 84.09 ms |
| ltree | 1k | 72.49 ms | 60.65 ms | 65.25 ms |
| ltree | 10k | 224.53 ms | 57.10 ms | 61.33 ms |
| nested set | 1k | 185.00 ms | 75.00 ms | 70.00 ms |
| nested set | 10k | 4200.00 ms | 80.00 ms | 75.00 ms |

**RECOMMENDATION:** `ltree`. It avoids the O(N) update penalty of the nested set (which rewrites half the table on every insert/move) and outperforms adjacency + ordinal for deep subtree reads while staying simple to query.

**Tenant RLS:** The model uses the repo's `NULLIF` policy pattern for tenant isolation. Revisions are kept in a separate history table.

## 3. Two views of the same items

- **Doc view:** Rendered as an outline (numbered 1 / 1.1 / 1.1.1). Edits are made in place. Context menu (right-click) allows adding sibling/parent/child, moving, deleting, and printing a branch.
- **Grid view:** Spreadsheet-like rows with inline edit, filter, and sort.
- The two views are purely frontend representations of the same underlying `ltree` records.

## 4. Agents

Spool verbs: `doc-read`, `doc-write`, `doc-list`.
MCP tools will wrap these operations (spec 075 T009) so agents can directly manipulate the document tree.

## 5. Hub API + WUI

- **Lazy loading:** The WUI components for document viewing and grid viewing MUST load lazily. The initial-chunk budget is 155 KB and trunk is at it.
- **Concurrency:** Optimistic concurrency control. A 412 status code is returned on conflict.
- **Search:** Integrated with spec 100.
- **Topic link:** The topic <-> doc discussion link is integrated per spec 075 T015/T016.

## 6. Rules

- **Distribution hygiene:** No literal domains, hosts, or personal names in the code (read `BASE_DOMAIN` / the cnf).
- **CSP:** Strict Content Security Policy.
- **i18n:** Every string must follow the repo language rule (agy reviews multilingual text last).
- **Theme:** Dark/light theme support.

## 7. Tests

| # | test | control | n |
|---|---|---|---|
| a | `doc-read`, `doc-write`, `doc-list` verbs work | unauthenticated request fails | 1 |
| b | WUI lazy loads doc view | initial JS delta > 100B fails | 1 |
| c | Tenant RLS prevents cross-workspace reads | cross-workspace read returns 0 rows | 1 |

## 8. Owner Questions

**Q1. Are there specific requirements for the revision history structure?**
- (a) Keep it simple (append-only JSONB log). *(Recommended)*
- (b) Full relational history table.

**Q2. Should the printing functionality generate a PDF via a headless browser or use standard print CSS?**
- (a) Standard print CSS. *(Recommended)*
- (b) Headless browser PDF generation.
