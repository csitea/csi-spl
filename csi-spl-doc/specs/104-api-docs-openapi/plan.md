# Implementation Plan: 104 API Docs (OpenAPI + Swagger Page) Published in Docs

**Branch**: `a-518-s104-api-docs-spec` | **Date**: 2026-10-07 | **Spec**: [104 spec.md](spec.md)  
**Topic**: `7dfe8a9d-8606-4993-8df5-63a44fb46c77`

---

## 1. Summary

This implementation plan delivers a complete OpenAPI 3.0.3 specification and an interactive documentation viewer for the Spool Hub API, fully integrated into the existing in-app **Docs** section (`/docs`) and automated deployment workflows.

The implementation is structured across five sequential phases:
1. **Phase 1: Contract Synthesis & CI Route Gate**: Synthesize the authoritative OpenAPI 3.0 document (`openapi.json`) covering all 183 `/v1` routes using existing contracts as the normative baseline; introduce a Go route coverage unit test (`TestOpenAPIRoutesCoverage`) that enforces 100% route coverage across `internal/hub`.
2. **Phase 2: Publish Pipeline & Hub Serving**: Extend `publish-docs.func.sh` (`do_publish_docs`) and `spl_docs_stage` to stage and upload `openapi.json` and a pre-bundled standalone `swagger.html` to the environment's docs bucket; update `ValidDocsPath` in `internal/hub/docs.go` to serve these assets to signed-in members.
3. **Phase 3: WUI Lazy API Reference Viewer**: Introduce a lightweight, theme-integrated API documentation viewer (`ApiDocViewer.vue`) loaded strictly on demand via `defineAsyncComponent` on route `/docs/api` (and via Docs tree link), guaranteeing 0 KB growth in the 155 KB initial chunk budget.
4. **Phase 4: Role-Gating & Safe Execution Controls**: Implement UI scope filtering (`Member API` vs `Operator API`), badging operator-only endpoints, and enforcing the default disablement of live mutating HTTP requests ("Try it out" protection).
5. **Phase 5: Automated Verification & Documentation**: End-to-end testing across dev and prd, performance budget validation, distribution hygiene verification, and user guide updates.

---

## 2. Technical Context

### 2.1 Language and runtime versions
- **Backend**: Go 1.22+ (`csi-spl-api/src/go/spool-hub-api`)
- **Frontend**: TypeScript 5.x / Vue 3.4+ / Nuxt 3.12+ (`csi-spl-wui`)
- **Orchestration & Deploy**: Bash 5.x / Google Cloud Storage CLI (`gcloud storage rsync`) (`csi-spl-orc`)
- **Schema**: OpenAPI 3.0.3 JSON Specification

### 2.2 Primary dependencies & architectural bounds
- **Go Router**: Standard library `net/http.ServeMux` route registration.
- **WUI Shell Budget**: CI gzip ceiling of **155.0 KB** (`ci_initial_gzip_kb` in `perf-budgets.json`). Headroom on trunk is ~8.1 KB. The API documentation viewer MUST NOT reside in the initial bundle; it must be delivered as a detached lazy chunk.
- **Access Control**: Session-authenticated reads (`s.humanTenant(w, r)`) requiring a valid member session (`hum != ""`).
- **Storage**: Environment docs storage bucket (`gs://${SPL_ORG_APP}-${ENV}-docs`) managed via Terraform step `051-gcs-docs` and `publish-docs.func.sh`.

---

## 3. Constitution & Gate Checks

*GATE: Checked against repository ground rules, CLAUDE.md integration rules, and distribution hygiene.*

- [x] **I. Paths**: All file references use repo-relative paths (`csi-spl-doc/`, `csi-spl-api/`, `csi-spl-wui/`, `csi-spl-orc/`); zero hardcoded absolute filesystem paths.
- [x] **II. Environment Variables**: Storage buckets and API roots are determined dynamically via environment configuration (`ENV`, `SPL_CNF`, `BASE_DOMAIN`).
- [x] **III. Distribution Hygiene**: 100% org-neutral; zero personal names; zero literal server IPs or hosts (`<BASE_DOMAIN>`, `{tenant}`, `<product-domain>`).
- [x] **IV. Performance Budget**: Strict zero-growth impact on the initial WUI chunk (`ci_initial_gzip_kb <= 155.0 KB`).
- [x] **V. Security Boundaries**: Default-disabled "Try it out" live execution; operator routes require `operator` role session; static assets served under sandboxed CSP (`sandbox; default-src 'none'`).

---

## 4. Source Code Mapping

```text
csi-spl/
├── csi-spl-doc/
│   └── specs/
│       └── 104-api-docs-openapi/
│           ├── spec.md                          # Normative specification & policy
│           ├── plan.md                          # Technical architecture & phasing
│           ├── tasks.md                         # Task breakdown, ownership & done checks
│           └── contracts/
│               └── openapi.json                 # Authoritative OpenAPI 3.0 specification
├── csi-spl-api/
│   └── src/go/spool-hub-api/
│       └── internal/
│           └── hub/
│               ├── docs.go                      # ValidDocsPath extension for openapi.json/swagger.html
│               ├── docs_test.go                 # Serving unit test for openapi.json
│               ├── openapi_test.go              # TestOpenAPIRoutesCoverage (183 route coverage test)
│               └── openapi_routes.go            # Helper to inspect ServeMux route patterns
├── csi-spl-orc/
│   └── src/bash/
│       ├── run/
│       │   └── publish-docs.func.sh             # spl_docs_stage inclusion of openapi.json & swagger.html
│       └── tests/
│           └── publish-docs-openapi.tst.sh      # Unit test verifying staging and tree.json entry
└── csi-spl-wui/
    ├── src/
    │   ├── components/
    │   │   ├── ApiDocViewer.vue                 # Lazy-loaded lightweight, theme-aware API viewer
    │   │   └── ApiRouteCard.vue                 # Expandable route item with method badges
    │   ├── pages/
    │   │   └── docs.vue                         # Route /docs/api and tree "API Reference" link
    │   ├── utils/
    │   │   └── docs.mjs                         # validDocsPath update and tree builder integration
    │   └── public/
    │       └── swagger/
    │           └── swagger.html                 # Standalone Swagger UI wrapper (optional full UI)
    └── tests/
        ├── unit/
        │   └── api-doc-viewer.test.mjs          # Vue component unit tests
        └── e2e/
            └── docs-api.test.mjs                # Playwright end-to-end test for /docs/api
```

---

## 5. Phased Execution Plan

### Phase 1: OpenAPI 3.0 Schema Authoring & Go Route Introspection CI Gate
- **Objective**: Establish the single source of truth for Hub API schemas and lock in automated route coverage enforcement.
- **Key deliverables**:
  1. Author `csi-spl-doc/specs/104-api-docs-openapi/contracts/openapi.json` adhering to OpenAPI 3.0.3.
  2. Populate models and endpoints for all 183 `/v1` routes using the 49 existing contract files.
  3. Implement `internal/hub/openapi_test.go`:
     - Introspects `s.route()` handler mappings.
     - Compares registered paths and HTTP methods against `openapi.json`.
     - Exits non-zero with descriptive diff if any `/v1` route is missing.

### Phase 2: Hub Serving & Publish Pipeline Integration
- **Objective**: Automate staging and serving of the OpenAPI specification and Swagger UI assets alongside repository Markdown.
- **Key deliverables**:
  1. Update `publish-docs.func.sh`:
     - Stage `openapi.json` into `$stage/openapi.json`.
     - Append `{ "path": "openapi.json", "blob": "<sha>", "title": "API Reference (OpenAPI)" }` to `tree.json`.
     - Stage pre-built standalone `swagger.html` into `$stage/swagger.html`.
  2. Update `internal/hub/docs.go`:
     - Update `ValidDocsPath(p)` to accept `openapi.json` and `swagger.html`.
     - Maintain strict session gating (`hum != ""` required).
     - Ensure correct `Content-Type` headers (`application/json`, `text/html`).

### Phase 3: WUI Lazy API Reference Viewer & Route Navigation
- **Objective**: Integrate the interactive documentation view into the Spool web application without degrading startup performance.
- **Key deliverables**:
  1. Create `csi-spl-wui/src/components/ApiDocViewer.vue`:
     - Asynchronous lazy component.
     - Search filtering (by tag, route path, method).
     - Interactive schema display for parameters, request bodies, and 2xx/4xx/5xx responses.
     - CSS variables aligned with Spool theme system.
  2. Update `csi-spl-wui/src/pages/docs.vue`:
     - Render `ApiDocViewer` when navigating to `/docs/api` or selecting "API Reference" in the Docs sidebar.
     - Provide link/button to open `/docs/swagger.html` in a separate tab.
  3. Run performance check: `perf-budget.py bundle` verifying `ci_initial_gzip_kb <= 155.0 KB`.

### Phase 4: Role-Gating & "Try It Out" Safe Client Controls
- **Objective**: Enforce clean UX separation for operator endpoints and safeguard production environments from unintended API mutations.
- **Key deliverables**:
  1. Implement scope selector in `ApiDocViewer`:
     - Default view: `Member API` (messages, channels, topics, issues, calendar, settings).
     - Filter toggle: `Operator API` (fleet controls, workspace provisioning, node diagnostics).
     - Non-operators display informational badge: *"Requires Operator Role"*.
  2. Ensure "Try it out" interactive execution is disabled by default across all endpoints.

### Phase 5: Verification & Production Rollout
- **Objective**: End-to-end validation across dev and prd environments.
- **Key deliverables**:
  1. Automated E2E test in `tests/e2e/docs-api.test.mjs`.
  2. Verification of `do_publish_docs` in staging and production pipelines.
  3. Pre-push hygiene and lint checks pass cleanly.

---

## 6. Complexity Tracking & Alternative Rejections

| Decision | Chosen Solution | Rejected Alternative | Rationale |
|---|---|---|---|
| **Schema Generation** | Hand-authored `openapi.json` backed by Go CI route coverage test | Swaggo code annotations (`// @Summary ...`) | Annotating 183 handlers adds massive code churn across 28 Go files; many handlers use untyped JSON maps where struct reflection fails. |
| **Viewer UI** | Lazy-loaded Vue viewer (`ApiDocViewer.vue`) + standalone static `swagger.html` | Bundled `swagger-ui-dist` in WUI app shell | `swagger-ui-dist` gzip size exceeds 280 KB, which would instantly breach the 155 KB initial chunk ceiling (`ci_initial_gzip_kb`). |
| **Operator Endpoints** | Single OpenAPI file with `Operator` tag & UI scope toggle | Separate `openapi-operator.json` file | Spool code is open source (spec 044); maintaining two separate specifications leads to schema drift and duplicate CI pipelines. |
| **Interactive Execution** | "Try it out" disabled by default | Enabled live API calls in browser | Prevents unintended data mutations or deletion in production workspaces while browsing documentation. |
| **Docs Storage** | Uploaded to environment docs bucket alongside Markdown | Dedicated separate API docs bucket | Reuses existing bucket infrastructure (`051-gcs-docs`) and deploy mechanics (`do_publish_docs`). |
