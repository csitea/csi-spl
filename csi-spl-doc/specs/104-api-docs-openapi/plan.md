# Implementation Plan: 104 API docs (OpenAPI 3.0.3, served by the hub, viewed in Docs)

**Version**: v1.1, panel consensus · **Date**: 2026-10-07 · **Spec**: [104 spec.md](spec.md) · **Tasks**: [tasks.md](tasks.md)  
**Topic**: `7dfe8a9d-8606-4993-8df5-63a44fb46c77` · **Reviews folded**: [rev-1](review-s104-rev-1.md), [rev-2](review-s104-rev-2.md)

---

## 1. Summary

One hand-written OpenAPI 3.0.3 JSON file lives in the hub Go module, is embedded with `go:embed`, and is served by the hub at `GET /v1/openapi.json`. A Go test parses the hub source and keeps the file and the routes equal in both directions. The WUI shows it at `/docs/api`, a lazy, theme-integrated page pinned at the top of the Docs tree.

Two deploy paths are touched, and only two: the hub image (workflow 20) carries the file, the gate and the route; the WUI (workflow 30) carries the viewer. The docs publish path (`do_publish_docs`, workflow 32, the docs bucket, `tree.json`, `ValidDocsPath`) is **not touched**.

---

## 2. Technical context

| area | fact |
|---|---|
| hub | Go module `csi-spl-api/src/go/spool-hub-api`, `go 1.25.14`; routes on a stdlib `http.ServeMux` built in `Server.Handler()` (`internal/hub/server.go:305`) |
| file | `internal/hub/openapi.json`, OpenAPI `3.0.3`, `jq -S .` form; `go:embed` cannot reach `../`, so not in `csi-spl-doc/` |
| auth | member session via `humanTenant` (`internal/hub/resolve.go:60`); 403 `forbidden` without one |
| errors | `{error, detail}` (`internal/wire/wire.go:936-937`) |
| WUI | Nuxt 3 / Vue 3 / TS; `docs.vue` is one catch-all page (`/docs/:path(.*)*`); `/docs/ws` is the precedent for a WUI-owned row |
| budget | `ci_initial_gzip_kb` ceiling 155.0, baseline 146.9 (`perf-budgets.json`) |
| CSP | deployed WUI CSP from `render-wui-firebase-json.sh`: no `unsafe-eval`, no `unsafe-inline`; hub already in `connect-src` |

---

## 3. Gate checks

- [x] **Paths**: repo-relative only; no box-local path cited.
- [x] **Hygiene**: no literal domain, host or name; server is `https://{tenant}.{baseDomain}` with `<BASE_DOMAIN>` default.
- [x] **Budget**: viewer is a lazy chunk; 0 KB initial delta, measured by `perf-budget.py bundle`.
- [x] **CSP**: no `swagger.html`; the viewer is proven under the deployed WUI CSP by an e2e.
- [x] **Version skew**: file, gate and route ship in one hub image.
- [x] **Access**: the hub's role checks are the only gate; the viewer's operator toggle is UX.

---

## 4. Source map

```text
csi-spl-api/src/go/spool-hub-api/internal/hub/
├── openapi.json               # the spec, hand-written, jq -S form
├── openapi.go                 # go:embed + handleOpenAPI, route GET /v1/openapi.json
├── openapi_serve_test.go      # 200 + content-type + version; 403 without a session
└── openapi_routes_test.go     # the gate: go/parser over .Handle/.HandleFunc/marketingRoute literals
csi-spl-wui/
├── src/components/
│   ├── ApiDocViewer.vue       # lazy viewer: tags, search, scope toggle, no "Try it out"
│   └── ApiRouteCard.vue       # one operation: method badge, params, body, responses
├── src/pages/docs.vue         # /docs/api reservation, pinned "API Reference" row
├── i18n/                      # viewer and row strings
└── tests/
    ├── unit/api-doc-viewer.test.mjs
    └── e2e/docs-api.test.mjs  # renders /docs/api, zero securitypolicyviolation
```

Not in the map, by decision: `publish-docs.func.sh`, `docs.go` / `ValidDocsPath`, `repo_docs_edit.go`, `docs.mjs` tree builder, `32_docs-publish.yml`, any `swagger.html`.

---

## 5. Phases

### Phase 1: file + gate (hub)
1. The gate test parses every non-test `internal/hub/*.go` with `go/parser`, collects the literal pattern of each `.Handle` / `.HandleFunc` call and of `s.marketingRoute`, fails on an unrecognised non-literal pattern, normalises `{x...}` -> `{x}`, applies the explicit exclusions (`OPTIONS`, `/v1/view/` catch-all, non-`/v1`), and compares both directions with the file. It also checks unique `operationId`, `openapi == "3.0.3"` and `jq -S` form.
2. `openapi.json` lands with the same commit, with a stub operation (operationId, tag, summary, path params, `ErrorEnvelope` error responses) for each of the ~124 operations, so the gate is green from its first commit.

### Phase 2: serving (hub)
`openapi.go` embeds the file and registers `GET /v1/openapi.json` behind the member-session door, with `info.version` set to the running version. The new route and its operation land together, so the gate stays green.

### Phase 3: schemas (hub, doc work in one file)
Fill request and response bodies from the 49 contracts. Sequential, one lane at a time on the one file.

### Phase 4: viewer (WUI)
`ApiDocViewer.vue` + `ApiRouteCard.vue`, tested against a fixture; then the `/docs/api` route and pinned row in `docs.vue`, the e2e under the deployed CSP, and `perf-budget.py bundle`.

### Later, not v1.1
A classic Swagger UI page, as its own task with its own size and CSP proof (spec §4.6).

---

## 6. Decisions and rejected alternatives

| decision | chosen | rejected | why |
|---|---|---|---|
| source of the file | hand-written, gated | swaggo annotations | no churn across 28 files; untyped bodies |
| where it lives | hub module, `go:embed` | `csi-spl-doc/.../contracts/` | `go:embed` cannot reach `../`; one commit for file, gate and route |
| where it is served | hub `GET /v1/openapi.json` | docs bucket via `do_publish_docs` | the bucket is published on the WUI deploy, the routes on the hub deploy: version skew |
| gate mechanism | `go/parser` over literals | recording mux; `s.route()` | `ServeMux` cannot list patterns; a recording mux edits ~30 signatures; `s.route()` does not exist |
| gate direction | both | route -> file only | a deleted route would leave a stale entry forever |
| viewer | bespoke lazy WUI page | Swagger UI bundled; hub `swagger.html` | budget; hub docs CSP runs no JS; WUI CSP has no eval |
| tree entry | WUI row like `/docs/ws` | `tree.json` entry | WUI drops non-`.md` tree entries; `tree.json` is the repo-edit base |
| operator routes | one file, `x-role`, UX toggle | separate file; omitted | one gate, no duplication; repo is public |
| "Try it out" | off | on, gated | no live mutation from a reference page |
