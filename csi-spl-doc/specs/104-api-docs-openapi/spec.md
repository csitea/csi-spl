# 104 API docs (OpenAPI 3.0 + Swagger page) published in Docs

**Feature ID**: `104-api-docs-openapi` · **Milestone**: M3 · **Status**: Draft (Panel Review)  
**Created**: 2026-10-07 · **Lane**: a-518 (spec only) · **Topic**: `7dfe8a9d-8606-4993-8df5-63a44fb46c77`  
**Authority**: this file for normative behaviour and schema policy; `plan.md` for architecture and phasing; `tasks.md` for build order, ownership and done checks. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing.

Builds on, and does not repeat:
- [003 spool message bus](../003-spool-message-bus/contracts/http-v1.md) (Hub HTTP transport v1, error envelope, routing conventions)
- [003 error envelope](../003-spool-message-bus/contracts/error-envelope.md) (standard error schema `{ error, reason }`)
- [026 tenant from identity](../026-spool-tenant-from-identity/spec.md) (header `X-Spool-Tenant` and session tenant resolution)
- [027 spool performance](../027-spool-performance/contracts/perf-budgets.md) (initial chunk budget: 155 KB CI gzip ceiling, new features load lazily)
- [044 spool open source](../044-spool-open-source/spec.md) (repo is public, open development principles)
- [075 docs section](../075-docs-section/spec.md) (Docs workspace in web app, `GET /v1/docs/...`, `tree.json`, explorer tree)
- [076 cloud layer](../076-cloud-layer/spec.md) (cloud provider dispatch: `publish-docs.func.sh`, GCS docs bucket)
- The 49 contract documents under `csi-spl-doc/specs/*/contracts/*.md`
- `csi-spl-wui/src/pages/docs.vue` and `csi-spl-wui/src/utils/docs.mjs`

---

## 1. The ask, context & owner instructions

### 1.1 Verbatim owner instructions
From owner HUM-10 in topic `303b6389` and topic `7dfe8a9d-8606-4993-8df5-63a44fb46c77` (#spool-hub-bugs):
- *"create the discussion for the creation of the swagger doc and their publishing to the existing open published docs"*
- *"Swagger page"*
- *"create it under bugs .. channel"*

Discussion topic: **t1 #spool-hub-bugs `7dfe8a9d-8606-4993-8df5-63a44fb46c77`**.  
Opening post by dispatcher `c-002`: `/var/spool-hub/dispatch/c002-bugs-swagger-discussion.md`.

### 1.2 Problem statement
Today, the Spool Hub API exposes **183 endpoints** under `/v1/...`. These routes are registered directly via `net/http`'s `http.ServeMux` across 28 Go source files. Their request and response payloads, status codes, query parameters, and authentication requirements are partially documented across 49 distinct Markdown contracts (`csi-spl-doc/specs/*/contracts/*.md`), but:
1. There is no machine-readable OpenAPI specification (OpenAPI 3.0 or 3.1).
2. Several routes have no formal contract at all.
3. There is no interactive documentation (Swagger UI or interactive reference) hosted in the web application.
4. Clients, developers, and agent harnesses must manually inspect Go handler code to determine payload schemas and validation rules.

The owner requires the creation of a complete OpenAPI specification and an interactive API documentation page published in the existing in-app **Docs** section (`/docs`), integrated with the automated deployment pipeline (`do_publish_docs`), while adhering strictly to performance, security, and distribution hygiene constraints.

---

## 2. Codebase inspection & baseline facts

Every metric and inventory item in this section is measured directly against the live repository tree as of 2026-10-07.

### 2.1 Hub route inventory
Route count command:
```bash
git grep -n 'HandleFunc("' csi-spl-api/src/go/spool-hub-api | grep -v '_test.go' | grep -v 'testkit/' | grep -v 'fakeidp/' | grep -v 'githubtest/' | grep '/v1' | wc -l
```
**Measured count**: exactly **183 `/v1` routes**.

Distribution across the 28 Go source files in `csi-spl-api/src/go/spool-hub-api/internal/hub/`:
| File | `/v1` Routes | Functional Domain |
|---|---|---|
| `server.go` | 30 | Core messaging, delivery, websocket `/v1/ws`, files, pins, health |
| `view.go` | 19 | Primary feed and query views (`/v1/view/...`) |
| `calendar.go` | 16 | Calendar events, schedules, recurring series |
| `channel_members.go` | 16 | Channel rosters, membership joins/leaves |
| `issues.go` | 13 | Issues tracking, epics, milestones, statuses |
| `rbac.go` | 12 | Role-based access control, tenant permissions |
| `tenant_settings.go` | 9 | Workspace configuration, JSONB settings |
| `operator_workspaces.go` | 7 | Operator workspace provisioning and fleet management |
| `agent_lifecycle.go` | 5 | Agent spawning, runtime state, context |
| `operator.go` | 5 | Operator fleet control, node diagnostics |
| `release_notes.go` | 5 | Release notes ingest and changelog views |
| `repo_docs_edit.go` | 5 | Repo doc inline editing and overlay diffs |
| `human_status.go` | 4 | User presence, custom status, emoji state |
| `topic_merge.go` | 4 | Topic deduplication and message merging |
| `workspace_docs.go` | 4 | Per-tenant workspace document management |
| `demo_moderation.go` | 3 | Demo tenant content filtering |
| `fleet_load.go` | 3 | Fleet telemetry and node load balance |
| `marketing_switch.go` | 3 | Marketing automation toggles |
| `agent_aliases.go` | 2 | Agent naming and alias mappings |
| `box_stats.go` | 2 | Box hardware resource telemetry |
| `calendar_search.go` | 2 | Search indexing across calendar entries |
| `channel_order.go` | 2 | Channel sidebar layout and custom sorting |
| `demo.go` | 2 | Demo user session creation |
| `docs.go` | 2 | Static repo docs serving (`tree.json`, `*.md`) |
| `perf_ingest.go` | 2 | Real User Monitoring (RUM) metric ingestion |
| `perf_summary.go` | 2 | Aggregate performance telemetry |
| `search.go` | 2 | Inverted message index search |
| `topic_promote.go` | 2 | Topic promotion and channel linking |
| **Total** | **183** | **183 `/v1` routes** |

*Note on non-`/v1` routes*: The hub additionally registers 40 routes outside the `/v1` prefix: `/auth/...` session and social OAuth routes (13 in `auth/handler.go`, 6 in `auth/native.go`, 3 in `auth/facebook_callbacks.go`, 4 in `hub/keys.go`, 2 in `hub/events.go`), payment checkout routes (7 in `payments/handler.go`), and top-level root/health probes (`GET /`, `GET /healthz`, `GET /version`, `GET /probe` in `hub/server.go`), bringing total registered handlers to 223.

### 2.2 Existing contract inventory
Contract files query:
```bash
ls csi-spl-doc/specs/*/contracts/*.md | wc -l
```
**Measured count**: **49 files**.
These documents define message structures (`canonical-json.md`, `message-schema-v2.md`), HTTP routes (`http-v1.md`, `http-rental.md`, `checkout-v1.md`), view formats (`view-v1.md`), search queries (`search-v1.md`), and issue schemas (`issues-v1.md`). They serve as the normative baseline for populating parameter schemas, request bodies, and response models.

### 2.3 Docs publishing infrastructure
Docs deployment is driven by `csi-spl-orc/src/bash/run/publish-docs.func.sh` (`do_publish_docs`), invoked during WUI deploy (workflow 30):
1. **Staging (`spl_docs_stage`)**: Scans tracked repository Markdown files (`git ls-files -s -z -- '*.md'`), extracts top-level H1 titles, and generates `tree.json`:
   ```json
   {
     "v": 1,
     "sha": "<commit-sha>",
     "files": [
       { "path": "README.md", "blob": "<sha>", "title": "Spool" },
       { "path": "csi-spl-doc/specs/075-docs-section/spec.md", "blob": "<sha>", "title": "075 Docs Section" }
     ]
   }
   ```
2. **Path validation (`internal/hub/docs.go`)**:
   `ValidDocsPath(p)` checks that incoming doc requests match `tree.json` or:
   ```go
   var docsPathRe = regexp.MustCompile(`^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*\.md$`)
   ```
   *Crucial finding*: Currently, `ValidDocsPath` rejects any non-`.md` file other than `tree.json`. Serving `openapi.json` via `/v1/docs/openapi.json` requires explicitly updating `ValidDocsPath` or adding a dedicated handler `GET /v1/docs/openapi.json`.
3. **Serving & Security**: Served via `GET /v1/docs/{path...}` requiring a signed-in member session (`hum != ""`). Content Security Policy is locked down: `Content-Security-Policy: sandbox; default-src 'none'`.

### 2.4 WUI performance budget & bundle constraints
According to `csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json`:
- **Ceiling**: `ci_initial_gzip_kb: 155.0 KB` (lowered from 160.0 KB by owner directive in topic `87eaa57b`).
- **Baseline**: Live mock `nuxt generate` on trunk is ~146.9 KB gzip across 3 chunks (`ci_bundle_size_mjs_gzip_kb: 150.2 KB`).
- **Headroom**: Only **~8.1 KB gzip** remains before failing CI.
- **Impact on Swagger UI**: Standard Swagger UI (`swagger-ui-dist`) weighs ~1.2 MB uncompressed (~280 KB gzip). If included statically in the WUI shell, it would breach the budget by over 170% and immediately trip CI quality gates. Any viewer component MUST be strictly lazy-loaded on demand (`defineAsyncComponent`) on route access.

---

## 3. The 3 open questions: analysis, recommendations & trade-offs

Dispatcher `c-002` presented three foundational open questions in `/var/spool-hub/dispatch/c002-bugs-swagger-discussion.md`. Below are the comprehensive recommendations and architectural trade-offs:

### 3.1 Question 1: Code generation vs Hand-written with CI verification
> *"Generate the file from the Go code (route table + struct tags), or keep a hand-written file that a test checks against the routes?"*

#### Options analyzed
- **Option A (Full code generation from Go annotations)**: Tools like `swaggo/swag` scan Go handler comments (`// @Summary ... // @Param ...`).
  - *Drawbacks*: Clutters 183 Go handlers across 28 files with hundreds of lines of fragile comment annotations. Many Spool handlers read request bodies into dynamic JSON maps or helper structs that lack formal Go struct tags. Keeping annotations synced with code edits creates maintenance drag and requires non-standard build toolchains.
- **Option B (Pure hand-written specification)**: Maintain an OpenAPI 3.0 JSON/YAML document manually.
  - *Drawbacks*: Risks documentation rot. As new `/v1` endpoints are added during rapid feature development, developers may omit updating the specification.
- **Option C (Hand-written specification enforced by Go route coverage test)**: Maintain a canonical OpenAPI 3.0 specification file (`openapi.json`) in `csi-spl-doc/specs/104-api-docs-openapi/contracts/openapi.json` (or published via docs bucket), enforced by a strict Go unit test in `internal/hub/openapi_test.go` (`TestOpenAPIRoutesCoverage`).

#### Recommendation: Option C (Authoritative OpenAPI file + Automated Go CI Route Coverage Test)
1. **The file**: Maintain a canonical OpenAPI 3.0 JSON file (`openapi.json`). Request and response models are seeded directly from the 49 existing contract files (`csi-spl-doc/specs/*/contracts/*.md`).
2. **The gate**: Implement `TestOpenAPIRoutesCoverage` in `csi-spl-api/src/go/spool-hub-api/internal/hub/openapi_test.go`. The test initializes the Hub server router (`s.route()`), collects every registered HTTP method and path pattern under `/v1/...`, parses `openapi.json`, and asserts that:
   - Every registered `/v1/...` route has an exact path match in `openapi.json`.
   - The registered HTTP method (`GET`, `POST`, `PUT`, `DELETE`, etc.) is declared on that path.
   - Any `/v1` route present in Go code but missing in `openapi.json` causes test failure, printing the exact missing endpoints.
3. **Incremental refinement**: Routes with existing contracts provide complete request/response schemas; routes lacking formal contracts receive baseline schemas (summary, description, path parameters, standard `003` error envelope), to be expanded over time.

#### Trade-offs
- *Advantage*: Guarantees **100% route coverage** with zero risk of silent endpoint omissions. Zero annotation clutter in Go handlers. Allows clean, human-reviewed Markdown descriptions and rich examples directly from specs.
- *Downside*: Developers introducing a new `/v1` route must manually add an entry to `openapi.json` to make `go test ./internal/hub` pass. (This is a desired forcing function).

---

### 3.2 Question 2: Swagger UI vs Lighter Viewer
> *"Swagger UI (heavy) or a lighter viewer, given the web app's startup size limit?"*

#### Options analyzed
- **Option A (Standard Swagger UI bundled in WUI)**: Bundle `swagger-ui-dist` or Vue wrapper.
  - *Drawbacks*: Weighs ~280 KB gzip (~1.2 MB uncompressed). If bundled into the app shell, instantly breaks the 155 KB initial chunk ceiling (`ci_initial_gzip_kb`). Furthermore, Swagger UI injects aggressive global CSS that interferes with Spool's theme variables and font system.
- **Option B (Lightweight theme-aware API viewer)**: A custom Vue component or lightweight viewer (such as `@scalar/api-reference` or a bespoke renderer `ApiDocsView.vue` utilizing existing `MarkdownBlock.vue` and `UiIcon.vue`).
  - *Drawbacks*: Lacks the exact traditional three-column layout familiar to long-time Swagger UI users, though modern alternatives like Scalar are widely praised.
- **Option C (Lazy-loaded isolated viewer with two-tier delivery)**:
  - In WUI (`/docs`): Implement a lightweight, theme-integrated viewer `ApiDocViewer.vue` loaded strictly on demand via `defineAsyncComponent(() => import('~/components/ApiDocViewer.vue'))`. It adds **0.0 KB** to the initial chunk.
  - Standalone Swagger page: Deploy a standalone, static HTML wrapper (`swagger.html`) into the docs bucket during `do_publish_docs` containing pre-bundled Swagger UI assets. When a user clicks "Open classic Swagger UI", it opens the standalone viewer in a dedicated tab or sandboxed iframe.

#### Recommendation: Option C (Lazy-loaded WUI Viewer + Standalone Docs Swagger Page)
1. In `csi-spl-wui/src/pages/docs.vue`, add a dedicated navigation link in the Docs tree: **API Reference**.
2. When selected, the page asynchronously loads `ApiDocViewer.vue` (under 25 KB gzipped), rendering categorized endpoints, method badges, path parameters, request bodies, and response codes matching Spool dark/light themes.
3. For users desiring standard Swagger UI, provide a top-right action button: *"Classic Swagger UI"*, which links to `/docs/swagger.html` (served with sandboxed CSP).
4. **Performance verification**: `ci_initial_gzip_kb` remains at 146.9 KB (< 155 KB ceiling).

#### Trade-offs
- *Advantage*: Absolute protection of WUI bundle budget; perfect theme integration for 99% of in-app browsing; zero CSS pollution; preserves full Swagger UI capability for users requiring the classic interface.
- *Downside*: Requires maintaining the WUI viewer component alongside the static Swagger bundle generation.

---

### 3.3 Question 3: Operator-only routes inclusion
> *"Should operator-only routes (`/v1/operator/...`) appear in the same reference, or in a separate admin one?"*

#### Options analyzed
- **Option A (Separate OpenAPI documents)**: Maintain `openapi-member.json` and `openapi-operator.json`.
  - *Drawbacks*: Duplicates schema definitions, requires two distinct publishing artifacts, two CI coverage tests, and confusing documentation branching.
- **Option B (Omit operator routes entirely)**: Only document member routes.
  - *Drawbacks*: Violates the requirement that all 183 `/v1` routes have documentation. Leaves operator tools and CLI harnesses undocumented.
- **Option C (Unified specification with OpenAPI tag taxonomy and viewer filtering)**: Maintain a single canonical `openapi.json` documenting all 183 routes. Group operator routes under dedicated tags (`tag: Operator Fleet`, `tag: Operator Workspaces`) with clear `x-role: operator` and `security: [{ OperatorAuth: [] }]` annotations.

#### Recommendation: Option C (Single Canonical Specification with Role Tagging & Viewer Filtering)
1. **Single Source of Truth**: `openapi.json` documents all 183 routes. The CI route coverage test verifies all 183 routes against this single file.
2. **Security & Open Source alignment**: The Spool codebase is fully open source (spec 044). Operator handler code is public in Git. Documenting operator endpoints poses no security risk because the endpoints themselves enforce strict session checks (`requireOperator` returning 403).
3. **Viewer UX**: In the WUI API viewer, provide a scope selector:
   - `Scope: Member API (Default)`: Displays user/member endpoints (messaging, topics, channels, issues, calendar, settings).
   - `Scope: Operator API`: Displays fleet diagnostics, agent lifecycle, workspace provisioning, and node controls.
   - For users without operator permissions (`accessStore.me?.role !== 'operator'`), the Operator section is badged with an *"Operator Role Required"* notice.

#### Trade-offs
- *Advantage*: Single canonical file, single CI test, complete transparency, zero schema duplication.
- *Downside*: Standard users browsing the API reference can view operator endpoint schemas (though they cannot invoke them). This is consistent with Spool's open architecture.

---

## 4. The 6 proposal elements: detailed design

Mapping the 6 items from dispatcher `c-002`'s opening post:

### 4.1 Piece 1: The OpenAPI 3.0 specification file
- **Location**: `csi-spl-doc/specs/104-api-docs-openapi/contracts/openapi.json`.
- **Format**: Valid OpenAPI 3.0.3 JSON schema.
- **Server URL**: Dynamically configured without hardcoded domains:
  ```json
  "servers": [
    {
      "url": "https://{tenant}.{baseDomain}/v1",
      "description": "Tenant API endpoint",
      "variables": {
        "tenant": { "default": "t1", "description": "Tenant workspace slug" },
        "baseDomain": { "default": "<BASE_DOMAIN>", "description": "Spool product domain" }
      }
    }
  ]
  ```
- **Coverage**: All 183 `/v1` routes registered in `csi-spl-api/src/go/spool-hub-api/internal/hub/`.

### 4.2 Piece 2: Request and response shapes
- **Normative source**: Seeded from the 49 contract files in `csi-spl-doc/specs/*/contracts/*.md`.
- **Standard error envelope**: All error responses reference the common schema from `003-spool-message-bus/contracts/error-envelope.md`:
  ```json
  "ErrorEnvelope": {
    "type": "object",
    "required": ["error"],
    "properties": {
      "error": { "type": "string", "example": "not_found" },
      "reason": { "type": "string", "example": "no such message" }
    }
  }
  ```
- **Fallback for uncontracted routes**: Endpoints without dedicated markdown contracts are populated with query/path parameter types, operation summary, and 200/400/401/403/500 responses.

### 4.3 Piece 3: Publishing pipeline & storage
- **Artifact**: Staged by `spl_docs_stage` in `csi-spl-orc/src/bash/run/publish-docs.func.sh`.
- **Bucket key**: Uploaded to `gs://${SPL_ORG_APP}-${ENV}-docs/openapi.json` and `swagger.html`.
- **Index integration**: Included in `tree.json` as:
  ```json
  { "path": "openapi.json", "blob": "<git-sha>", "title": "API Reference (OpenAPI)" }
  ```
- **Hub serving**:
  - Update `internal/hub/docs.go`:
    ```go
    // ValidDocsPath allows tree.json, openapi.json, swagger.html, and *.md paths <= 512 bytes
    func ValidDocsPath(p string) bool {
        return p == DocsIndex || p == "openapi.json" || p == "swagger.html" || 
               (len(p) <= 512 && docsPathRe.MatchString(p))
    }
    ```
  - Content-Type: `application/json; charset=utf-8` for `.json`, `text/html; charset=utf-8` for `.html`.
  - Cache-Control: `private, no-cache`.

### 4.4 Piece 4: The Swagger / API documentation page
- **Primary route**: In WUI at `/docs/api` (and accessible via `/docs` sidebar tree as "API Reference").
- **Component structure**:
  - Lazy component `csi-spl-wui/src/components/ApiDocViewer.vue` loaded via `defineAsyncComponent`.
  - Reuses Spool design tokens: `--bg-primary`, `--text-primary`, `--accent-teal`, `--border-color`.
  - Method badges: `GET` (teal), `POST` (green), `PUT` (yellow), `DELETE` (crimson).
  - Collapsible route cards with search filter by path, tag, and HTTP method.
- **Secondary route**: Standalone Swagger UI at `/docs/swagger.html` for complete interactive specification exploration.

### 4.5 Piece 5: Access control & authorization
- Aligns with existing Docs access model:
  - Requires signed-in member session (`hum != ""`, verified via `s.humanTenant(w, r)`).
  - Unauthenticated requests receive `403` with `error: forbidden, reason: docs need a signed-in member session`.
  - Protected behind `signed-out-redirect` in WUI.

### 4.6 Piece 6: "Try it out" execution gating
- **Policy**: In Phase 1 and initial release, interactive "Try it out" request firing is **strictly disabled** by default.
  - The documentation serves as a reference and schema contract.
  - Reason: Preventing accidental mutations against production databases (e.g. `POST /v1/messages`, `DELETE /v1/channels/...`) while browsing documentation.
- **Future phase enablement**: If enabled in subsequent milestones, "Try it out" must:
  - Be restricted to safe idempotent methods (`GET`).
  - Require explicit tenant slug and API key / Bearer token entry in an interactive credentials drawer.
  - Block mutating methods (`POST`, `PUT`, `DELETE`) on production environments unless an explicit `ALLOW_LIVE_API_MUTATIONS` toggle is enabled in tenant settings.

---

## 5. Functional requirements (normative)

- **FR-001 (Specification Format)**: The system shall provide an authoritative OpenAPI 3.0 specification file (`openapi.json`) defining all 183 `/v1/...` routes.
- **FR-002 (CI Route Gate)**: A Go test (`TestOpenAPIRoutesCoverage`) shall introspect the hub router and fail CI if any mounted `/v1` route lacks an entry in `openapi.json`.
- **FR-003 (Publish Pipeline)**: The deploy action `do_publish_docs` shall stage and upload `openapi.json` and `swagger.html` to the environment's docs storage bucket at each WUI deploy.
- **FR-004 (Hub Serving)**: The Hub API route `GET /v1/docs/{path...}` shall serve `openapi.json` and `swagger.html` to signed-in members, returning 404 for unauthenticated callers or when docs are disabled.
- **FR-005 (WUI Zero-Budget Footprint)**: The WUI API reference viewer shall be loaded asynchronously via dynamic import; `ci_initial_gzip_kb` shall not increase by more than 0.1 KB and must stay strictly below 155.0 KB.
- **FR-006 (Role Separation)**: Operator-only endpoints (`/v1/operator/...`) shall be distinctly tagged and filtered in the UI, requiring explicit toggle to view.
- **FR-007 (Distribution Hygiene)**: No literal domains, hostnames, IP addresses, or personal names shall appear in the OpenAPI document or viewer templates. Dynamic placeholders `<BASE_DOMAIN>` and `{tenant}` shall be utilized.
- **FR-008 (Mutation Protection)**: "Try it out" live execution shall be disabled by default.

---

## 6. Open points for panel review

The following architectural points are submitted to the spec review panel for final determination:
1. **OpenAPI Version**: OpenAPI 3.0.3 vs OpenAPI 3.1.0. Recommendation: OpenAPI 3.0.3 has superior tooling and viewer compatibility across all lightweight Vue and standalone Swagger renderers.
2. **File Format**: JSON (`openapi.json`) vs YAML (`openapi.yaml`). Recommendation: JSON for zero-dependency native parsing in Go (`encoding/json`) and instant browser consumption without heavy client-side YAML parsers.
3. **Docs Tree Placement**: Should "API Reference" be pinned at the very top of the Docs tree (above repo folders) or alphabetized under `csi-spl-doc/`? Recommendation: Pinned at top alongside workspace docs for high visibility.
