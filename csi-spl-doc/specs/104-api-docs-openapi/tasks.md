# 104 API docs (OpenAPI 3.0 + Swagger page) published in Docs: tasks

Authority for what is built (`spec.md` holds the behaviour; `plan.md` holds the architecture). Each task names the files it owns, its dependencies, positive and negative tests, and how "live" is proven in dev and prd. Status vocabulary: `../README.md` §2.3. Paths are under repository root unless specified.

Every build task is done only when:
- Backend: `go test -v ./...` in `csi-spl-api/src/go/spool-hub-api` passes cleanly.
- Frontend: `pnpm run test:unit`, `pnpm run typecheck`, and bundle size check in `csi-spl-wui` pass cleanly.
- Gate: `cd csi-spl-iac && ./run -a do_check_dist_hygiene` and `./run -a do_check_pre_push` pass cleanly.

---

### Phase 0: Specification
- [x] T001 **specification & planning** (lane a-518):
  - **Owns**: `csi-spl-doc/specs/104-api-docs-openapi/spec.md`, `csi-spl-doc/specs/104-api-docs-openapi/plan.md`, `csi-spl-doc/specs/104-api-docs-openapi/tasks.md`.
  - **Dependencies**: None.
  - **Positive test**: File syntax and structure validate against repo guidelines; all 183 `/v1` routes and 49 contracts accurately enumerated; 3 open questions answered with concrete recommendations.
  - **Negative test**: `cd csi-spl-iac && ./run -a do_check_dist_hygiene` fails if literal hosts, IP addresses, personal names, or non-org references are introduced.
  - **How live is proven**:
    - Dev & Prd: Committed to git master branch; review panel convened in discussion topic `7dfe8a9d-8606-4993-8df5-63a44fb46c77`.
  - **Done**: `do_check_dist_hygiene` clean, `do_check_pre_push_lint` clean, pushed to master.

---

### Phase 1: Canonical OpenAPI Specification & Go Route Introspection CI Gate
- [ ] T002 **authoritative OpenAPI 3.0 specification**:
  - **Owns**: `csi-spl-doc/specs/104-api-docs-openapi/contracts/openapi.json`.
  - **Dependencies**: T001.
  - **Positive test**: `jq empty csi-spl-doc/specs/104-api-docs-openapi/contracts/openapi.json` succeeds; JSON schema validator passes against OpenAPI 3.0.3 schema specification; all 183 `/v1` routes present in `paths`.
  - **Negative test**: Intentionally introducing a malformed method or invalid JSON structure causes schema validation to exit non-zero.
  - **How live is proven**:
    - Dev & Prd: `npx @stoplight/spectral-cli lint csi-spl-doc/specs/104-api-docs-openapi/contracts/openapi.json` returns zero errors.
  - **Done**: Complete OpenAPI 3.0.3 file committed covering all 183 routes.

- [ ] T003 **hub Go route coverage test gate**:
  - **Owns**: `csi-spl-api/src/go/spool-hub-api/internal/hub/openapi_test.go`, `csi-spl-api/src/go/spool-hub-api/internal/hub/openapi_routes.go`.
  - **Dependencies**: T002.
  - **Positive test**: `go test -v -run TestOpenAPIRoutesCoverage ./internal/hub` passes, asserting that every route registered in `Server.route()` matching `/v1/...` exists in `openapi.json` with matching HTTP method.
  - **Negative test**: Registering a dummy test route `mux.HandleFunc("GET /v1/test-untracked-route", ...)` without adding it to `openapi.json` causes `TestOpenAPIRoutesCoverage` to fail and print the exact missing endpoint.
  - **How live is proven**:
    - Dev: CI workflow runs `go test ./internal/hub` and passes.
    - Prd: Deploy gate verifies test passes before image compilation.
  - **Done**: Test committed and passing in Go test suite.

---

### Phase 2: Hub Serving & Publish Pipeline Integration
- [ ] T004 **publish pipeline docs staging for openapi.json & swagger.html**:
  - **Owns**: `csi-spl-orc/src/bash/run/publish-docs.func.sh`, `csi-spl-orc/src/bash/tests/publish-docs-openapi.tst.sh`.
  - **Dependencies**: T002.
  - **Positive test**: `ENV=dev DRY_RUN=1 ./run -a do_publish_docs` outputs staged `tree.json` containing an entry for `openapi.json` with title `"API Reference (OpenAPI)"` and stages `openapi.json` and `swagger.html` in staging directory.
  - **Negative test**: If `openapi.json` is missing from the repository, `do_publish_docs` logs a warning or fails staging without creating invalid `tree.json`.
  - **How live is proven**:
    - Dev: `gsutil ls gs://${SPL_ORG_APP}-dev-docs/openapi.json` confirms object presence in dev docs bucket.
    - Prd: `gsutil ls gs://${SPL_ORG_APP}-prd-docs/openapi.json` confirms object presence in production docs bucket.
  - **Done**: `publish-docs-openapi.tst.sh` passes; deploy script stages assets.

- [ ] T005 **hub HTTP route extension for openapi and swagger assets**:
  - **Owns**: `csi-spl-api/src/go/spool-hub-api/internal/hub/docs.go`, `csi-spl-api/src/go/spool-hub-api/internal/hub/docs_test.go`.
  - **Dependencies**: T004.
  - **Positive test**: Authenticated member request `GET /v1/docs/openapi.json` returns HTTP 200 with `Content-Type: application/json; charset=utf-8` and body matching the staged specification. `GET /v1/docs/swagger.html` returns HTTP 200 with `Content-Type: text/html; charset=utf-8`.
  - **Negative test**: Unauthenticated request (no session cookie/token) returns HTTP 403 `forbidden`. Request for invalid path `GET /v1/docs/openapi.json.bak` returns HTTP 404 `not_found`.
  - **How live is proven**:
    - Dev: `curl -s -H "Authorization: Bearer <member-token>" https://t1.<BASE_DOMAIN>/v1/docs/openapi.json | jq .openapi` returns `"3.0.3"`.
    - Prd: `curl -s -H "Authorization: Bearer <member-token>" https://t1.<BASE_DOMAIN>/v1/docs/openapi.json | jq .openapi` returns `"3.0.3"`.
  - **Done**: Hub unit tests pass and endpoint responds as specified.

---

### Phase 3: WUI Lazy API Reference Viewer & Docs Integration
- [ ] T006 **lightweight theme-aware API viewer component**:
  - **Owns**: `csi-spl-wui/src/components/ApiDocViewer.vue`, `csi-spl-wui/src/components/ApiRouteCard.vue`, `csi-spl-wui/tests/unit/api-doc-viewer.test.mjs`.
  - **Dependencies**: T005.
  - **Positive test**: Unit test mounts `ApiDocViewer.vue` with mock OpenAPI schema; asserts routes render grouped by tags, method pills display correct colors, and searching filter input narrows displayed route list.
  - **Negative test**: Malformed OpenAPI JSON payload displays fallback error state `alert: Failed to load API schema` without throwing unhandled exceptions.
  - **How live is proven**:
    - Dev: `pnpm run test:unit tests/unit/api-doc-viewer.test.mjs` exits 0.
  - **Done**: Viewer component implemented and covered by unit tests.

- [ ] T007 **WUI docs route navigation & bundle budget verification**:
  - **Owns**: `csi-spl-wui/src/pages/docs.vue`, `csi-spl-wui/src/utils/docs.mjs`, `csi-spl-wui/tests/e2e/docs-api.test.mjs`.
  - **Dependencies**: T006.
  - **Positive test**: Navigating to `/docs/api` renders `ApiDocViewer`; selecting "API Reference" in Docs sidebar navigates to `/docs/api`; `perf-budget.py bundle` passes with `ci_initial_gzip_kb <= 155.0 KB` (initial bundle delta is 0.0 KB).
  - **Negative test**: When Docs section is disabled on hub (`docs_off`), navigating to `/docs/api` displays graceful disabled state (`t('docs.off')`).
  - **How live is proven**:
    - Dev: Playwright e2e test `BASE_URL=https://t1.<BASE_DOMAIN> pnpm run test:e2e tests/e2e/docs-api.test.mjs` passes.
    - Prd: Browser navigation to `https://t1.<BASE_DOMAIN>/docs/api` renders interactive reference in < 2 seconds.
  - **Done**: E2E test passes; bundle ceiling verified.

---

### Phase 4: Role-Gating & "Try It Out" Safe Execution Controls
- [ ] T008 **operator route scope filtering and UI badging**:
  - **Owns**: `csi-spl-wui/src/components/ApiDocViewer.vue`, `csi-spl-wui/tests/unit/api-doc-operator-filter.test.mjs`.
  - **Dependencies**: T006.
  - **Positive test**: By default, scope filter is set to "Member API" and hides all `/v1/operator/...` endpoints; toggling scope filter to "Operator API" reveals operator routes; non-operator users see *"Requires Operator Role"* chip on operator cards.
  - **Negative test**: Standard member with role `member` cannot execute or view unauthenticated operator actions.
  - **How live is proven**:
    - Dev: Log in as standard member, verify operator endpoints are filtered by default.
    - Prd: Verify scope selector in production workspace.
  - **Done**: Scope filtering and role chips implemented and verified.

- [ ] T009 **safe execution controls ("Try it out" gating)**:
  - **Owns**: `csi-spl-wui/src/components/ApiDocViewer.vue`.
  - **Dependencies**: T008.
  - **Positive test**: Endpoint cards render request parameters, headers (`X-Spool-Tenant`), and payload schemas; no live "Execute" / "Send Request" button is rendered; documentation is purely descriptive.
  - **Negative test**: Inspection of component DOM confirms absence of live HTTP `fetch` triggers against mutating endpoints (`POST`, `PUT`, `DELETE`).
  - **How live is proven**:
    - Dev & Prd: Code review and DOM assertion in e2e test confirming zero outgoing API calls from viewer.
  - **Done**: Mutation prevention verified.

---

### Phase 5: Verification, Standalone Swagger UI & Production Sign-off
- [ ] T010 **standalone swagger.html bundle deployment**:
  - **Owns**: `csi-spl-wui/src/public/swagger/swagger.html`, `csi-spl-orc/src/bash/run/publish-docs.func.sh`.
  - **Dependencies**: T004.
  - **Positive test**: Clicking "Classic Swagger UI" in `/docs/api` opens `/docs/swagger.html`; Swagger UI renders using `/v1/docs/openapi.json` as spec source under sandboxed CSP.
  - **Negative test**: Directly invoking non-allowed scripts or external CDN origins fails under CSP policy (`sandbox; default-src 'none'`).
  - **How live is proven**:
    - Dev & Prd: `curl -I https://t1.<BASE_DOMAIN>/v1/docs/swagger.html` returns `HTTP 200` with proper security headers.
  - **Done**: Standalone Swagger asset tested and deployed.

- [ ] T011 **end-to-end verification, distribution hygiene & release note**:
  - **Owns**: `csi-spl-doc/specs/104-api-docs-openapi/spec.md`, release notes documentation.
  - **Dependencies**: T001..T010.
  - **Positive test**: Full suite execution: `do_check_dist_hygiene` exits 0; `do_check_pre_push` exits 0; dev and prd deployment pipelines complete without lag.
  - **Negative test**: Running hygiene check with intentional leak exits non-zero.
  - **How live is proven**:
    - Dev & Prd: Production release link verified via `SHA=<sha> ENV=prd ./run -a do_release_note_link`.
  - **Done**: All gates green, release note generated, feature ready for panel sign-off.
