# 075: the Docs section (repo and workspace markdown, explorer tree, search, links)

**Feature ID**: `075-docs-section` · **Milestone**: M3 · **Status**: Draft
**Created**: 2026-10-04 · **Lane**: a-223 · **Topic**: `9f0d751c-c0db-4e56-ad8b-798ab312f1ff`
**Authority**: this file for the behaviour and its rules; `tasks.md` for what is built, with the sha and the check for each item. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing (`../README.md` §2.4).

Builds on, and does not repeat:
- [002 box-agent messaging](../002-box-agent-messaging/spec.md) (local folder spool, CLI + MCP contracts)
- [003 message bus](../003-spool-message-bus/spec.md) (the hub, store, blob storage, viewer API)
- [005 WUI](../005-spool-wui/spec.md) (Slack-like interface, layout, theming)
- [013 chat reverse](../013-spool-chat-reverse/spec.md) (feed layout and card display)
- [022 top-bar & global search](../022-spool-wui-top-bar-search/spec.md) (Omnibox `/search` mode, grouped search results)
- [025 workspace RBAC](../025-spool-tenant-rbac/spec.md) (roles, permissions, and entry gates)
- [026 workspace from identity](../026-spool-tenant-from-identity/spec.md) (single API host, identity resolution)
- [032 message edit & revisions](../032-spool-message-edit/spec.md) (versioning and revision history)
- [044 open source](../044-spool-open-source/spec.md) (public repo, OSS export gates)
- [046 workspace settings](../046-spool-tenant-settings/spec.md) (workspace-scoped settings and RLS)
- [072 rapid deployability](../072-rapid-deployability/spec.md) (one-command setup, dev usability)
- [074 operator workspace](../074-operator-workspace/spec.md) (multi-workspace management)
- and `../../doc/help/` (Help section sync and rendering pattern).

`<BASE_DOMAIN>`, `<tenant>`, `<workspace_id>`, `<human_id>`, and `<run-time>.csitea.net` are placeholders. No estate value appears as a literal to copy.
Per the owner's wording rule, this specification uses the term **workspace** throughout the narrative, requirements, user stories, and acceptance scenarios; the term **tenant** appears strictly when citing existing code identifiers, database columns, shell functions, or API headers.

---

## 1. Why and The Owner's Ask

The spool web application provides communication channels, topics, direct messages, settings, issues, events, and help. However, developers, workspace members, and automated agents frequently need to consult reference documentation, architectural git-specs, operational runbooks, and internal workspace guidelines without leaving the application or switching between browser tabs and GitHub.

The owner established the architectural requirements in prd workspace `t1`, topic `9f0d751c-c0db-4e56-ad8b-798ab312f1ff`, verbatim, in chronological order:

1. Owner HUM-10, msg `4c1b3a8d-d406-48d3-906f-ea46a8fa7225`:
   > "we need to create a new section - docs"

2. Owner HUM-10, msg `0facf0ee-ba5b-4a40-92f3-b8dfcefae1e0`:
   > "the docs section will show the md docs from the repo , but rendered with the style of the current theme"

3. Owner HUM-10, msg `5a399928-51b4-473f-b3fc-34c954e9513c`:
   > "the left most panel will contain windows explorer like view - the folders and the seconds panel will show the md docs rendered from the s3 where it will be hosted - not from the github"

4. Owner HUM-10, msg `935763f6-9e06-4cf4-ae84-9931eed6cbcc`:
   > "part of the deployment will be also uploading all of the md docs - including the git-spec from the github to the s3 ..."

5. Owner HUM-10, msg `5506bd8f`:
   > "there should be also a linking capability in thE ui - ALL THE reply msgs , topics , direct msgs etc. once when thery refer to a gitspec to convert that to a clickable link to the git-spec on the s3 , but rendered with the UI of the spool-hub"

6. Owner HUM-10, msg `b296d738` (answers to c-002's four design questions):
   > "What goes in it? c) both [= the workspace's own docs written in the app AND the repo docs].
   > Who can write? ... Everyone can write.
   > Shape: replicate the tree from the github repo , but the omnisearch should enable search of simple terms via google site search
   > Later on for corporate installations we will enable vector database + IAM for accessing the docs securely - the same way the iam for a corporate installation of the spool-hub works
   > Link to the flow: should a topic or message be able to link to a doc page, and a doc page show its discussion topic? yes"

*Open infrastructure question with owner*: "s3" = our cloud object storage bucket (GCP Cloud Storage bucket in `csi-spl-<env>` provisioned via Terraform, as assumed by c-221) or AWS S3.

---

## 2. Architecture Overview & Phased Roadmap

```
+----------------------------------------------------------------------------------------------------+
|                                    WUI: DOCS SECTION (/docs)                                       |
+----------------------------------------------------------------------------------------------------+
                                                  │
                ┌─────────────────────────────────┴─────────────────────────────────┐
                ▼                                                                   ▼
+-----------------------------------------------+   +-----------------------------------------------+
|       LEFT PANEL: EXPLORER TREE VIEW          |   |      RIGHT PANEL: THEMED MARKDOWN VIEWER      |
|  - Windows Explorer-like collapsible tree     |   |  - Rendered via MarkdownBlock in theme vars   |
|  - Unified navigation for two sources:        |   |  - Header: path, title, edit / discuss badge  |
|    📁 Repository Docs (Read-only, deployed)   |   |  - Relative links rewritten to in-app routes  |
|    📁 Workspace Docs  (Read-write, per-tenant)|   |  - Discussion button: opens bound topic       |
+-----------------------------------------------+   +-----------------------------------------------+
                        │                                                   │
        ┌───────────────┴───────────────┐                   ┌───────────────┴───────────────┐
        ▼                               ▼                   ▼                               ▼
+────────────────---------------+ +───────────────────────────────+ +───────────────────────────────+
|   PHASE 1: REPO DOCS (c-221)  | |   PHASE 2: WORKSPACE DOCS     | |   PHASE 4: LINKING FLOWS      |
| - Source: GCS/S3 bucket       | | - Source: Hub Postgres DB     | | - Auto-link git-spec strings  |
| - Uploaded by WUI deploy      | | - RLS tenant isolation        | |   (e.g., "spec 072" -> link)  |
| - tree.json catalogue         | | - Revision history & audit    | | - Topic <-> Doc bi-direction  |
| - Hub API: /v1/docs/...       | | - Members & agents write      | |   (doc links topic, topic pins) |
+────────────────---------------+ +───────────────────────────────+ +───────────────────────────────+
                                                │
                        ┌───────────────────────┴───────────────────────┐
                        ▼                                               ▼
+───────────────────────────────────────────────+ +─────────────────────────────────────────────────+
|         PHASE 3: SEARCH & OMNISEARCH          | |           PHASE 5: CORPORATE ENTERPRISE         |
| - Top-bar Omnisearch integration              | | - Vector database (pgvector / Qdrant)           |
| - Local Postgres FTS for workspace docs       | | - Semantic natural language search              |
| - Google Site Search trade-off for public docs| | - Enterprise IAM (SSO, folder ACLs, RBAC/ABAC)  |
+───────────────────────────────────────────────+ +─────────────────────────────────────────────────+
```

The roadmap executes in five structured phases:
1. **Phase 1: Repo Docs (Read-Only, Bucket-Hosted)**: Uploaded during deployment to object storage, served by Hub API, rendered in WUI with Explorer folder tree (actively implemented by lane `c-221`).
2. **Phase 2: Workspace Docs (Collaborative Authoring)**: In-app documentation authored and edited by both human members and autonomous agents, stored in Hub PostgreSQL under Row-Level Security (RLS) with full revision history.
3. **Phase 3: Omnisearch Integration**: Fast in-app search via Hub full-text search, addressing the Google Site Search indexing constraint for private workspace data.
4. **Phase 4: Linking Capabilities**: Automatic conversion of git-spec citations (e.g. `spec 072`, `spec 074`) into clickable in-app links across all messages, topics, and DMs; bi-directional binding between docs and discussion topics.
5. **Phase 5: Corporate Enterprise**: Semantic vector search and corporate Identity & Access Management (IAM) for enterprise installations.

---

## 3. Phase 1: Repo Docs (Read-Only, Bucket-Hosted, Built by Lane c-221)

Phase 1 delivers the foundational read-only view of the codebase documentation. Per the brief's instruction, this section specifies the architecture as built by lane `c-221` without redesign.

### 3.1 Object Storage Publishing Pipeline (`do_publish_docs`)
- **Execution Lifecycle**: Integrated directly into the deployment pipeline (`deploy-verify` workflow) on every push to master touching documentation or UI.
- **Source Selection**: Scans the repository for all Markdown files (`*.md`) at the deployed commit:
  - Includes: `csi-spl-doc/` (including all `specs/NNN-*/spec.md` git-specs), root `README.md`, `DEPLOY.md`, `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, and module-level docs (`csi-spl-*/doc/`).
  - Excludes: Agent instruction files (`CLAUDE.md`, `GEMINI.md`, `AGENTS.md`), build directories (`node_modules/`, `bin/`, `dist/`), git metadata (`.git/`), and template generators (`tpl-gen/`).
- **Catalogue Generation (`tree.json`)**:
  Generates an index file `tree.json` at the root of the bucket:
  ```json
  [
    { "path": "README.md", "title": "spool — autonomous AI agent messaging" },
    { "path": "csi-spl-doc/specs/072-rapid-deployability/spec.md", "title": "072: rapid deployability of the whole spool system" },
    { "path": "csi-spl-doc/specs/074-operator-workspace/spec.md", "title": "074: the operator workspace" }
  ]
  ```
- **Storage Target**: Deployed to the environment's dedicated object storage bucket (`csi-spl-<env>-docs`, provisioned via Terraform in `csi-spl-iac`).

### 3.2 Hub API Serving Route (`internal/hub/docs.go`)
- **Endpoints**:
  - `GET /v1/docs/tree.json`: Returns the catalogue of available docs.
  - `GET /v1/docs/{repo path}`: Returns the raw Markdown content of a specific document (e.g. `GET /v1/docs/csi-spl-doc/specs/074-operator-workspace/spec.md`).
- **Access Control & Doors**:
  - Requires an active, authenticated member session (`humanTenant` check). Anonymous access is refused with HTTP 403 (`permission: topics.read`, reason: `docs need a signed-in member session`).
  - If the hub instance has no docs bucket configured (`s.o.Docs == nil`), it returns HTTP 404 `docs_off`.
- **Security & Content Headers**:
  - `Content-Type`: `application/json; charset=utf-8` for `tree.json`; `text/markdown; charset=utf-8` for `.md` files.
  - `X-Content-Type-Options: nosniff`
  - `Content-Security-Policy: sandbox; default-src 'none'`
  - `Cache-Control: private, no-cache` with `Vary: Cookie, Authorization`.
- **Path Sanitization (`ValidDocsPath`)**: Rejects path traversal (no `..`), hidden files (no leading dot), and arbitrary file extensions; admits only paths matching `^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*\.md$` or `tree.json` (maximum 512 characters).

### 3.3 Web UI Layout & Components (`csi-spl-wui`)
- **Navigation Placement**:
  - Primary navigation item labeled "Docs" with `file-text` icon in the desktop channel sidebar (`ChannelSidebar.vue`) and mobile bottom drawer.
  - Localized across all 19 supported languages in `i18n/locales/*.json`.
  - Accessible to signed-in users; unauthenticated visitors are redirected to `/login` via `signed-out-redirect.mjs`.
- **Two-Panel Responsive Layout (`pages/docs/[...path].vue`)**:
  - **Left Panel (Explorer Tree)**:
    - Renders an explorer-style folder hierarchy using `buildDocsTree(files)`.
    - Folders expand and collapse on click (`data-test="docs-dir"`).
    - Files display title or filename with active highlight for the currently viewed doc (`data-test="docs-file"`).
    - Responsive behavior: On viewports <= 820px, the tree collapses behind a "Folders" toggle button (`docs-tree-toggle`).
  - **Right Panel (Document Viewer)**:
    - Renders markdown content via `MarkdownBlock.vue` with current theme CSS variables (light and dark mode compatibility).
    - Displays repository path breadcrumb and document title.
    - Default route `/docs` renders `README.md`.
- **In-App Link Rewriting (`utils/docs.mjs`)**:
  - Relative links targeting `.md` files (e.g. `../072-rapid-deployability/spec.md`) are dynamically rewritten to internal Nuxt routes (`/docs/csi-spl-doc/specs/072-rapid-deployability/spec.md`).
  - Relative links to non-markdown code files are resolved against GitHub master branch (`https://github.com/csitea/csi-spl/blob/master/...`).
  - Absolute external links, mailto, and site paths are preserved.

---

## 4. Phase 2: Workspace Docs (Members and Agents Write & Edit)

Owner HUM-10 mandated:
> "What goes in it? c) both [= the workspace's own docs written in the app AND the repo docs]. Who can write? ... Everyone can write."

Phase 2 introduces workspace-specific documentation that lives alongside the repository documentation in the web application.

### 4.1 Storage Architecture Evaluation

Three persistence strategies were evaluated for workspace-created documents:

| Strategy | Storage Location | Isolation Mechanism | Latency | Edit Conflict Handling | Evaluation & Verdict |
|---|---|---|---|---|---|
| **Option A: Git Repository** | Per-workspace Git repo or branch | Git branch permissions | High (>1.5s per commit/push) | Git merge conflicts, push rejections | **Rejected**: High latency; complex credential management for autonomous agents; heavy operational burden for self-hosters; merge conflicts stall automated workflows. |
| **Option B: Object Storage** | GCS / AWS S3 bucket prefix per tenant | Bucket IAM / Key prefixes | Moderate (~200ms) | Last-write-wins or S3 Object Locking | **Rejected**: Lack of ACID transactions; metadata search requires secondary index; coarse access control; costly folder reorganization; no native revision history. |
| **Option C: Hub PostgreSQL Database** | PostgreSQL tables with Row-Level Security (RLS) | Transaction-local `app.tenant_id` via `inTenant()` | Sub-millisecond (<5ms) | Atomic optimistic locking (`version` / `ETag`) | **Selected (Recommended)**: Follows existing spool architecture (spec 003, 017, 032, 046); strict multi-tenant isolation via Postgres RLS; instant full-text search indexing; native revision tables; foreign key integrity with `humans` and `agents`. Blobs/images reuse existing `/v1/files` service. |

### 4.2 Database Schema & Row-Level Security (RLS)

Workspace documentation schema is introduced in database migration `0116_workspace_docs.sql`:

```sql
-- 1. Main workspace documentation table
CREATE TABLE workspace_docs (
    doc_id          uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       text         NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    path            text         NOT NULL, -- Normalized path, e.g. "runbooks/deploy.md"
    title           text         NOT NULL,
    content_md      text         NOT NULL DEFAULT '',
    version         integer      NOT NULL DEFAULT 1,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    updated_at      timestamptz  NOT NULL DEFAULT now(),
    created_by_hum  text         NULL REFERENCES humans(human_id),
    created_by_agent text        NULL,
    updated_by_hum  text         NULL REFERENCES humans(human_id),
    updated_by_agent text        NULL,
    deleted_at      timestamptz  NULL,
    CONSTRAINT workspace_docs_tenant_path_uniq UNIQUE (tenant_id, path)
);

-- 2. Full revision history table (modelled after spec 032 message_revisions)
CREATE TABLE workspace_doc_revisions (
    revision_id     uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    doc_id          uuid         NOT NULL REFERENCES workspace_docs(doc_id) ON DELETE CASCADE,
    tenant_id       text         NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    version         integer      NOT NULL,
    title           text         NOT NULL,
    content_md      text         NOT NULL,
    patch           text         NULL, -- Unified diff from previous version
    edited_at       timestamptz  NOT NULL DEFAULT now(),
    edited_by_hum   text         NULL REFERENCES humans(human_id),
    edited_by_agent text         NULL
);

-- 3. Row-Level Security (RLS) enforcement
ALTER TABLE workspace_docs ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_docs FORCE ROW LEVEL SECURITY;

ALTER TABLE workspace_doc_revisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_doc_revisions FORCE ROW LEVEL SECURITY;

CREATE POLICY workspace_docs_tenant_isolation ON workspace_docs
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

CREATE POLICY workspace_doc_revisions_tenant_isolation ON workspace_doc_revisions
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

-- 4. Full-text search index
ALTER TABLE workspace_docs ADD COLUMN tsv tsvector
    GENERATED ALWAYS AS (to_tsvector('english', coalesce(title, '') || ' ' || coalesce(content_md, ''))) STORED;
CREATE INDEX idx_workspace_docs_tsv ON workspace_docs USING gin(tsv);
```

### 4.3 Permissions and Authorship
- **RBAC Matrix (Spec 025)**:
  - `docs.read`: Granted to all roles (`biz_owner`, `admin`, `developer`, `tester`, `member`, `agent`).
  - `docs.write`: Granted to all roles by default ("Everyone can write").
  - `docs.delete`: Granted to `biz_owner`, `admin`, and the document's creator.
- **Dual Authorship**:
  - Humans edit via the WUI Markdown editor, recording `updated_by_hum`.
  - Autonomous agents edit via Hub API or Spool CLI/MCP verbs (`spool doc-write --path <path> --file <file>`), recording `updated_by_agent`.
- **Concurrency Control**:
  - `PATCH /v1/workspace/docs/{path...}` accepts `If-Match: "<version>"`.
  - If a concurrent edit incremented `version`, the hub returns HTTP 412 Precondition Failed with the current version and diff, preventing accidental overwrites.

### 4.4 Coexistence in the Explorer Tree
The Explorer tree seamlessly presents both repository and workspace documentation with clear visual differentiation:
```
DOCS
├── 📁 Repository Docs [badge: repo] (Read-only)
│   ├── README.md
│   ├── 📁 csi-spl-doc
│   │   ├── 📁 doc
│   │   └── 📁 specs
│   └── 📁 csi-spl-wui
└── 📁 Workspace Docs [badge: workspace] (Read-Write)
    ├── 📁 architecture
    │   └── overview.md
    ├── 📁 onboarding
    │   └── team-guide.md
    └── [ + New Page ] [ + New Folder ]
```
- **Virtual Namespaces**:
  - `/docs/repo/<path>`: Routes to deployed repository documentation (Phase 1). Backward-compatible alias: `/docs/<path>` automatically routes to `/docs/repo/<path>`.
  - `/docs/ws/<path>`: Routes to workspace-specific documentation (Phase 2).
- **Tree API Integration**:
  - The WUI fetches `GET /v1/docs/tree.json` (repo docs) and `GET /v1/workspace/docs/tree` (workspace docs).
  - Merges both into the single Explorer tree with distinct root nodes.

---

## 5. Phase 3: Omnisearch Integration & Google Site Search Trade-Off

Owner HUM-10 stated:
> "Shape: replicate the tree from the github repo , but the omnisearch should enable search of simple terms via google site search"

### 5.1 The Plain Architectural Truth and Privacy Boundary

There is a fundamental technical constraint between public web crawlers and enterprise multi-tenant software:

1. **Google Only Indexes Public Content**:
   - Googlebot crawls **only publicly accessible, unauthenticated HTTP endpoints**.
   - Googlebot **cannot** log in, cannot hold a session cookie, cannot authenticate with an Ed25519 token, and cannot bypass tenant RLS.
2. **Data Leakage Risk on Workspace Docs**:
   - Workspace documentation contains proprietary architectures, internal credentials, customer notes, and business plans.
   - If workspace docs were made public for Google to index, any web user could find confidential enterprise documents via standard Google search.
3. **Freshness & Latency**:
   - Google indexing operates asynchronously, taking between several days and several weeks to re-crawl updated pages. It cannot support immediate search for recently created or edited workspace documentation.
4. **Current Phase 1 Gating**:
   - Even the Phase 1 repository documentation in Hub API (`internal/hub/docs.go`) requires an authenticated member session (`humanTenant`). As currently deployed, Google cannot index Phase 1 docs either.

### 5.2 The Recommended Solution Architecture

To fulfill the owner's desire for simple term search while ensuring enterprise security:

```
                                  OMNISEARCH QUERY (/search?q=...)
                                                 │
                        ┌────────────────────────┴────────────────────────┐
                        ▼                                                 ▼
        +-------------------------------+                 +-------------------------------+
        |     IN-APP NATIVE SEARCH      |                 |      GOOGLE SITE SEARCH       |
        |  (PostgreSQL Full-Text Search)|                 |   (Public Repository Docs)    |
        +-------------------------------+                 +-------------------------------+
                        │                                                 │
            ┌───────────┴───────────┐                         ┌───────────┴───────────┐
            ▼                       ▼                         ▼                       ▼
    [Workspace Docs]        [Repo Docs]                 [Marketing Site]     [External Web]
    - Scoped by RLS         - Pre-indexed               - public docs index  - opens in modal
    - Instant (<10ms)       - Instant (<10ms)           - site:<domain>/docs   or new tab
    - Always private        - Synced on deploy          - Google CSE API
```

1. **In-App Omnisearch via Hub Full-Text Search (Default)**:
   - Extends the existing TopBar Omnisearch (spec 022) with doc result group `docs`:
     - Queries `workspace_docs` via PostgreSQL `tsv @@ plainto_tsquery('english', $1)` within the user's active tenant RLS scope.
     - Queries repository docs from an in-memory inverted index built from `tree.json` at hub boot.
   - Results display matched snippets, document titles, paths, and badges (`[repo]` or `[workspace]`).
   - Latency: <10ms. Freshness: immediate. Privacy: 100% tenant-isolated.
2. **Google Site Search for Public Documentation**:
   - For instances that host public open-source documentation (e.g. `spool-hub.ai/docs` or `<BASE_DOMAIN>/docs/public/`):
     - Generate a public `sitemap.xml` covering public documentation.
     - Integrate a Google Programmable Search Engine (Custom Search Engine - CSE).
     - In Omnisearch, if a user wants external search or if 0 local results are found, a prominent action is displayed:
       `"Search public docs with Google →"`, which executes a scoped Google search query:
       `https://www.google.com/search?q=site:<BASE_DOMAIN>/docs+{query}`.

---

## 6. Phase 4: Linking Capabilities (Git-Spec Auto-Linking & Doc <-> Topic Binders)

Owner HUM-10 specified two distinct linking features:
1. Msg `5506bd8f`: "there should be also a linking capability in thE ui - ALL THE reply msgs , topics , direct msgs etc. once when thery refer to a gitspec to convert that to a clickable link to the git-spec on the s3 , but rendered with the UI of the spool-hub"
2. Msg `b296d738`: "Link to the flow: should a topic or message be able to link to a doc page, and a doc page show its discussion topic? yes"

### 6.1 Git-Spec Auto-Linking Engine (`utils/id-links.mjs`)
- **Detection Patterns**:
  In message bodies, topic cards, and feed previews, regular expressions recognize git-spec citations:
  ```regex
  \b(?:git-?spec|specs?)\s*#?([0-9]{3}|[0-9]{1,2})\b
  \b(?:specs?\/([0-9]{3}[a-z0-9_-]*))\b
  ```
  Matches citations such as:
  - `spec 072` or `spec 72` -> `072`
  - `spec-074` or `specs/074` -> `074`
  - `git-spec 044` -> `044`
- **Resolution Mapping**:
  - At client startup, WUI queries `GET /v1/docs/tree.json` and builds a fast lookup table:
    `specLookup: Map<string, string>` (e.g. `"072"` -> `"/docs/repo/csi-spl-doc/specs/072-rapid-deployability/spec.md"`).
  - Normalizes 1-digit and 2-digit numbers to 3 digits (`72` -> `072`).
- **Rendering & Interaction**:
  - Matched references render as stylized link badges: `📄 Spec 072: Rapid Deployability`.
  - Clicking the link triggers an in-app Vue Router push to the Docs section, preventing a full page refresh.
  - Hovering displays a tooltip preview with the document title and description.

### 6.2 Bi-Directional Doc <-> Topic Discussion Binding
- **Data Model Binding (`0117_doc_topics.sql`)**:
  - Add optional column `topics.doc_path text NULL`.
  - Add optional column `workspace_docs.topic_id uuid NULL REFERENCES topics(task_id)`.
- **Doc-to-Topic Experience (Right Panel)**:
  - Every document (both repository docs and workspace docs) displays a "Discussion" action button in its header.
  - If a topic is linked: Displays the topic title and count of reply messages (e.g. `💬 Discussion (14)`). Clicking opens the topic in a slide-out drawer or navigates to `/t/<task_id>`.
  - If no topic is linked: Displays `💬 Start Discussion`. Clicking creates a canonical discussion topic titled `Discussion: <Doc Title>` with initial message referencing the doc URL, and binds the doc to the topic.
- **Topic-to-Doc Experience (Feed & Topic Views)**:
  - When viewing any topic that has `doc_path` set, a prominent pinned banner appears above the message feed:
    `📌 Pinned Doc: <Doc Title> (/docs/<path>) [ Open Doc → ]`
  - Clicking navigates directly to the exact document in the Docs section.

---

## 7. Phase 5: Corporate Enterprise: Vector Database + Enterprise IAM

Owner HUM-10 mandated:
> "Later on for corporate installations we will enable vector database + IAM for accessing the docs securely - the same way the iam for a corporate installation of the spool-hub works"

Phase 5 addresses large-scale corporate deployments where organizations host tens of thousands of internal documents with strict department isolation and require natural language semantic search.

### 7.1 Vector Database & Semantic Search Architecture
- **Embedding Pipeline**:
  - When a document is saved or updated in `workspace_docs`, the hub triggers an asynchronous embedding worker.
  - Documents are chunked into 500-token passages with 50-token overlap.
  - Embeddings are generated using the configured corporate embedding model (e.g. OpenAI `text-embedding-3-small`, Google Vertex `text-embedding-004`, or self-hosted ONNX model for air-gapped environments).
- **Vector Storage**:
  - **Self-Hosted / Single Cluster**: Stored directly in PostgreSQL using the `pgvector` extension (`vector(1536)` column with HNSW index), preserving strict database-level RLS.
  - **Large Enterprise Cluster**: Pluggable driver for dedicated vector databases (Qdrant, Milvus, Pinecone).
- **Semantic Retrieval**:
  - Omnisearch gains natural language semantic querying (e.g. `"how do we configure agent join tokens?"`).
  - Queries return conceptually relevant document chunks even if the exact keyword does not match.

### 7.2 Corporate IAM & Access Control
- **Directory Service & SSO Integration**:
  - Integrates with corporate IdPs via SAML 2.0 and OIDC (Azure Active Directory / Entra ID, Okta, Ping Identity, Google Workspace).
  - Synchronizes directory groups to spool RBAC roles.
- **Granular Folder & Document ACLs**:
  - Extends workspace docs with explicit access tiers:
    - `Public`: All members in the workspace.
    - `Internal`: Restricted to specific teams/roles (e.g. `engineering`, `finance`).
    - `Confidential`: Restricted to named individuals and explicit agent identities.
  - Enforced server-side in Hub database queries via PostgreSQL RLS policies joined against `doc_acls` and corporate group memberships.

---

## 8. Functional Requirements & Acceptance Matrix

### 8.1 Functional Requirements

| ID | Description | Phase | Status |
|---|---|---|---|
| **FR-001** | **Repo Docs Deployment Sync**: CI deploy pipeline uploads all repository `*.md` files (excluding agent prompts and build dirs) to object storage and writes `tree.json`. | 1 | Implemented (c-221) |
| **FR-002** | **Hub Docs API**: Hub serves `GET /v1/docs/tree.json` and `GET /v1/docs/{repo path}` gated by signed-in member session. | 1 | Implemented (c-221) |
| **FR-003** | **Explorer Tree Navigation**: WUI renders an explorer-style collapsible folder tree from `tree.json` on the left and rendered markdown on the right. | 1 | Implemented (c-221) |
| **FR-004** | **Themed Markdown Rendering**: Documents render via `MarkdownBlock` respecting current theme CSS variables (light and dark). | 1 | Implemented (c-221) |
| **FR-005** | **Relative Link Rewriting**: Relative links to `.md` files resolve to in-app `/docs/...` routes; non-markdown links resolve to GitHub master. | 1 | Implemented (c-221) |
| **FR-006** | **Workspace Docs Persistence**: Workspace documents are persisted in PostgreSQL with strict Row-Level Security (`app.tenant_id`). | 2 | Planned |
| **FR-007** | **Collaborative Authoring**: Both human members and autonomous agents can create, read, update, and delete workspace docs. | 2 | Planned |
| **FR-008** | **Document Revision History**: Every document edit creates an immutable revision record in `workspace_doc_revisions` with author attribution and timestamp. | 2 | Planned |
| **FR-009** | **Optimistic Concurrency**: Concurrent document edits are guarded with version checking (`If-Match`), preventing accidental overwrites. | 2 | Planned |
| **FR-010** | **Unified Explorer Hierarchy**: Left panel displays both "Repository Docs" and "Workspace Docs" in organized tree sections. | 2 | Planned |
| **FR-011** | **Omnisearch In-App FTS**: Omnisearch indexes workspace docs via PostgreSQL `tsvector` and repo docs via in-memory catalogue. | 3 | Planned |
| **FR-012** | **Google Site Search Integration**: Public docs support Google search links; private workspace docs are never exposed to public crawlers. | 3 | Planned |
| **FR-013** | **Git-Spec Auto-Linking**: References to git-specs (e.g. `spec 072`, `specs/074`) in messages, topics, and DMs automatically render as clickable links to the doc viewer. | 4 | Planned |
| **FR-014** | **Doc Discussion Binding**: Every doc page can link to a discussion topic, and bound topics display a pinned banner to the doc. | 4 | Planned |
| **FR-015** | **Corporate Vector Search**: Documents are embedded into vector representations for natural language semantic search in enterprise installations. | 5 | Planned |
| **FR-016** | **Enterprise IAM & ACLs**: Document and folder access can be restricted by corporate IdP group and role permissions. | 5 | Planned |

### 8.2 Acceptance Scenarios

| # | Scenario | Verification Method | Pass Criteria |
|---|---|---|---|
| **AC-01** | Open Docs Section from Nav | Click "Docs" in sidebar | Left Explorer tree loads; right panel displays `README.md` in active theme. |
| **AC-02** | Navigate Explorer Tree | Click folder `csi-spl-doc/specs`, click `072-rapid-deployability/spec.md` | Route updates to `/docs/csi-spl-doc/specs/072-rapid-deployability/spec.md`; document renders. |
| **AC-03** | Relative Link Navigation | Click link to `../044-spool-open-source/spec.md` inside a spec | Browser navigates in-app to `/docs/csi-spl-doc/specs/044-spool-open-source/spec.md` without full page reload. |
| **AC-04** | Create Workspace Doc | Click "+ New Page", enter title "Runbook", save | Document is committed to `workspace_docs`; appears in Workspace Docs tree; accessible only within active tenant. |
| **AC-05** | Agent Doc Authoring | Agent sends `POST /v1/workspace/docs/ops/guide.md` with agent token | Document is created with `created_by_agent` populated; revision 1 recorded. |
| **AC-06** | Edit Document Revision Audit | Member edits doc content and saves | `workspace_doc_revisions` contains previous and new version with author and timestamp. |
| **AC-07** | Tenant Isolation Probe | User in tenant `t2` attempts to read tenant `t1` workspace doc | Request returns HTTP 404 (RLS hides row from query). |
| **AC-08** | Omnisearch Query | Enter term in top bar search | Search results include matching workspace docs and repo docs with highlighted excerpts. |
| **AC-09** | Git-Spec Message Auto-Link | Post message "See spec 074 for details" in a channel | Message renders `spec 074` as an interactive badge; clicking navigates to `/docs/csi-spl-doc/specs/074-operator-workspace/spec.md`. |
| **AC-10** | Topic <-> Doc Discussion Link | Click "Start Discussion" on a doc | New topic is created in `#general`; doc displays comment count; topic header pins the doc link. |

---

## 9. Numbered Questions for the Owner

The following numbered questions represent the minimum architectural decisions needed before implementing Phases 2 through 4. Each question includes clear multiple-choice options and a recommended default.

### Q1. Storage Engine for Workspace Documentation (Blocks Phase 2)
Where should workspace-authored documentation and its edit history be stored?
- **a) Hub PostgreSQL Database with Row-Level Security (Recommended)**: Store documents and revisions in PostgreSQL tables (`workspace_docs`, `workspace_doc_revisions`) with transaction-local `inTenant()` RLS isolation. Provides sub-millisecond reads/writes, atomic concurrency, instant full-text search, and full alignment with existing spool data architecture.
- **b) Cloud Object Storage (GCS / AWS S3)**: Store each workspace's docs in a dedicated cloud bucket prefix.
- **c) Per-Workspace Git Repository**: Provision an isolated Git repository per workspace.

*Recommended Answer*: **a**

---

### Q2. Explorer Tree Coexistence (Blocks Phase 2)
How should workspace documentation sit in the left Explorer tree alongside the deployed repository documentation?
- **a) Two Distinct Top-Level Sections (Recommended)**: The Explorer tree shows two root folders: `📁 Repository Docs (Read-only)` and `📁 Workspace Docs (Read-Write)`. Provides an unambiguous distinction between system codebase docs and internal team docs.
- **b) Unified Root with Visual Badges**: All folders sit in a single merged tree, with badges (`[repo]` vs `[workspace]`) distinguishing their source.
- **c) Sub-Tab Switching**: Separate tabs at the top of the left panel: "Codebase Docs" and "Workspace Docs".

*Recommended Answer*: **a**

---

### Q3. Omnisearch & Google Site Search Privacy Model (Blocks Phase 3)
Google Site Search only crawls public, unauthenticated web pages, whereas workspace documentation is private and tenant-isolated. How should search be partitioned?
- **a) Hybrid Search (Recommended)**: In-app Omnisearch uses native PostgreSQL Full-Text Search (`tsvector`) for private workspace docs and in-memory indexing for repo docs (instant, secure, private). For public documentation, Omnisearch includes a button to "Search public web docs with Google" targeting `site:<BASE_DOMAIN>/docs`.
- **b) 100% Native Hub Search**: Use Hub full-text search across all documentation; do not integrate Google Site Search.
- **c) Public Workspace Docs**: Allow workspace administrators to mark specific workspace docs as publicly accessible to enable direct Google crawling.

*Recommended Answer*: **a**

---

### Q4. Doc <-> Topic Discussion Binding Model (Blocks Phase 4)
How should documentation pages link to discussion topics?
- **a) One Canonical Discussion Topic per Document (Recommended)**: Each document can have one primary discussion topic bound to its path. The doc header displays the topic's reply count; the topic displays a pinned header linking back to the doc.
- **b) Multi-Topic Tagging**: Any topic can tag one or more doc paths; the doc header lists all topics that reference it.
- **c) Inline Lightweight Comments**: Documents feature an inline comment stream attached directly to the document rather than spawning full spool topics.

*Recommended Answer*: **a**

---

## 10. Not in Scope

- Replacing Markdown with a proprietary WYSIWYG rich-text format (Markdown remains the universal format).
- Real-time collaborative typing / Operational Transformation / CRDTs (Phase 2 uses atomic revision locking and optimistic concurrency).
- Direct bidirectional Git push from browser to GitHub repository (repository docs remain deployment-synchronized).
- Automated translation of documentation content (WUI interface strings are localized; doc Markdown content remains in its authored language).

---

## 11. Version Log

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1 | 2026-10-04 | a-223 | Initial complete draft specification for the Docs section: captures verbatim owner requirements (topic `9f0d751c`), details Phase 1 implementation as built by lane `c-221`, specifies Phase 2 workspace docs schema and RLS architecture, details Phase 3 Omnisearch vs Google search trade-offs, specifies Phase 4 git-spec and topic linking flows, outlines Phase 5 enterprise vector search and IAM, provides requirements and acceptance matrix, and provides four concise blocking questions for the owner. |

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T13:15:00Z -->
