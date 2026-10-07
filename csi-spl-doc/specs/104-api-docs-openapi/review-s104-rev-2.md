# 104 API docs: panel review, seat s104-rev-2

**Seat**: s104-rev-2 (claude) · **Reviewed**: `spec.md`, `plan.md`, `tasks.md` at
`aeb8b204` (lane a-518) · **Tree measured**: trunk `6e4fb6ed`, 2026-10-07 ·
**Topic**: `7dfe8a9d-8606-4993-8df5-63a44fb46c77`

Verdict: **agree with the shape** (hand-written spec plus a Go coverage gate, one
file for member and operator routes, a lazy viewer, no "Try it out"), **change
five things** before the build starts: the route count, the standalone
`swagger.html`, the hub serving change, the Docs tree entry and the coverage
test's mechanism. Every claim below names the command or line that checks it.

## 1. Facts checked against the code

### 1.1 Route count: 183 is grep lines, not documentable operations

The draft's command reproduces: `git grep -n 'HandleFunc("' csi-spl-api/src/go/spool-hub-api | grep -v _test.go | grep -v testkit/ | grep -v fakeidp/ | grep -v githubtest/ | grep /v1 | wc -l` -> `183`, all of them in `internal/hub` (28 files; the per-file table matches exactly). But those 183 lines are:

| kind | lines | command |
|---|---|---|
| `OPTIONS` CORS preflights | 59 | `git grep -ho 'HandleFunc("OPTIONS [^"]*"' -- csi-spl-api/src/go/spool-hub-api/internal/hub ':!*_test.go' \| wc -l` |
| methodless catch-all `"/v1/view/"` (only answers 404 / 405) | 1 | `view.go:67` |
| `GET` 52, `POST` 28, `PUT` 11, `PATCH` 13, `DELETE` 19 | 123 | same grep with `'HandleFunc("[A-Z]* /v1'`, then `awk '{print $1}' \| sort \| uniq -c` |

And the grep misses one: `marketing_switch.go:187` registers `GET /v1/marketing` through `s.marketingRoute(mux, …)`, which calls `mux.HandleFunc(pattern, …)` with a variable (`marketing_switch.go:66`).

So the reference documents **124 operations** (123 + 1), not 183. Preflights are
CORS plumbing, not API; documenting them adds 59 empty entries. FR-001,
FR-002, plan Phase 1 and tasks T002/T003 should say "every non-`OPTIONS` `/v1`
operation (124 at `6e4fb6ed`)", and the gate should exclude `OPTIONS` and the
catch-all by rule rather than pin a count.

Also: 7 patterns end in a `{path...}` wildcard (`/v1/docs/{path...}`,
`/v1/workspace/docs/{path...}`). OpenAPI path templates cannot express a
multi-segment parameter; the spec must state the mapping (e.g. `{path}` plus an
`x-multi-segment: true` extension and a note) so the gate's path comparison is
defined.

### 1.2 Docs publish path

Confirmed: `csi-spl-orc/src/bash/run/publish-docs.func.sh` (`do_publish_docs`,
`spl_docs_stage`), `tree.json` = `{v, sha, files: [{path, blob, title}]}`,
`ValidDocsPath` in `internal/hub/docs.go:31` accepts `tree.json` or a `.md` path
only. The draft gets these wrong or misses them:

1. **Two publishers, not one.** Besides workflow 30, `.github/workflows/32_docs-publish.yml` runs `do_publish_docs` on every master push touching `**/*.md` (its `paths:` filter, lines 27-30). A change to `openapi.json` alone would not republish until the next WUI deploy or `.md` push. Add the file's path to that filter.
2. **The bucket is cnf, not a name pattern.** `do_docs_publish_gcp` reads `env.steps."051-gcs-docs".docs_bucket_name` from `SPL_CNF`. `gs://${SPL_ORG_APP}-${ENV}-docs` (spec 4.3, plan 2.2, T004) does not exist in the code: `grep -c SPL_ORG_APP csi-spl-orc/src/bash/run/publish-docs.func.sh` -> `0`. T004's live proof also uses `gsutil ls` with no `--account`, which breaks the repo rule that every gcloud call carries `--account` as the env SA. Use `gcloud storage ls … --account="$GCP_ACCOUNT"` through a named action.
3. **Provider `none` never deletes a stale non-`.md`.** `do_docs_publish_none` only removes `*.md` that left the stage, so a renamed or dropped `openapi.json` stays on a self-host box. Worth one line in T004.
4. **The hub change is two places, not one.** With repo editing on, `handleGetDoc` hands every path to `getRepoDoc` -> `serveRepoDoc`, which always sets `text/markdown` (`repo_docs_edit.go:375`, `docHeaders(h, "text/markdown; charset=utf-8")`) and looks up edit overlays for the path. Widening only `ValidDocsPath` would serve `openapi.json` as markdown on any env with repo edit on. T005 must route `openapi.json` past the overlay branch (or give it its own `GET /v1/docs/openapi.json` handler) and own `repo_docs_edit.go` too. `repodocs.validPath` (`internal/repodocs/path.go:26`) stays `.md`-only, so the file is not editable through the Docs editor; keep it so and test it.
5. **Unauthenticated status.** Code answers `writeForbidden` (403) when `hum == ""` (`docs.go:49`). Spec 4.5 says 403, FR-004 says 404. Fix FR-004 to 403.

### 1.3 WUI initial chunk budget

Confirmed: `perf-budgets.json` -> `"ci_initial_gzip_kb": 155.0`, baseline 146.9 KB,
about 8 KB headroom. The draft's conclusion (lazy chunk, 0 KB initial delta) is
right. One addition: a new client plugin, or a static import of the viewer's
helpers in `docs.vue`, pulls code into the initial set even when the component
itself is async. T007's check must be the real `perf-budget.py bundle` run on a
mock `nuxt generate`, not an assertion that the import is dynamic.

### 1.4 WUI CSP: the standalone `swagger.html` cannot work as drafted

Deployed CSP is rendered by `csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh` (lines 176-188): `script-src 'self' <sha256 hashes>`, `style-src 'self' <sha256 hashes>`, no `'unsafe-eval'`, no `'unsafe-inline'`, no `blob:`; `connect-src` is `'self'` plus the hub hosts. (`firebase.json` in git and `CSP_PROD` in `nuxt.config.ts` are not what ships; the render is, per `nuxt.config.ts:108-127`.)

1. **`/v1/docs/swagger.html` is dead on arrival.** The hub sends `Content-Security-Policy: sandbox; default-src 'none'` on every docs response (`docs.go:82`). A sandbox without `allow-scripts` plus `default-src 'none'` runs no script and loads no stylesheet: Swagger UI renders nothing. Loosening that header to make it run would turn the docs bucket into a script host on the hub origin, which carries the member session. **Drop `swagger.html` from the hub and the bucket** (spec 4.3/4.4, FR-003, FR-004, T004, T005, T010).
2. **A viewer inside the WUI must survive the deployed CSP**: no `eval` / `new Function` (rules out a viewer that compiles JSON Schema validators at runtime, Ajv-style), no runtime-injected `<style>` elements and no inline `style=` / `on*=` markup (the render FATALs on inline attributes in the bundle, line 130). Whether a given third-party viewer (Swagger UI, Scalar, Redoc) meets that is **unchecked here** and must be proven, not assumed.

Recommendation: the "Swagger page" the owner asked for is `/docs/api`, served by
the bespoke lazy `ApiDocViewer.vue` (the in-app half of the draft's Option C).
If a third-party viewer is wanted later, it is a lazy WUI route that must pass
an e2e test run against the **rendered** policy with zero CSP violations. Add
that negative test to T006/T007: load `/docs/api`, assert no
`securitypolicyviolation` event.

## 2. The three open points

| point | opinion | why |
|---|---|---|
| 3.0.3 vs 3.1.0 | **agree: 3.0.3** | Nothing in the plan needs 3.1 (no webhooks, no JSON Schema 2020-12 features). The Go gate only reads `paths` with `encoding/json`, and the bespoke viewer reads a small subset, so the choice only matters for external tools; I believe, unchecked, that 3.0.3 is still the more widely supported there (Go `kin-openapi`, older Swagger UI). Pin `"openapi": "3.0.3"` in the gate so a bump is a deliberate edit. |
| JSON vs YAML | **agree: JSON** | `handleGetDoc` already sends `application/json` for a `.json` suffix (`docs.go:76`); the Go module has no YAML dependency (`grep -c yaml csi-spl-api/src/go/spool-hub-api/go.mod` -> `0`); the browser parses it natively. Require one formatting (`jq -S .`) so diffs stay reviewable on a hand-maintained 124-operation file. |
| Docs tree position | **agree: pinned at top, but as a WUI row, not a `tree.json` entry** | The WUI drops every non-`.md` tree entry: `buildDocsTree` skips paths failing `validDocsPath` (`csi-spl-wui/src/utils/docs.mjs:133`), which is `.md`-only (line 19). So the draft's `{ "path": "openapi.json", … }` in `tree.json` would never show. Follow the `/docs/ws/<path>` precedent (`docs.vue:164`): a fixed "API Reference" row above the repo folders, route `/docs/api` reserved in `docs.vue` (the page is one catch-all, `definePageMeta({ path: '/docs/:path(.*)*' })`, so the reservation is code, not a route file). Leave `tree.json` unchanged; the viewer fetches `GET /v1/docs/openapi.json` directly. |

## 3. Other changes

1. **Coverage test mechanism.** There is no `s.route()`; the mux is built in `Server.Handler()` (`server.go:305`), and `http.ServeMux` has no API that lists its patterns. Wrapping the mux would change the `mux *http.ServeMux` parameter of ~30 `route*` functions. Cheaper, and no production change: the test parses the hub's non-test `.go` files with `go/parser`, collects the string-literal pattern of every `HandleFunc` / `Handle` / `marketingRoute` call, and **fails on any non-literal pattern** it does not recognise. Then compare both directions: every Go operation is in `openapi.json`, and every `openapi.json` operation exists in Go (the draft checks only the first; a deleted route would leave a stale entry forever).
2. **Server URL.** `https://{tenant}.{baseDomain}/v1` puts `/v1` in the server, so the paths would have to drop it, while the gate compares full `/v1/...` patterns. Use `https://{tenant}.{baseDomain}` as the server and keep `/v1/...` in `paths`, so the file's paths equal the Go patterns byte for byte.
3. **Auth schemes.** The spec names an `OperatorAuth` scheme but not what the hub accepts. Declare the real ones (read `humanTenant` before writing them: session cookie for the WUI, a bearer token only if the hub accepts one) and make `X-Spool-Tenant` (spec 026) a reusable parameter.
4. **"Try it out" future rules** (spec 4.6) invent a tenant setting `ALLOW_LIVE_API_MUTATIONS`. FR-008 (off) is enough; strike the future-phase design so nobody builds against it.
5. **Ownership overlaps in `tasks.md`.** `publish-docs.func.sh` is owned by both T004 and T010; `ApiDocViewer.vue` by T006, T008 and T009. With `swagger.html` dropped, T010 goes away; fold T008/T009 into T006 (one file, one owner).
6. **Plan 2.1** says Go 1.22+; the module is `go 1.25.14` (`grep -m1 '^go ' csi-spl-api/src/go/spool-hub-api/go.mod`).
7. **Operator scope toggle (FR-006)** is fine as UX, but "hidden by default" must not read as access control: say in the spec that the hub's role checks are the only gate.

## 4. Five-line verdict

1. Agree: hand-written `openapi.json` + Go gate, one file for all roles, lazy in-app viewer, no "Try it out".
2. Change: count is 124 operations (183 lines minus 59 `OPTIONS` minus 1 catch-all, plus `GET /v1/marketing`); gate both directions via `go/parser`.
3. Change: drop hub-served `swagger.html` (hub CSP `sandbox; default-src 'none'` kills it); the "Swagger page" is `/docs/api`, proven against the rendered WUI CSP.
4. Change: serve `openapi.json` past the repo-edit overlay branch (`serveRepoDoc` forces `text/markdown`); bucket from cnf; add the file to workflow 32's path filter.
5. Open points: 3.0.3 yes, JSON yes, pinned at top yes, but as a WUI row like `/docs/ws`, not a `tree.json` entry (the WUI drops non-`.md` entries).
