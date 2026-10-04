# Implementation Plan: 075 Docs Section

**Branch**: `a-223-docs-section-spec` | **Date**: 2026-10-04 | **Spec**: [075 spec.md](spec.md)
**Topic**: `9f0d751c-c0db-4e56-ad8b-798ab312f1ff`

## Summary

The Docs section introduces a dedicated documentation workspace in the spool web application (`/docs`) featuring a two-panel Windows Explorer-like layout: a collapsible folder tree on the left and themed Markdown rendering on the right. 

The implementation rolls out in five structured phases:
1. **Phase 1: Repo Docs (Read-Only)**: Object storage bucket hosting all repository `.md` files uploaded on deploy, served via Hub API (`/v1/docs/...`), rendered in WUI with Explorer tree (built by lane `c-221`).
2. **Phase 2: Workspace Docs**: User- and agent-authored documentation stored in Hub PostgreSQL under strict Row-Level Security (`app.tenant_id`) with full revision history (`workspace_docs`, `workspace_doc_revisions`).
3. **Phase 3: Omnisearch & Search Integration**: In-app Full-Text Search via PostgreSQL `tsvector` for private workspace docs, combined with public Google Site Search integration for open repository documentation.
4. **Phase 4: Linking Capabilities**: Auto-linking git-spec citations (e.g. `spec 072`) to in-app docs across all messages/topics, and bi-directional binding between docs and discussion topics.
5. **Phase 5: Corporate Enterprise**: Vector database (`pgvector` / external vector store) for semantic natural language search and enterprise IAM/ACLs.

## Technical Context

**Language/Version**:
- Hub API: Go 1.22+ (`csi-spl-api/src/go/spool-hub-api`)
- Web UI: TypeScript / Vue 3 / Nuxt 3 (`csi-spl-wui`)
- Database: PostgreSQL 16+ (`csi-spl-rdb`)
- Infrastructure: Terraform / Google Cloud Storage (`csi-spl-iac`)

**Primary Dependencies**:
- Backend: Standard Go `net/http`, `blob.Store` interface, PostgreSQL driver `jackc/pgx/v5`
- Frontend: `MarkdownBlock.vue` (unified renderer), `useSpoolApi`, Nuxt routing, `lucide` icons
- Search: PostgreSQL Full-Text Search (`tsvector`, GIN indexing), Google Programmable Search API

**Storage**:
- Phase 1: Cloud Object Storage (`GCS` / `S3`) bucket for static deployed repo docs
- Phase 2: PostgreSQL database tables with forced RLS (`workspace_docs`, `workspace_doc_revisions`)
- Phase 5: PostgreSQL `pgvector` extension for semantic embedding storage

**Testing**:
- Backend: Go unit tests (`docs_test.go`, `store_test.go`), Postgres RLS isolation tests
- Frontend: Node unit tests (`docs.test.mjs`, `help-sync.test.mjs`), Playwright / Nuxt e2e tests
- Lint & Hygiene: `do_check_dist_hygiene`, `do_check_pre_push_lint`

**Target Platform**: Linux server (Cloud Run / Docker Compose), Modern web browsers (Desktop & Mobile viewports down to 360px).

## Constitution Check

*GATE: Checked against repo ground rules and distribution hygiene.*

- [x] **I. Paths** — Derived dynamically from repository and deployment metadata; no hardcoded absolute paths.
- [x] **II. Env** — Cloud storage buckets and domain names configured via environment variables (`SPOOL_DOCS_BUCKET`, `<BASE_DOMAIN>`).
- [x] **VI. Cnf-only config** — Settings defined in `csi-spl-cnf` and injected at deploy.
- [x] **V. Hygiene** — Fully org-neutral; zero personal names, zero literal server IPs/hosts, placeholders (`<BASE_DOMAIN>`, `<tenant>`, `<run-time>.csitea.net`) used throughout.

## Phased Execution Layout

```
specs/075-docs-section/
├── spec.md              # Authoritative behaviour and rules
├── plan.md              # Technical architecture and implementation plan
└── tasks.md             # Concrete phased task breakdown and done checks
```

### Source Code Mapping

```text
# Backend (csi-spl-api)
csi-spl-api/src/go/spool-hub-api/
├── internal/
│   ├── hub/
│   │   ├── docs.go               # Phase 1: Repo docs serving (/v1/docs/...)
│   │   ├── docs_test.go          # Phase 1: Unit tests
│   │   ├── workspace_docs.go     # Phase 2: Workspace docs CRUD endpoints
│   │   └── search_docs.go        # Phase 3: Omnisearch doc queries
│   └── store/
│       ├── workspace_docs.go     # Phase 2: Store queries under inTenant()
│       └── migrations/
│           ├── 0116_workspace_docs.sql # Phase 2: Schema, RLS & FTS
│           └── 0117_doc_topics.sql     # Phase 4: Doc <-> Topic binding

# Frontend (csi-spl-wui)
csi-spl-wui/src/
├── pages/
│   └── docs/
│       └── [...path].vue         # Two-panel Explorer and Markdown viewer
├── utils/
│   ├── docs.mjs                  # Explorer tree builder & link rewriter
│   └── id-links.mjs              # Phase 4: Git-spec citation auto-linker
└── components/
    └── docs/
        ├── WorkspaceDocEditor.vue # Phase 2: Markdown editor with live preview
        └── DocTopicBinder.vue     # Phase 4: Discussion topic badge & drawer

# Infrastructure & Deploy (csi-spl-iac / csi-spl-orc)
csi-spl-iac/terraform/modules/
└── 035-gcp-docs-bucket/          # Phase 1: Terraform GCS bucket definition
csi-spl-orc/src/bash/run/
└── spl-publish-docs.func.sh      # Phase 1: Deploy publish action (do_publish_docs)
```

## Complexity Tracking

| Component | Why Needed | Alternative Rejected |
|---|---|---|
| PostgreSQL RLS for Workspace Docs | Guarantees strict multi-tenant data isolation; prevents cross-workspace data leakage even on software defects. | Dedicated GCS bucket per tenant: Rejected due to lack of ACID transactions, high metadata latency, and complex ACL management. |
| In-App Postgres FTS vs Google CSE | Preserves enterprise confidentiality; Google cannot index private authenticated docs. | Pure Google Site Search: Rejected because Google only crawls unauthenticated public web pages. |

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T13:16:00Z -->
