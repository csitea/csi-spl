# 075: the Docs section (repo and workspace markdown, explorer tree, search, links)

**Feature ID**: `075-docs-section` · **Milestone**: M3 · **Status**: Draft (v0.2.0)
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

`<BASE_DOMAIN>`, `<tenant>`, `<workspace_id>`, `<human_id>`, `<org>`, `<app>`, `<env>`, and `<run-time>.csitea.net` are placeholders. No estate value appears as a literal to copy.
Per the owner's wording rule, this specification uses the term **workspace** throughout the narrative, requirements, user stories, and acceptance scenarios; the term **tenant** appears strictly when citing existing code identifiers, database columns, shell functions, terraform resources, or API headers.

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

7. Owner HUM-10, msg `9431127d` (decision on Phase 2 storage and question Q1):
   > "create a new s3 bucket for the docs only per tenant"

8. Owner HUM-10, prd t1 topic `aa35699c`, msg `b7c66282` (naming input for per-workspace buckets):
   > "the buckets' names could be similar to the DNSs"

### Cloud-Layer Decisions (Owner Resolved)
- **Object Storage Technology**: The owner's references to "s3" are resolved as **Google Cloud Storage (GCS)** buckets, maintaining the GCP-default cloud layer across `csi-spl-iac` and the deployment architecture.
- **Phase 1 vs Phase 2 Bucket Separation**:
  - **Phase 1 (Repo Docs)**: ONE bucket per environment (`csi-spl-<env>-docs`, provisioned by terraform step `051-gcs-docs`), storing deployed repository Markdown and `tree.json`.
  - **Phase 2 (Workspace Docs)**: ONE dedicated GCS bucket **PER WORKSPACE** (per tenant), storing workspace-created documentation, workspace `tree.json`, and edit history.
  - **Content Scope**: Dedicated strictly to **docs only** (markdown files, document hierarchy, and version histories). Binary file attachments and user uploads continue to use the separate files bucket (`050-gcs-files`) via `/v1/files/`.

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
+───────────────────────────────+ +───────────────────────────────+ +───────────────────────────────+
|   PHASE 1: REPO DOCS (c-221)  | |   PHASE 2: WORKSPACE DOCS     | |   PHASE 4: LINKING FLOWS      |
| - Single GCS bucket per env   | | - GCS BUCKET PER WORKSPACE    | | - Auto-link git-spec strings  |
|   (csi-spl-<env>-docs)        | |   (csi-spl-<env>-docs-<tenant>| |   (e.g., "spec 072" -> link)  |
| - Uploaded by WUI deploy      | | - Docs only (md + .history)   | | - Topic <-> Doc bi-direction  |
| - tree.json catalogue         | | - Hub SA mediated access      | |   (doc links topic, topic pins) |
| - Hub API: /v1/docs/...       | | - Members & agents write      | |                               |
+───────────────────────────────+ +───────────────────────────────+ +───────────────────────────────+
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
1. **Phase 1: Repo Docs (Read-Only, Bucket-Hosted)**: Uploaded during deployment to a single environment GCS bucket (`051-gcs-docs`), served by Hub API, rendered in WUI with Explorer folder tree (actively implemented by lane `c-221`).
2. **Phase 2: Workspace Docs (Per-Workspace GCS Bucket, Collaborative Authoring)**: Workspace documentation authored and edited by human members and autonomous agents, stored in a dedicated GCS bucket per workspace (`csi-spl-<env>-docs-<tenant>`), docs only, accessed strictly via the Hub runtime service account with complete tenant isolation.
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
- **Storage Target**: Deployed to the environment's dedicated object storage bucket (`csi-spl-<env>-docs`, provisioned via Terraform step `051-gcs-docs` in `csi-spl-iac`).

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

## 4. Phase 2: Workspace Docs (Per-Workspace GCS Bucket, Members & Agents)

Owner HUM-10 mandated:
> Msg `b296d738`: "What goes in it? c) both [= the workspace's own docs written in the app AND the repo docs]. Who can write? ... Everyone can write."
> Msg `9431127d`: "create a new s3 bucket for the docs only per tenant"

Per the owner's decision, Phase 2 implements a **dedicated Google Cloud Storage bucket per workspace** for all workspace-authored documentation and its revision history.

### 4.1 Bucket Naming & Convention

Owner HUM-10 provided naming guidance (msg `b7c66282` in `aa35699c`): *"the buckets' names could be similar to the DNSs"*.

To align with Google Cloud Storage operational requirements and the broader spool architecture:
1. **GCS Dotted Domain Verification Constraint**: In Google Cloud Storage, any bucket name containing dots (such as `t1.spool-hub.ai` or `<workspace>.docs.<BASE_DOMAIN>`) is categorized as a domain name and requires domain ownership verification in Google Search Console for the deploying GCP service account. This requirement introduces manual administrative steps, prevents automated zero-touch tenant provisioning, and creates failure points in multi-tenant cloud operations.
2. **Retirement of Per-Workspace DNS Subdomains (Spec 074)**: Per spec 074 §1 (owner decisions D2 and D3), legacy per-workspace vanity subdomains (`<workspace>.<BASE_DOMAIN>`) are retired within a 30-day grace period in favor of a single unified apex DNS entry point (`https://<BASE_DOMAIN>/w/<workspace>/`). Deriving bucket names from deprecated per-workspace vanity DNS hostnames would couple storage to an expiring routing scheme.
3. **Settled Dot-Free Host-Derived Standard**:
   The bucket naming derives from the workspace host slug in a **dot-free format**:

   $$\text{Bucket Name} = \langle\text{workspace\_slug}\rangle\text{-docs-}\langle\text{env}\rangle \quad\text{or}\quad \langle\text{org}\rangle\text{-}\langle\text{app}\rangle\text{-}\langle\text{env}\rangle\text{-docs-}\langle\text{workspace\_slug}\rangle$$

   In `csi-spl-cnf`:
   - `${SPL_ORG_APP}-${ENV}-docs-${WORKSPACE_SLUG}` (or `${WORKSPACE_SLUG}-docs-${ENV}`)
   - Example in development for workspace `t1`: `csi-spl-dev-docs-t1` (or `t1-docs-dev`)
   - Example in production for workspace `engineering`: `csi-spl-prd-docs-engineering`
   - Self-hosted or local mode: falls back to local directory `dat/docs/<workspace_slug>/` or local MinIO/S3 bucket.

   This dot-free convention:
   - Eliminates all Google Search Console domain verification requirements.
   - Preserves complete alignment with the workspace slug used in the previous DNS structure.
   - Guarantees global uniqueness in GCS via the project and environment prefix.
   - Adheres to GCS bucket naming constraints: 3 to 63 lowercase alphanumeric characters and hyphens (`^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$`).
   - Contains strictly no hardcoded literal hostnames or customer names.

### 4.2 Content Scope: "Docs Only"

Per owner msg `9431127d` ("create a new s3 bucket for the docs only per tenant"), the bucket stores strictly documentation text and document metadata:

```
gs://csi-spl-<env>-docs-<workspace>/
├── tree.json                              # Workspace document index & hierarchy
├── architecture/
│   ├── overview.md                        # Active document markdown
│   └── network-design.md
├── runbooks/
│   └── deploy-procedure.md
└── .history/                              # Immutable revision history
    ├── architecture/
    │   └── overview.md/
    │       ├── 20261004T140000Z--HUM-10--v1.md
    │       └── 20261004T153000Z--a-223--v2.md
    └── runbooks/
        └── deploy-procedure.md/
            └── 20261004T161000Z--HUM-12--v1.md
```

- **Included**: Markdown documents (`*.md`), the workspace index catalogue (`tree.json`), and versioned historical revisions under `.history/`.
- **Excluded**:
  - Image assets, PDFs, and binary attachments are **explicitly excluded** from the docs bucket.
  - Binary files must be uploaded to the dedicated files bucket (`050-gcs-files`) via the existing Hub files API (`POST /v1/files`) and referenced in Markdown using standard file markdown syntax `![diagram](/v1/files/<file-id>)`. This guarantees the docs bucket remains lightweight, cost-effective, and auditable.

### 4.3 Access Control & Tenant Isolation

Tenant isolation is strictly maintained through the Hub API layer. Web browsers and client agents never connect directly to Google Cloud Storage:

```
[ WUI / Agent Client ]
         │
         │  HTTPS + Authorization Cookie / Token (X-Spool-Tenant: t1)
         ▼
[ Spool Hub API Server ]
         │  1. Authenticate caller (humanTenant check)
         │  2. Verify tenant matches caller's session (sess.Tenant == "t1")
         │  3. Authorize RBAC permission (docs.read / docs.write)
         │  4. Resolve bucket name: csi-spl-<env>-docs-t1
         │
         ▼  GCP IAM (Hub Runtime Service Account)
[ gs://csi-spl-<env>-docs-t1 ] (ONLY accessible by Hub SA)
```

1. **GCS Bucket Security Policies**:
   - `uniform_bucket_level_access = true`: Access managed exclusively through GCP IAM; legacy object ACLs disabled.
   - `public_access_prevention = "enforced"`: Bucket cannot be made public under any circumstance.
   - No CORS configuration: Direct browser access to GCS is forbidden; all reads and writes flow through the Hub API.
2. **Hub Runtime Service Account**:
   - The Hub runtime service account (`hub_runtime_sa_account_id`, e.g. `csi-spl-hub-rt@...`) is granted `roles/storage.objectAdmin` on the workspace docs buckets.
3. **Zero Cross-Workspace Read / Write**:
   - Every Hub route for workspace docs (`/v1/workspace/docs/...`) invokes `s.humanTenant(w, r)`.
   - The Hub derives the bucket name solely from the caller's verified active workspace session `sess.Tenant`.
   - A member of workspace `t2` attempting to request a document from workspace `t1` receives HTTP 403 Forbidden or 404 Not Found.
   - Cross-workspace reading or writing is physically impossible at the API layer.

### 4.4 Provisioning Lifecycle (How a New Workspace Gets Its Bucket)

Workspaces are provisioned through two complementary mechanisms:

1. **Static Bootstrap Workspaces (Terraform Step `052-gcs-tenant-docs`)**:
   - Workspaces declared statically in `csi-spl-cnf/<env>.env.yaml` (e.g. root workspace `t1` and operator workspace) are provisioned via Terraform.
   - A Terraform module creates buckets with `for_each = toset(var.configured_tenants)`:
     ```hcl
     resource "google_storage_bucket" "workspace_docs" {
       for_each                    = toset(var.tenants)
       name                        = "${var.org}-${var.app}-${var.env}-docs-${each.value}"
       project                     = var.gcp_project
       location                    = upper(var.gcp_region)
       storage_class               = "STANDARD"
       uniform_bucket_level_access = true
       public_access_prevention    = "enforced"
       force_destroy               = false

       labels = {
         org    = var.org
         app    = var.app
         env    = var.env
         tenant = each.value
         role   = "workspace-docs"
       }
     }
     ```
2. **Dynamic Runtime Workspaces (Hub API Storage Client)**:
   - When an operator admin provisions a new workspace dynamically via the Operator API (`POST /v1/operator/workspaces`, spec 074) or CLI (`do_spl_tenant_create`):
     - The Hub runtime initializes a Cloud Storage client using Google Application Default Credentials.
     - Automatically creates bucket `${SPL_ORG_APP}-${ENV}-docs-${new_tenant_slug}` in the environment's configured region.
     - Writes the initial root `tree.json` (`[]`) and seeds default starter documentation (e.g. `welcome.md`).
     - Applies standard labels (`role = "workspace-docs"`, `tenant = new_tenant_slug`).
   - If bucket creation fails (e.g. quota limit), workspace creation rolls back atomically.

### 4.5 Concurrency Control & Revision History

- **Optimistic Locking**:
  - GCS natively supports atomic object preconditions using generation numbers (`x-goog-generation`).
  - When saving an updated document, the WUI or agent sends the known generation or version in the `If-Match` HTTP header.
  - The Hub executes a GCS write with `storage.Conditions{GenerationMatch: gen}`.
  - If a concurrent edit modified the object, GCS returns `412 Precondition Failed`, and the Hub returns HTTP 412 to the client with the remote version, preventing silent overwrites.
- **Revision Audit Trail**:
  - Prior to overwriting `<path>.md`, the Hub copies the existing object to:
    `.history/<path>/<ISO8601-UTC>--<author_id>--v<generation>.md`
  - Maintains full change attribution without requiring a database table or Git commit overhead.

### 4.6 Coexistence in the Explorer Tree

The left Explorer tree renders both repository documentation (Phase 1) and workspace documentation (Phase 2):

```
DOCS
├── 📁 Repository Docs [badge: repo] (Read-only, deployed)
│   ├── README.md
│   ├── 📁 csi-spl-doc
│   │   ├── 📁 doc
│   │   └── 📁 specs
│   └── 📁 csi-spl-wui
└── 📁 Workspace Docs [badge: workspace] (Read-Write, per-tenant)
    ├── 📁 architecture
    │   └── overview.md
    ├── 📁 runbooks
    │   └── deploy-procedure.md
    └── [ + New Page ] [ + New Folder ]
```

- **Routes**:
  - `/docs/repo/<path>`: Deployed codebase docs (Phase 1, read from `csi-spl-<env>-docs`). Backward-compatible alias: `/docs/<path>` resolves here.
  - `/docs/ws/<path>`: Workspace docs (Phase 2, read from `csi-spl-<env>-docs-<tenant>`).
- **Tree API**:
  - WUI queries `GET /v1/docs/tree.json` (repo catalogue) and `GET /v1/workspace/docs/tree.json` (workspace catalogue).
  - Merges the catalogues into the single Explorer component with respective badges and write capability.

---

## 5. Phase 3: Omnisearch Integration & Google Site Search Trade-Off

Owner HUM-10 stated:
> "Shape: replicate the tree from the github repo , but the omnisearch should enable search of simple terms via google site search"

### 5.1 The Plain Architectural Truth and Privacy Boundary

There is a fundamental technical constraint between public web crawlers and enterprise multi-tenant software:

1. **Google Only Indexes Public Content**:
   - Googlebot crawls **only publicly accessible, unauthenticated HTTP endpoints**.
   - Googlebot **cannot** log in, cannot hold a session cookie, cannot authenticate with an Ed25519 token, and cannot bypass tenant access controls.
2. **Data Leakage Risk on Workspace Docs**:
   - Workspace documentation contains proprietary architectures, internal credentials, customer notes, and business plans.
   - If workspace docs were made public for Google to index, any web user could find confidential enterprise documents via standard Google search.
3. **Freshness & Latency**:
   - Google indexing operates asynchronously, taking between several days and several weeks to re-crawl updated pages. It cannot support immediate search for recently created or edited workspace documentation.
4. **Current Phase 1 Gating**:
   - Even the Phase 1 repository documentation in Hub API (`internal/hub/docs.go`) requires an authenticated member session (`humanTenant`). As currently deployed, Google cannot index Phase 1 docs either.

### 5.2 The Recommended Solution Architecture

```
                                  OMNISEARCH QUERY (/search?q=...)
                                                 │
                        ┌────────────────────────┴────────────────────────┐
                        ▼                                                 ▼
        +-------------------------------+                 +-------------------------------+
        |     IN-APP NATIVE SEARCH      |                 |      GOOGLE SITE SEARCH       |
        |  (Hub Workspace & Repo FTS)   |                 |   (Public Repository Docs)    |
        +-------------------------------+                 +-------------------------------+
                        │                                                 │
            ┌───────────┴───────────┐                         ┌───────────┴───────────┐
            ▼                       ▼                         ▼                       ▼
    [Workspace Docs]        [Repo Docs]                 [Marketing Site]     [External Web]
    - Scoped to tenant      - Pre-indexed               - public docs index  - opens in modal
    - Instant (<10ms)       - Instant (<10ms)           - site:<domain>/docs   or new tab
    - Always private        - Synced on deploy          - Google CSE API
```

1. **In-App Omnisearch via Hub Full-Text Search (Default)**:
   - Extends the existing TopBar Omnisearch (spec 022) with doc result group `docs`:
     - Queries workspace docs catalogue and content cached in memory or indexed via Hub search worker, scoped strictly to the active workspace.
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
  - In workspace docs `tree.json`: document entries record associated `topic_id`.
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
  - When a document is saved or updated in a workspace docs bucket, the Hub triggers an asynchronous embedding worker.
  - Documents are chunked into 500-token passages with 50-token overlap.
  - Embeddings are generated using the configured corporate embedding model (e.g. OpenAI `text-embedding-3-small`, Google Vertex `text-embedding-004`, or self-hosted ONNX model for air-gapped environments).
- **Vector Storage**:
  - **Self-Hosted / Single Cluster**: Stored in PostgreSQL using the `pgvector` extension (`vector(1536)` column with HNSW index), preserving database-level RLS.
  - **Large Enterprise Cluster**: Pluggable driver for dedicated vector databases (Qdrant, Milvus, Pinecone).
- **Semantic Retrieval**:
  - Omnisearch gains natural language semantic querying (e.g. `"how do we configure agent join tokens?"`).
  - Queries return conceptually relevant document chunks even if the exact keyword does not match.

### 7.2 Corporate IAM & Access Control
- **Directory Service & SSO Integration**:
  - Integrates with corporate IdPs via SAML 2.0 and OIDC (Azure Active Directory / Entra ID, Okta, Ping Identity, Google Workspace).
  - Synchronizes directory groups to spool RBAC roles.
- **Granular Folder & Document ACLs**:
  - Extends workspace docs with explicit access tiers stored in bucket metadata:
    - `Public`: All members in the workspace.
    - `Internal`: Restricted to specific teams/roles (e.g. `engineering`, `finance`).
    - `Confidential`: Restricted to named individuals and explicit agent identities.
  - Enforced server-side in Hub API queries before streaming content from the workspace bucket.

---

## 8. Functional Requirements & Acceptance Matrix

### 8.1 Functional Requirements

| ID | Description | Phase | Status |
|---|---|---|---|
| **FR-001** | **Repo Docs Deployment Sync**: CI deploy pipeline uploads all repository `*.md` files (excluding agent prompts and build dirs) to environment object storage bucket (`csi-spl-<env>-docs`) and writes `tree.json`. | 1 | Implemented (c-221) |
| **FR-002** | **Hub Docs API**: Hub serves `GET /v1/docs/tree.json` and `GET /v1/docs/{repo path}` gated by signed-in member session. | 1 | Implemented (c-221) |
| **FR-003** | **Explorer Tree Navigation**: WUI renders an explorer-style collapsible folder tree from `tree.json` on the left and rendered markdown on the right. | 1 | Implemented (c-221) |
| **FR-004** | **Themed Markdown Rendering**: Documents render via `MarkdownBlock` respecting current theme CSS variables (light and dark). | 1 | Implemented (c-221) |
| **FR-005** | **Relative Link Rewriting**: Relative links to `.md` files resolve to in-app `/docs/...` routes; non-markdown links resolve to GitHub master. | 1 | Implemented (c-221) |
| **FR-006** | **Workspace Docs Bucket per Tenant**: Dedicated GCS bucket provisioned per workspace (`csi-spl-<env>-docs-<tenant>`) storing strictly docs content and metadata. | 2 | Planned |
| **FR-007** | **Collaborative Authoring**: Both human members and autonomous agents can create, read, update, and delete workspace docs via Hub API and CLI/MCP. | 2 | Planned |
| **FR-008** | **Document Revision History in Bucket**: Revisions are saved as immutable history objects under `.history/` prefix in the workspace bucket with author and timestamp. | 2 | Planned |
| **FR-009** | **Optimistic Concurrency via GCS Preconditions**: Concurrent document edits are guarded via GCS generation preconditions (`if_generation_match`), returning HTTP 412 on conflict. | 2 | Planned |
| **FR-010** | **Unified Explorer Hierarchy**: Left panel displays both "Repository Docs" and "Workspace Docs" in organized tree sections. | 2 | Planned |
| **FR-011** | **Omnisearch In-App FTS**: Omnisearch indexes workspace docs and repo docs via Hub search worker with strict tenant isolation. | 3 | Planned |
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
| **AC-04** | Create Workspace Doc | Click "+ New Page", enter title "Runbook", save | Document is written to `gs://csi-spl-<env>-docs-<tenant>/runbook.md`; appears in Workspace Docs tree; accessible only within active tenant. |
| **AC-05** | Agent Doc Authoring | Agent sends `POST /v1/workspace/docs/ops/guide.md` with agent token | Document is created in workspace bucket with agent author attribution; initial version recorded. |
| **AC-06** | Edit Document Revision Audit | Member edits doc content and saves | `.history/` in workspace bucket contains previous version with author and timestamp. |
| **AC-07** | Tenant Isolation Probe | User in tenant `t2` attempts to read tenant `t1` workspace doc | Request returns HTTP 403 or 404 (Hub routes strictly to `csi-spl-<env>-docs-t2`). |
| **AC-08** | Omnisearch Query | Enter term in top bar search | Search results include matching workspace docs and repo docs with highlighted excerpts. |
| **AC-09** | Git-Spec Message Auto-Link | Post message "See spec 074 for details" in a channel | Message renders `spec 074` as an interactive badge; clicking navigates to `/docs/csi-spl-doc/specs/074-operator-workspace/spec.md`. |
| **AC-10** | Topic <-> Doc Discussion Link | Click "Start Discussion" on a doc | New topic is created in `#general`; doc displays comment count; topic header pins the doc link. |

---

## 9. Numbered Questions for the Owner

The following numbered questions record owner decisions and open design choices for upcoming phases:

### Q1. Storage Engine for Workspace Documentation (RESOLVED by Owner msg 9431127d)
**DECISION**: **b) Cloud Object Storage (GCS) bucket per workspace, docs only.**
- Owner msg `9431127d` verbatim: *"create a new s3 bucket for the docs only per tenant"*.
- "s3" resolved as Google Cloud Storage (GCS), the standard cloud object store for the spool system.
- Content is strictly docs-only (Markdown, `tree.json`, and `.history/`); binary media attachments use the dedicated files bucket (`050-gcs-files`).
- Read/write access is mediated exclusively via the Hub runtime service account with strict per-tenant session routing; zero cross-tenant access.

---

### Q1b. Bucket Naming Style: Dot-Free vs Dotted Domain (Blocks Phase 2 Provisioning)
Owner suggested *"the buckets' names could be similar to the DNSs"* (msg `b7c66282`). How should the bucket name be structured?
- **a) Dot-Free Host-Derived Name: `<workspace-slug>-docs-<env>` (Recommended)**: Derived from the workspace slug that the DNS used (e.g. `t1-docs-dev` or `csi-spl-dev-docs-t1`). Avoids GCS Search Console domain verification requirements, does not rely on retired per-workspace vanity DNS subdomains (spec 074), and enables instant zero-touch tenant provisioning.
- **b) Dotted Domain-Style Name: `<workspace-slug>.docs.<BASE_DOMAIN>`**: Literal domain-style naming. Requires Google Search Console domain ownership verification for the deploying service account for every domain.

*Recommended Answer*: **a**

---

### Q2. Explorer Tree Coexistence (Blocks Phase 2 WUI)
How should workspace documentation sit in the left Explorer tree alongside the deployed repository documentation?
- **a) Two Distinct Top-Level Sections (Recommended)**: The Explorer tree shows two root folders: `📁 Repository Docs (Read-only)` and `📁 Workspace Docs (Read-Write)`. Provides an unambiguous distinction between system codebase docs and internal team docs.
- **b) Unified Root with Visual Badges**: All folders sit in a single merged tree, with badges (`[repo]` vs `[workspace]`) distinguishing their source.
- **c) Sub-Tab Switching**: Separate tabs at the top of the left panel: "Codebase Docs" and "Workspace Docs".

*Recommended Answer*: **a**

---

### Q3. Omnisearch & Google Site Search Privacy Model (Blocks Phase 3)
Google Site Search only crawls public, unauthenticated web pages, whereas workspace documentation is private and tenant-isolated. How should search be partitioned?
- **a) Hybrid Search (Recommended)**: In-app Omnisearch uses native Hub search for private workspace docs and in-memory indexing for repo docs (instant, secure, private). For public documentation, Omnisearch includes a button to "Search public web docs with Google" targeting `site:<BASE_DOMAIN>/docs`.
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
- Real-time collaborative typing / Operational Transformation / CRDTs (Phase 2 uses atomic revision locking via GCS object preconditions).
- Direct bidirectional Git push from browser to GitHub repository (repository docs remain deployment-synchronized).
- Storing binary media files inside the docs bucket (binary attachments use `/v1/files` and `050-gcs-files`).

---

## 11. Version Log

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1.0 | 2026-10-04 | a-223 | Initial complete draft specification for the Docs section: captures verbatim owner requirements (topic `9f0d751c`), details Phase 1 implementation as built by lane `c-221`, specifies Phase 2 workspace docs schema and RLS architecture, details Phase 3 Omnisearch vs Google search trade-offs, specifies Phase 4 git-spec and topic linking flows, outlines Phase 5 enterprise vector search and IAM, provides requirements and acceptance matrix, and provides four concise blocking questions for the owner. |
| v0.2.0 | 2026-10-04 | a-223 | Amended for owner decision (msg `9431127d`): Q1 resolved as (b) and "s3" resolved as GCS. Phase 2 updated to specify a dedicated GCS bucket per workspace (`csi-spl-<env>-docs-<tenant>`), docs only, accessed via Hub SA, with GCS generation preconditions for optimistic locking, `.history/` version audit, and dynamic/static bucket provisioning rules. Q2-Q4 kept open. |
| v0.2.1 | 2026-10-04 | a-223 | Settled bucket naming convention per owner msg `b7c66282` ('similar to the DNSs'): analyzed GCS domain verification constraint for dotted names vs spec 074 DNS retirement, adopted dot-free host-derived format `<workspace-slug>-docs-<env>`, and added Q1b with dot-free recommended default. |

<!-- version: 0.2.1 · updated: 2026-10-04 · last-edit: 2026-10-04T15:25:00Z -->
