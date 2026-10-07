# 104 API docs (OpenAPI 3.0.3 reference, served by the hub, viewed in Docs)

**Feature ID**: `104-api-docs-openapi` · **Milestone**: M3 · **Status**: **v1.1, panel consensus, 2026-10-07**  
**Created**: 2026-10-07 · **Lane**: a-518 (draft v1.0), c-485 (v1.1 fold) · **Topic**: `7dfe8a9d-8606-4993-8df5-63a44fb46c77`  
**Authority**: this file for normative behaviour and schema policy; `plan.md` for architecture; `tasks.md` for build order, ownership and done checks. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing.

**v1.1 folds the two panel reviews**, which stay unchanged beside this file:
- [review-s104-rev-1.md](review-s104-rev-1.md) (`79cc9e4d`)
- [review-s104-rev-2.md](review-s104-rev-2.md) (`0c2812da`)

Both agreed with the v1.0 shape (hand-written file + Go gate, one file for every role, lazy viewer, "Try it out" off) and both corrected the same facts. The one point they differed on, where the file is served from, settled on **the hub** (rev-2 conceded, 14:4xZ). What v1.0 said and v1.1 changed is listed in §7.

Builds on, and does not repeat:
- [003 spool message bus](../003-spool-message-bus/contracts/http-v1.md) (hub HTTP transport v1, routing conventions)
- [003 error envelope](../003-spool-message-bus/contracts/error-envelope.md) (`{ error, detail }`)
- [026 tenant from identity](../026-spool-tenant-from-identity/spec.md) (`X-Spool-Tenant`, session tenant resolution)
- [027 spool performance](../027-spool-performance/contracts/perf-budgets.md) (initial chunk ceiling 155 KB gzip; new features load lazily)
- [044 spool open source](../044-spool-open-source/spec.md) (the repo is public)
- [075 docs section](../075-docs-section/spec.md) (Docs workspace, `/docs/ws/<path>` precedent for a WUI-owned row)
- The 49 contract documents under `csi-spl-doc/specs/*/contracts/*.md`

---

## 1. The ask

### 1.1 Verbatim owner instructions
From owner HUM-10 in topics `303b6389` and `7dfe8a9d-8606-4993-8df5-63a44fb46c77` (#spool-hub-bugs):
- *"create the discussion for the creation of the swagger doc and their publishing to the existing open published docs"*
- *"Swagger page"*
- *"create it under bugs .. channel"*

Discussion topic: **t1 #spool-hub-bugs `7dfe8a9d-8606-4993-8df5-63a44fb46c77`** (opening post by dispatcher `c-002`).

### 1.2 Problem
The hub registers its `/v1` routes directly on a `net/http` `ServeMux` across 28 Go files. Their payloads, status codes and auth are partly described in 49 Markdown contracts, but there is no machine-readable OpenAPI file, several routes have no contract at all, and there is no API reference page in the web app. Clients and agents read Go handlers to learn a payload.

"Swagger page", in this spec, means the in-app API reference at `/docs/api` (§4.4). A classic Swagger UI page is not part of v1.1 (§4.6).

---

## 2. Baseline facts (measured on trunk `6e4fb6ed`, 2026-10-07)

### 2.1 Route inventory
```bash
git grep -n 'HandleFunc("' csi-spl-api/src/go/spool-hub-api | grep -v '_test.go' | grep -v 'testkit/' | grep -v 'fakeidp/' | grep -v 'githubtest/' | grep '/v1' | wc -l
```
-> **183 lines**, all in `internal/hub`, 28 files:

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

Those 183 lines are not 183 operations:

| kind | n | source |
|---|---|---|
| `OPTIONS` CORS preflights | 59 | `git grep -ho 'HandleFunc("OPTIONS [^"]*"' -- csi-spl-api/src/go/spool-hub-api/internal/hub ':!*_test.go' \| wc -l` |
| methodless catch-all `"/v1/view/"` (answers only 404 / 405) | 1 | `internal/hub/view.go:67` |
| `GET` 52, `POST` 28, `PUT` 11, `PATCH` 13, `DELETE` 19 | 123 | same grep with `'HandleFunc("[A-Z]* /v1'` |
| `GET /v1/marketing`, registered through `s.marketingRoute(mux, …)` with a variable pattern, so the grep misses it | +1 | `internal/hub/marketing_switch.go:65`, `:187` |

**The reference documents ~124 operations**: 183 − 59 `OPTIONS` − 1 catch-all + 1 `marketingRoute`. The count is measured, not pinned: the gate (§4.3) derives it by rule.

Seven patterns end in Go's multi-segment wildcard (`/v1/docs/{path...}`, `/v1/workspace/docs/{path...}`). OpenAPI path parameters match one segment only, so the file writes them `{path}` (parameter described as "repo path, may contain `/`") and the gate normalises `{x...}` to `{x}` before comparing.

Outside `/v1` the module registers ~39 more routes (`/auth/...`, `payments/handler.go` checkout, `GET /`, `/healthz`, `/version`, `/probe`). They are **out of scope for v1.1**; the gate lists that exclusion explicitly (§4.3), so adding them later is a deliberate edit.

### 2.2 Router shape
There is no `s.route()`. The mux is built in `Server.Handler()` (`internal/hub/server.go:305`), which passes a `*http.ServeMux` to ~30 `routeX(mux)` helpers. The standard library `ServeMux` (module is `go 1.25.14`) has **no API that lists its patterns**; probing with `mux.Handler(req)` only finds routes already known. The gate therefore reads the source, not the mux (§4.3).

### 2.3 Error envelope
`internal/wire/wire.go:936-937`: `Error string json:"error"`, `Detail string json:"detail,omitempty"`. The envelope is **`{error, detail}`**; there is no `reason` field.

### 2.4 CSP
- Hub docs responses carry `Content-Security-Policy: sandbox; default-src 'none'` (`internal/hub/docs.go`). A sandbox without `allow-scripts` runs no JavaScript: a hub-served Swagger HTML page renders nothing, and loosening the header would put script-running HTML on the hub origin under a member session.
- The deployed WUI CSP is rendered by `csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh`: `script-src 'self'` + sha256 hashes, no `'unsafe-eval'`, no `'unsafe-inline'`; `connect-src` already includes the hub hosts.

### 2.5 WUI initial chunk budget
`perf-budgets.json`: `ci_initial_gzip_kb` ceiling **155.0** (owner, topic `87eaa57b`), baseline 146.9 KB; real headroom is 5..8 KB depending on the figure read. Any viewer must sit in a lazy chunk, and nothing it needs may be imported from a client plugin, a layout or statically from `docs.vue`.

---

## 3. Decisions (the open questions, settled)

| question | decision | why |
|---|---|---|
| Generate from Go, or hand-write + gate? | **Hand-written file, gated by a Go test** | No annotation churn across 28 files; many handlers decode into helpers without struct tags. The gate is the forcing function. |
| Swagger UI or lighter viewer? | **Bespoke lazy WUI viewer at `/docs/api`; no Swagger UI in v1.1** | Budget (§2.5) and CSP (§2.4). |
| Operator routes in the same reference? | **One file, operator routes tagged, UI toggle** | Repo is public (044); one file, one gate, no schema duplication. The toggle is UX only. |
| OpenAPI 3.0.3 or 3.1.0? | **3.0.3** | Widest viewer/linter support; nothing here needs 3.1. Use `nullable: true`, not `type: [x, "null"]`. |
| JSON or YAML? | **JSON** | `go:embed` + `encoding/json`, no YAML dependency in the module (`grep -c yaml go.mod` -> 0); the browser parses it natively. |
| Docs tree position? | **Pinned at the top, as a WUI row** | Like `/docs/ws` (`docs.vue:164`); not a `tree.json` entry (the WUI drops non-`.md` tree entries, `docs.mjs:133`). |

---

## 4. Design

### 4.1 The file
- **One hand-written OpenAPI 3.0.3 JSON file inside the hub Go module**: `csi-spl-api/src/go/spool-hub-api/internal/hub/openapi.json`. It must be under the module: `go:embed` cannot reach `../`, so it cannot live in `csi-spl-doc/`.
- **Formatting**: `jq -S .` canonical form (sorted keys, 2-space indent), enforced by the gate, so diffs stay line-local.
- **`openapi`**: exactly `"3.0.3"`, pinned by the gate.
- **Server**: `https://{tenant}.{baseDomain}` with variables `tenant` (default `t1`) and `baseDomain` (default `<BASE_DOMAIN>`). The server carries **no `/v1`**: `paths` keep the full `/v1/...` patterns, byte-for-byte equal to the Go patterns after `{x...}` -> `{x}`. No literal domain or host anywhere.
- **Paths**: the ~124 operations of §2.1. Every operation has a unique `operationId`, a tag, a summary, its path parameters and its responses.
- **Schemas**: request and response bodies seeded from the 49 contracts; a route without a contract gets summary, parameters and the standard responses, to be filled in over time.
- **Error envelope** (`components.schemas.ErrorEnvelope`), referenced by every error response:
  ```json
  { "type": "object", "required": ["error"],
    "properties": { "error": { "type": "string", "example": "not_found" },
                    "detail": { "type": "string", "example": "no such message" } } }
  ```
- **Security**: declare only what the hub accepts. Read `humanTenant` (`internal/hub/resolve.go:60`) before writing `securitySchemes`: a member session, and a view token where that door accepts one. Operator routes carry `x-role: operator` on the same scheme; there is no separate `OperatorAuth` credential. `X-Spool-Tenant` (026) is one reusable parameter.

### 4.2 Serving
- The file is embedded with `go:embed` and served by the hub at **`GET /v1/openapi.json`**: `Content-Type: application/json; charset=utf-8`, `Cache-Control: private, no-cache`, `info.version` set to the running hub version (`/version`).
- Access: the same door as Docs, a signed-in member session. No member session -> **403** `forbidden` (FR-004).
- It ships **in the same image as the routes**, so file, gate and served spec are always one commit. Therefore:
  - no docs-bucket publish, no `publish-docs.func.sh` change;
  - no `ValidDocsPath` change, no `repo_docs_edit.go` change;
  - no `tree.json` entry;
  - no workflow 32 (`32_docs-publish.yml`) path-filter change.
- `GET /v1/openapi.json` is itself one of the documented operations, and the gate sees its `.HandleFunc` like any other.

### 4.3 The route gate
A Go test in `internal/hub` (no production change):
1. Parses every non-test `.go` file of `internal/hub` with `go/parser` and collects the string-literal pattern of every `.Handle` / `.HandleFunc` call, plus the literal passed to `s.marketingRoute`.
2. **Fails on any non-literal pattern it does not recognise**, so a new helper like `marketingRoute` cannot hide a route.
3. Normalises `{x...}` to `{x}`.
4. Applies the **exclusions, listed explicitly in the test**: every `OPTIONS` pattern; the methodless `/v1/view/` catch-all; every pattern not under `/v1` (§2.1).
5. Compares **both directions** against the embedded `openapi.json`:
   - a route without a spec operation fails, naming it;
   - a spec operation without a route fails, naming it;
   - a duplicate `operationId` fails.
6. Checks `openapi == "3.0.3"` and that the embedded bytes equal their `jq -S .` form.

### 4.4 The viewer (`/docs/api`)
- **One file for every role**; operator routes tagged; the viewer offers a scope toggle (member by default, operator on demand). The toggle is **UX only**: the hub's role checks are the only access control (044: the repo is public).
- A **lazy, theme-integrated WUI page at `/docs/api`**, rendered by a bespoke component loaded with `defineAsyncComponent`, fetching `GET /v1/openapi.json` from the hub (already in `connect-src`).
- **Pinned at the top of the Docs tree as a WUI row**, like `/docs/ws`. `docs.vue` is one catch-all page (`/docs/:path(.*)*`), so the reservation of `api` is code there; `/docs/api` cannot collide with a repo doc, whose paths all end in `.md`.
- **"Try it out" off**: the viewer issues no request other than fetching the spec.
- **0 KB initial-chunk delta**, proven by `perf-budget.py bundle` on a mock `nuxt generate`, not by asserting the import is dynamic.
- **An e2e proves it renders under the real WUI CSP**: no `eval` / `new Function`, no `unsafe-inline` (no runtime `<style>` injection, no inline `style=` / `on*=`), zero `securitypolicyviolation` events on `/docs/api`.

### 4.5 Not-allowed and error states
- No member session: hub answers 403 `forbidden` with the `{error, detail}` envelope; the WUI's signed-out redirect applies to `/docs/api`.
- Spec fetch fails: the viewer shows an error state, never a blank page.

### 4.6 No `swagger.html`
There is no `swagger.html` in v1.1, in the hub, the docs bucket or WUI `public/`. The hub docs CSP (`sandbox; default-src 'none'`) runs no JS, and loosening it is a stored-XSS surface. A classic Swagger UI page, if ever wanted, is a **later, separate task**: a lazy WUI route or static page with `swagger-ui-dist` vendored (no CDN), an external init script, and its own size and CSP e2e proof.

---

## 5. Functional requirements (normative)

- **FR-001 (File)**: One hand-written OpenAPI 3.0.3 JSON file at `csi-spl-api/src/go/spool-hub-api/internal/hub/openapi.json` documents every non-`OPTIONS` `/v1` operation the hub registers (~124 at `6e4fb6ed`), with `{path...}` written `{path}`.
- **FR-002 (Gate)**: A Go test using `go/parser` over the `.Handle` / `.HandleFunc` (and `marketingRoute`) literals fails when a route has no spec operation, when a spec operation has no route, on a duplicate `operationId`, and on an unrecognised non-literal pattern. Exclusions (`OPTIONS`, `/v1/view/` catch-all, non-`/v1`) are listed in the test.
- **FR-003 (Serving)**: The hub embeds the file with `go:embed` and serves it at `GET /v1/openapi.json`, in the same image as the routes. No docs-bucket publish, no `ValidDocsPath`, no `tree.json`, no workflow 32 change.
- **FR-004 (Access)**: `GET /v1/openapi.json` requires a signed-in member session; without one it answers **403** `forbidden` with `{error, detail}`.
- **FR-005 (Budget)**: The viewer is a lazy chunk; `ci_initial_gzip_kb` delta is 0 KB and stays below 155.0.
- **FR-006 (Roles)**: Operator routes are tagged `x-role: operator` and hidden behind a viewer toggle. The toggle is UX only; the hub's role checks are the access control.
- **FR-007 (CSP)**: An e2e proves `/docs/api` renders under the deployed WUI CSP with zero CSP violations (no eval, no unsafe-inline).
- **FR-008 (Hygiene)**: No literal domain, host, IP or personal name in the file or the viewer; `{tenant}` / `<BASE_DOMAIN>` placeholders only.
- **FR-009 (No mutation)**: "Try it out" is off; the viewer sends no request but the spec fetch.

---

## 6. Out of scope
- Non-`/v1` routes (`/auth`, checkout, `/version`, probes): excluded explicitly by the gate; a later spec may add them.
- A classic Swagger UI page (§4.6).
- Any "Try it out" design (no future-phase rules are specified).

---

## 7. Changes from v1.0 (panel)

| # | v1.0 said | v1.1 says | review |
|---|---|---|---|
| 1 | 183 routes to document | ~124 operations: −59 `OPTIONS`, −1 `/v1/view/` catch-all, +`GET /v1/marketing`; `{path...}` -> `{path}` | rev-1 §1.1/1.3, rev-2 §1.1 |
| 2 | gate introspects `s.route()`, one direction | `go/parser` over the literals, both directions, exclusions listed; no `s.route()`, `ServeMux` cannot list patterns | rev-1 §1.2/3.3, rev-2 §3.1 |
| 3 | `ErrorEnvelope {error, reason}` | `{error, detail}` (`wire.go:936-937`) | rev-1 §1.4 |
| 4 | file in `csi-spl-doc/.../contracts/`, published to the docs bucket, `ValidDocsPath` + `tree.json` change | file in the hub module, `go:embed`, `GET /v1/openapi.json`; no bucket, `ValidDocsPath`, `tree.json` or wf 32 change | rev-1 §3.1 (rev-2 §1.2 conceded) |
| 5 | standalone `swagger.html` in bucket, hub and WUI `public/` | dropped; later separate task | rev-1 §1.7/3.2, rev-2 §1.4 |
| 6 | FR-004: 404 when unauthenticated | 403 `forbidden` | rev-1 §1.8, rev-2 §1.2.5 |
| 7 | `OperatorAuth` scheme; future "Try it out" rules with `ALLOW_LIVE_API_MUTATIONS` | one session scheme + `x-role`; future rules struck | rev-1 §3.5, rev-2 §3.3/3.4 |
| 8 | server `https://{tenant}.{baseDomain}/v1` | server without `/v1`; paths equal Go patterns | rev-2 §3.2 |
| 9 | "API Reference" as a `tree.json` entry | pinned WUI row like `/docs/ws` | rev-1 §2.3, rev-2 §2 |
| 10 | Go 1.22+; box-local dispatch path cited | `go 1.25.14`; topic id only | rev-1 §1.8/3.6, rev-2 §3.6 |
