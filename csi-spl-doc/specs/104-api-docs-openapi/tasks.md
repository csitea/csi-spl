# 104 API docs (OpenAPI 3.0.3, served by the hub, viewed in Docs): tasks

**Version**: v1.1, panel consensus · **Spec**: [spec.md](spec.md) (behaviour) · **Plan**: [plan.md](plan.md) (architecture)  
Status vocabulary: `../README.md` §2.3. Paths are repo-relative.

**One lane per task.** Each task names the files it owns; a file has one owner at a time, and a task that edits a file another task created starts only after that task has landed on master. Dependencies are stated per task.

Every build task is done only when:
- hub tasks: `bash csi-spl-api/src/bash/tests/run-all-tests.sh` green (it runs the gate);
- WUI tasks: `pnpm run typecheck`, `pnpm run test:unit`, and `BASE_URL=<generated bundle> pnpm run test:e2e` green in `csi-spl-wui`;
- all: `cd csi-spl-iac && ./run -a do_check_dist_hygiene` and `./run -a do_check_pre_push` green; landed on master; deployed dev and prd (`./run -a do_check_deploy_lag`).

**Never touched by any task below** (spec §4.2, §4.6): `csi-spl-orc/src/bash/run/publish-docs.func.sh`, `csi-spl-api/src/go/spool-hub-api/internal/hub/docs.go`, `.../internal/hub/repo_docs_edit.go`, `csi-spl-wui/src/utils/docs.mjs`, `.github/workflows/32_docs-publish.yml`, any `swagger.html`.

---

### Phase 0: specification

- [x] T001 **v1.0 draft** (lane a-518): `spec.md`, `plan.md`, `tasks.md`.
- [x] T001b **v1.1 panel-consensus fold** (lane c-485): `spec.md`, `plan.md`, `tasks.md`; reviews `review-s104-rev-1.md`, `review-s104-rev-2.md` unchanged.

---

### Phase 1: file + gate

- [ ] T002 **openapi.json with every operation stubbed, plus the route gate**
  - **Owns**: `csi-spl-api/src/go/spool-hub-api/internal/hub/openapi.json` (creates), `csi-spl-api/src/go/spool-hub-api/internal/hub/openapi_routes_test.go`.
  - **Depends on**: T001b.
  - **Builds**: the gate of spec §4.3 (embeds the file from the test with `go:embed`); the file of spec §4.1 with `info`, `servers` (`https://{tenant}.{baseDomain}`, no `/v1`), `components.schemas.ErrorEnvelope` `{error, detail}`, `securitySchemes` as read from `humanTenant`, the `X-Spool-Tenant` parameter, and one stub operation (operationId, tag, summary, path params, error responses) per route the gate finds (~124). Operator routes tagged `x-role: operator`.
  - **Positive test**: `go test -run TestOpenAPIRoutes ./internal/hub` passes; `jq -r .openapi internal/hub/openapi.json` -> `3.0.3`; `jq -S . openapi.json | diff - openapi.json` empty.
  - **Negative tests** (in the test file, on synthetic input): a route with no operation fails naming it; an operation with no route fails naming it; a duplicate `operationId` fails; a non-literal pattern outside the known helper fails; an `OPTIONS` pattern and `/v1/view/` are ignored.
  - **Live**: the hub image built from the landed sha passes CI (workflow 20); nothing served yet.

### Phase 2: serving

- [ ] T003 **serve the embedded file at `GET /v1/openapi.json`**
  - **Owns**: `csi-spl-api/src/go/spool-hub-api/internal/hub/openapi.go` (creates), `csi-spl-api/src/go/spool-hub-api/internal/hub/openapi_serve_test.go` (creates); edits `openapi.json` only to add the `GET /v1/openapi.json` operation; one registration line in the hub's route setup (`server.go` `Handler()`).
  - **Depends on**: T002 landed.
  - **Builds**: spec §4.2: `go:embed`, member-session door, `Content-Type: application/json; charset=utf-8`, `Cache-Control: private, no-cache`, `info.version` = running version.
  - **Positive test**: with a member session, 200, the content type above, body parses, `.openapi == "3.0.3"`, `.info.version` equals `/version`.
  - **Negative test**: no session -> 403 `forbidden` with `{error, detail}`; the gate fails if the route is registered without its operation.
  - **Live**: dev and prd, against the hub host (cnf `env.dns.api_fqdn`, never a literal), with a member session: `jq -r .openapi` -> `3.0.3`; without one -> 403.

### Phase 3: schemas

- [ ] T004 **request and response bodies from the 49 contracts**
  - **Owns**: `csi-spl-api/src/go/spool-hub-api/internal/hub/openapi.json` (edits only).
  - **Depends on**: T003 landed. One lane at a time on the file; if split, split by tag and run the lanes in sequence, never in parallel.
  - **Builds**: `requestBody` and 2xx schemas for every operation that has a contract under `csi-spl-doc/specs/*/contracts/*.md`; `nullable: true` (3.0), not `type: [x, "null"]`; each schema cites its contract in `description`.
  - **Positive test**: gate green; `jq -S` form holds; every operation with a contract has a non-empty 2xx schema, counted with `jq` in the lane's report.
  - **Negative test**: hub suite green; no literal host or name (`do_check_dist_hygiene`).
  - **Live**: dev and prd `GET /v1/openapi.json` shows the filled schemas after the hub deploy.

### Phase 4: viewer

- [ ] T005 **lazy viewer component**
  - **Owns**: `csi-spl-wui/src/components/ApiDocViewer.vue`, `csi-spl-wui/src/components/ApiRouteCard.vue`, `csi-spl-wui/tests/unit/api-doc-viewer.test.mjs` (all created).
  - **Depends on**: T002 landed (file shape; the unit test uses a small fixture, not the hub).
  - **Builds**: spec §4.4: operations grouped by tag, method badges, search by path / tag / method, params, body and responses; scope toggle (member default, operator on demand, UX only); no "Try it out"; theme tokens only, no inline `style=`, no runtime `<style>`, no `eval`.
  - **Positive test**: fixture renders grouped by tag; search narrows; the toggle hides and shows `x-role: operator` operations.
  - **Negative tests**: malformed JSON shows the error state without throwing; the component issues no request other than the spec fetch.
  - **Live**: covered by T006.

- [ ] T006 **`/docs/api` route, pinned row, CSP e2e, budget**
  - **Owns**: `csi-spl-wui/src/pages/docs.vue` (edits), the new strings in `csi-spl-wui/i18n/`, `csi-spl-wui/tests/e2e/docs-api.test.mjs` (creates).
  - **Depends on**: T005 landed; T003 deployed (the page fetches `GET /v1/openapi.json`).
  - **Builds**: `api` reserved in the `docs.vue` catch-all, rendered with `defineAsyncComponent(() => import('~/components/ApiDocViewer.vue'))`; an "API Reference" row pinned at the top of the Docs tree, like `/docs/ws`. No import of the viewer or its helpers from a plugin, a layout or statically from `docs.vue`.
  - **Positive test**: e2e loads `/docs/api`, the reference renders, the row is first in the tree and navigates to `/docs/api`; `perf-budget.py bundle` on a mock `nuxt generate` shows 0 KB `ci_initial_gzip_kb` delta, below 155.0.
  - **Negative tests**: e2e records zero `securitypolicyviolation` events on `/docs/api` under the rendered WUI CSP; a failed spec fetch shows the error state; signed-out lands on the signed-out redirect.
  - **Live**: dev and prd, `/docs/api` renders on the tenant WUI after the WUI deploy.

### Phase 5: close-out

- [ ] T007 **status to Done**
  - **Owns**: `csi-spl-doc/specs/104-api-docs-openapi/spec.md` (status line), `tasks.md` (checkboxes).
  - **Depends on**: T002..T006 live in dev and prd.
  - **Done**: release note links for the T003 and T006 shas (`SHA=<sha> ENV=<env> ./run -a do_release_note_link`, dev and prd) in the lane report.

---

### Later, not v1.1

- L001 **classic Swagger UI page** (spec §4.6): a separate spec or task, with `swagger-ui-dist` vendored, an external init script, a size proof and a CSP e2e. Not started by this spec.
