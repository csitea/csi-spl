# Implementation Plan: 075 Docs Section

**Branch**: `a-223-docs-section-spec` | **Date**: 2026-10-04 | **Spec**: [075 spec.md](spec.md)
**Topic**: `9f0d751c-c0db-4e56-ad8b-798ab312f1ff`

## Summary

The Docs section introduces a dedicated documentation workspace in the spool web application (`/docs`) featuring a two-panel Windows Explorer-like layout: a collapsible folder tree on the left and themed Markdown rendering on the right. 

The implementation rolls out in five structured phases:
1. **Phase 1: Repo Docs (Read-Only)**: Object storage bucket hosting all repository `.md` files uploaded on deploy, served via Hub API (`/v1/docs/...`), rendered in WUI with Explorer tree (built by lane `c-221`).
2. **Phase 2: Workspace Docs**: User- and agent-authored documentation stored in a dedicated Google Cloud Storage bucket per workspace (`csi-spl-<env>-docs-<tenant>`), docs only, mediated exclusively by the Hub runtime service account with strict per-tenant session isolation and `.history/` revision audit.
3. **Phase 3: Omnisearch & Search Integration**: In-app search via Hub search worker across workspace and repo docs, combined with public Google Site Search integration for open repository documentation.
4. **Phase 4: Linking Capabilities**: Auto-linking git-spec citations (e.g. `spec 072`) to in-app docs across all messages/topics, and bi-directional binding between docs and discussion topics.
5. **Phase 5: Corporate Enterprise**: Vector database (`pgvector` / external vector store) for semantic natural language search and enterprise IAM/ACLs.

## Technical Context

**Language/Version**:
- Hub API: Go 1.22+ (`csi-spl-api/src/go/spool-hub-api`)
- Web UI: TypeScript / Vue 3 / Nuxt 3 (`csi-spl-wui`)
- Database: PostgreSQL 16+ (`csi-spl-rdb`)
- Infrastructure: Terraform / Google Cloud Storage (`csi-spl-iac`)

**Primary Dependencies**:
- Backend: Standard Go `net/http`, `blob.Store` interface, `cloud.google.com/go/storage`
- Frontend: `MarkdownBlock.vue` (unified renderer), `useSpoolApi`, Nuxt routing, `lucide` icons
- Search: In-app inverted search index, Google Programmable Search API

**Storage**:
- Phase 1: Environment-wide GCS bucket for static deployed repo docs (`csi-spl-<env>-docs`)
- Phase 2: Dedicated GCS bucket per workspace for workspace docs + history (`csi-spl-<env>-docs-<tenant>`), docs only
- Phase 5: PostgreSQL `pgvector` extension for semantic embedding storage

**Testing**:
- Backend: Go unit tests (`docs_test.go`, `workspace_docs_test.go`), cross-tenant isolation tests
- Frontend: Node unit tests (`docs.test.mjs`, `help-sync.test.mjs`), Playwright / Nuxt e2e tests
- Lint & Hygiene: `do_check_dist_hygiene`, `do_check_pre_push_lint`

**Target Platform**: Linux server (Cloud Run / Docker Compose), Modern web browsers (Desktop & Mobile viewports down to 360px).

## Constitution Check

*GATE: Checked against repo ground rules and distribution hygiene.*

- [x] **I. Paths** — Derived dynamically from repository and deployment metadata; no hardcoded absolute paths.
- [x] **II. Env** — Cloud storage buckets and domain names configured via environment variables and project configuration (`${SPL_ORG_APP}-${ENV}-docs-${WORKSPACE_SLUG}`, `<BASE_DOMAIN>`).
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
│   │   ├── workspace_docs_test.go # Phase 2: Tenant isolation unit tests
│   │   └── search_docs.go        # Phase 3: Omnisearch doc queries
│   └── store/
│       └── migrations/
│           └── 0117_doc_topics.sql # Phase 4: Doc <-> Topic binding schema

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
csi-spl-iac/src/terraform/
├── 051-gcs-docs/                 # Phase 1: Environment repo docs bucket
└── 052-gcs-tenant-docs/          # Phase 2: Per-workspace docs buckets
csi-spl-orc/src/bash/run/
└── spl-publish-docs.func.sh      # Phase 1: Deploy publish action (do_publish_docs)
```

## Complexity Tracking

| Component | Why Needed | Alternative Rejected |
|---|---|---|
| Dedicated GCS Bucket per Workspace | Full physical data isolation per tenant; straightforward lifecycle and capacity management; direct owner mandate (msg 9431127d). | Single DB table: Rejected per owner decision 9431127d. Single shared bucket: Rejected because per-tenant IAM / bucket deletion guarantees no cross-tenant leakage. |
| Hub SA Mediated Storage Access | Prevents exposing storage bucket credentials to browser or untrusted clients; enforces workspace session boundary in Go middleware. | Direct client pre-signed URLs: Rejected because pre-signed URLs complicate fine-grained RBAC and audit logging. |

<!-- version: 0.2.0 · updated: 2026-10-04 · last-edit: 2026-10-04T15:20:00Z -->
