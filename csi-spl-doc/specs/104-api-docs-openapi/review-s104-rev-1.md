# 104 API docs: review, seat s104-rev-1

**Reviews**: `spec.md`, `plan.md`, `tasks.md` at `aeb8b204` (lane a-518) · **Seat**: s104-rev-1 (claude) · **Date**: 2026-10-07  
**Topic**: `7dfe8a9d-8606-4993-8df5-63a44fb46c77` · **Tree measured**: `origin/master` at `6e4fb6ed`

**Verdict: agree with the shape, change five things before the build.** The draft is right on these points: write the file by hand, gate it with a Go test, never put a viewer in the initial chunk, keep one file for member and operator routes, and turn "Try it out" off. Five of its facts are wrong, and each one would mislead a build lane. Section 1 gives the commands and file lines, so anyone can check them.

---

## 1. Checks against the code

### 1.1 Route count: 183 is right, but 59 of them are CORS preflights

`grep -rhoE '\.(Handle|HandleFunc)\("[^"]*/v1[^"]*"' <internal/hub non-test .go> | sort -u | wc -l` -> **183**, in 28 files. The per-file table in spec §2.1 matches exactly.

Broken down by method, the same grep gives:

| method | n |
|---|---|
| OPTIONS | 59 |
| GET | 52 |
| POST | 28 |
| DELETE | 19 |
| PATCH | 13 |
| PUT | 11 |
| no method (`/v1/view/` catch-all, view.go:67) | 1 |

So there are about **123 real operations**, not 183. The 59 `OPTIONS` handlers are browser preflights and do not belong in an API reference. The `/v1/view/` subtree is a 404/405 fallback. The coverage gate must skip both on purpose and list those exclusions in the test. Otherwise a lane spends days writing 59 empty preflight entries just to satisfy FR-001.

The non-`/v1` count is 39 by the same grep over the module (minus testkit/fakeidp/githubtest), not 40. That gap is small. The bigger issue is scope (see 3.4).

### 1.2 There is no `s.route()`, and `ServeMux` cannot list its routes

Spec §3.1 and T003 say the test "initializes the Hub server router (`s.route()`) and collects every registered pattern". No such function exists. The routes are built in `Server.Handler()` (server.go:305), which passes a `*http.ServeMux` to some 30 `routeX(mux)` helpers. The Go standard library `http.ServeMux` (go 1.25.14, go.mod) has **no API to list registered patterns**. You can only probe it with `mux.Handler(req)`, and probing finds routes you already know about, never ones you missed. The test can be built in either of two ways:

- **(a) AST scan (recommended):** a `go/parser` pass over `internal/hub/*.go` (non-test) that collects the string literal of every `.Handle`/`.HandleFunc` call. It needs no handler changes, and it is the same set the grep above counts.
- **(b) Recording mux:** change `routeX(mux *http.ServeMux)` to a small interface that records patterns. That edits about 30 signatures, which is churn the spec says it avoids.

T003 also names `openapi_routes.go` as "Helper to inspect ServeMux route patterns". Under (a) that file is test-only, so it should be `openapi_routes_test.go`.

### 1.3 `{path...}` cannot be written in OpenAPI 3.0 or 3.1

Seven routes use Go's multi-segment wildcard: `GET|PUT|OPTIONS /v1/docs/{path...}` and `GET|PUT|DELETE|OPTIONS /v1/workspace/docs/{path...}`. An OpenAPI path parameter matches only one segment, because `/` is not allowed inside it. The spec has to fix one mapping now, because the gate compares strings:

- Document the path as `/v1/docs/{path}`, with the parameter described as "repo path, may contain `/`".
- Have the test normalise `{x...}` to `{x}` before comparing.

### 1.4 Error envelope is `{error, detail}`, not `{error, reason}`

`internal/wire/wire.go:936-937`: `Error string json:"error"`, `Detail string json:"detail,omitempty"`. The 003 contract shows `{ "error": "unpinned_box", "detail": "…" }` too. Spec §4.2's `ErrorEnvelope` schema has `reason`. Every one of the ~123 operations references that schema, so this one error would be copied into all of them. Fix: `required: [error]`, `properties: {error, detail}`.

### 1.5 Docs publish path

- `spl_docs_stage` (publish-docs.func.sh:111-132) stages only `git ls-files -- '*.md'`. To ship `openapi.json` it needs a separate copy step, and the draft does say that.
- `ValidDocsPath` (docs.go:32) accepts `tree.json` or `*.md`. Content-Type already handles `.json` (docs.go:79), so adding `openapi.json` is one line. The draft is right here.
- **Do not put `openapi.json` in `tree.json` `files`.** That list is the repo-edit base (`blob` is the git blob an edit starts from, publish-docs.func.sh:110). Adding the file there puts a JSON file into the editable-docs list, and the WUI `buildDocsTree` (docs.mjs:133) drops any non-`.md` path anyway. Add a separate top-level key, e.g. `"api": {"path": "openapi.json", "title": "API Reference"}`, or leave it out of `tree.json` entirely (see 3.1).
- `do_docs_publish_none` (self-host) prunes only `*.md` (line 88), so a stale `openapi.json` survives forever there. That is minor, but name it.

### 1.6 WUI initial chunk budget

`perf-budgets.json`: `ci_initial_gzip_kb` ceiling **155.0** (owner 2026-10-02, topic 87eaa57b), with a 146.9 KB measured baseline. The `ci_bundle_size_mjs_gzip_kb` 150.2 and a 149.7 entry are also in the file. The draft's "~8.1 KB headroom" uses the oldest figure, so real headroom may be closer to 5 KB. Either way the conclusion holds: lazy-load only. I did not measure the draft's "Swagger UI ~280 KB gzip" and "viewer under 25 KB" figures; they are unverified.

FR-005 says "shall not increase by more than 0.1 KB". A `defineAsyncComponent` adds a few hundred bytes of import stub to `docs.vue`'s chunk. That chunk is lazy, but run `perf-budget.py` to be sure. (A past lane learned this: a static import inside a *client plugin* broke this budget once. The viewer must never be imported from a plugin or layout.)

### 1.7 CSP: the standalone `swagger.html` cannot work as specified

This is the largest defect in the draft.

- **Hub-served (`/v1/docs/swagger.html`):** `handleGetDoc` sets `Content-Security-Policy: sandbox; default-src 'none'` (docs.go:83). A `sandbox` without `allow-scripts` runs **no JavaScript**, so Swagger UI renders nothing. Loosening that CSP to make it work would put script-running HTML on the API origin, under a member session cookie. That is a stored-XSS surface on the hub, and it must not ship.
- **Iframed from the WUI:** the prod `frame-src 'self'` (nuxt.config.ts CSP_PROD; render-wui-firebase-json.sh:64) blocks a hub-origin iframe.
- **As a WUI static file** (`csi-spl-wui/src/public/swagger/`, plan §4): the prod `script-src` is `'self'` plus sha256 hashes of known inline blocks, **no `'unsafe-eval'`** (render-wui-firebase-json.sh:59; only CSP_DEV carries `'unsafe-eval'`, for Vite). The Swagger UI init script would have to be an external `.js`, not inline. Whether the `swagger-ui-dist` bundle itself calls `eval`/`new Function` is unverified. The `csp-violations.test.mjs` e2e must prove it, not assume it. The same applies to any third-party viewer (e.g. Scalar).

The draft puts `swagger.html` in three places at once: the bucket (T004), the hub (T005) and WUI `public/` (T010). Pick one. My recommendation is in 3.2.

### 1.8 Smaller factual issues

- Plan §2.1 says "Go 1.22+"; go.mod is `go 1.25.14`.
- Spec §4.5 says unauthenticated callers get 403, but FR-004 says 404. The code returns 403 `forbidden` for no member session (docs.go:48) and 404 `docs_off` when the hub has no docs bucket. Make FR-004 say that.
- T005's live proof uses `Authorization: Bearer <member-token>` on `https://t1.<BASE_DOMAIN>`. The docs door reads a member session (`humanTenant`), and the hub host is cnf `env.dns.api_fqdn`, not the tenant WUI host. Write the proof against the hub host with a session.

---

## 2. The three open points

### 2.1 OpenAPI 3.0.3 vs 3.1.0: **3.0.3**, agree

Every candidate viewer and linter (swagger-ui, spectral, a hand-rolled Vue viewer) handles 3.0.3 without surprises. Two 3.1 features would actually help here, JSON-Schema `null` types and `webhooks`, but neither matters for a reference of a JSON-over-HTTP hub. Two notes for whoever authors the file: use `nullable: true` (3.0) rather than `type: [x, "null"]`, and keep `jq .openapi` returning `"3.0.3"` as the done check.

### 2.2 JSON vs YAML: **JSON**, agree, for one more reason

No YAML parser goes into the WUI, and Go reads it with `encoding/json`. The draft gives both reasons. The decisive one it misses is this: **the file should be embedded in the hub binary** (see 3.1), and `go:embed` plus `encoding/json` keeps the hub module free of a YAML dependency it does not have today. The cost is reviewability: a 123-operation JSON file is diff-heavy. Mitigate it with `jq -S` canonical formatting enforced by the test (sorted keys, 2-space indent), so diffs stay line-local.

### 2.3 Docs tree position: **pinned at the top, as a synthetic row**, agree

`docsRoute` keeps the `.md` suffix (`'/docs/' + path`), and every published doc path ends in `.md`, so `/docs/api` can never collide with a repo doc. A pinned "API Reference" row above the repo folders is the right place. It must be a WUI constant, not a `tree.json` entry (see 1.5).

---

## 3. What the draft misses or gets wrong (design)

### 3.1 Version skew: serve the spec from the hub, not the docs bucket

`do_publish_docs` runs on the **WUI** deploy (workflow `30_wui-build-deploy.yml`). The routes the file describes ship with the **hub** deploy (`20_hub-build-deploy.yml`). Those two deploys land at different times and versions, so a bucket-published `openapi.json` describes whatever hub was current at the last WUI deploy.

Recommendation:

- Keep the file inside the Go module, e.g. `csi-spl-api/src/go/spool-hub-api/internal/hub/openapi/openapi.json`. `go:embed` cannot reach `csi-spl-doc/`, which is outside the module.
- Embed it in the hub and serve it from a dedicated `GET /v1/openapi.json`, with the same member-session door as docs, `Content-Type: application/json`, and `info.version` set to the running `/version`.
- The coverage test reads the same embedded bytes, so file, gate and served spec are always one commit.
- This drops the `ValidDocsPath` change, the publish-docs staging (T004) and the `tree.json` question entirely.
- Point the spec 104 `contracts/` directory at the module path from a short README; no copy.

### 3.2 Standalone Swagger UI: defer it

Given 1.7, phase 1 should be only the lazy WUI viewer fetching `GET /v1/openapi.json` (hub origin is already in `connect-src`). If the owner's "Swagger page" means literally Swagger UI, then the only CSP-sound home is a WUI static page with an external init `.js`, `swagger-ui-dist` vendored (not CDN, since prod `script-src 'self'`), and a passing `csp-violations` e2e. Make that a separate later task with its own size and CSP proof, not part of T004/T005.

### 3.3 The gate should check both directions and method sets

FR-002 only fails on routes missing from the file. It should also fail on:

- a path or method in the file that the hub does not register, so stale entries cannot rot after a route is removed;
- a duplicate `operationId`.

That is the half that keeps the reference honest when a route is deleted.

### 3.4 Non-`/v1` routes are API too

`/auth/...` (sign-in, session, OAuth callbacks), the checkout routes in `payments/handler.go`, and `GET /version` are what a client actually calls first. The draft scopes them out silently. Either include them, at least `/auth` session and `/version`, or write an explicit exclusion list into the spec and the gate.

### 3.5 Operator routes: agree on one file, but security metadata must match the code

`x-role: operator` and a `security: [{OperatorAuth: []}]` scheme need a real `securitySchemes` entry. The hub's operator check is a session role, not a separate credential. Define one cookie/session `securityScheme` and carry the role in `x-role`, rather than inventing an `OperatorAuth` scheme that does not exist. FR-006's "requiring explicit toggle to view" is UX only. Say so, so nobody mistakes it for access control (the repo is public, spec 044).

### 3.6 The spec should not quote paths outside the repo

Spec §1.1 cites `/var/spool-hub/dispatch/c002-bugs-swagger-discussion.md`, a box-local path that the published docs cannot resolve. Cite the topic id only.

---

## 4. Summary for the consensus step

| # | change | where |
|---|---|---|
| 1 | Gate excludes 59 `OPTIONS` + the `/v1/view/` catch-all; ~123 operations to document | spec §2.1, FR-001/002, T002/T003 |
| 2 | No `s.route()`; gate = AST scan of `.Handle/.HandleFunc` literals, both directions, `{x...}` -> `{x}` | spec §3.1, T003 |
| 3 | `ErrorEnvelope` is `{error, detail}` | spec §4.2 |
| 4 | Spec lives in the Go module, `go:embed`, served at `GET /v1/openapi.json` by the hub; drop bucket staging / `ValidDocsPath` / `tree.json` change | spec §4.1/4.3, plan Phase 2, T004/T005 |
| 5 | `swagger.html` dropped from phase 1 (hub sandbox CSP runs no JS; WUI prod CSP has no eval); later task as WUI static page with external init + csp e2e | spec §3.2/4.4, T010 |
| — | agree: 3.0.3, JSON, pinned synthetic "API Reference" row, one file for operator routes, Try-it-out off | spec §6 |
