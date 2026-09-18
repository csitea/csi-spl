# What 005 needs from the 003 WUI read API (consumer view)

**The wire is 003's** (`../../README.md` §5: "WUI read API — owner 003
`contracts/`; 005 cites and depends"). This file does not define paths or
response shapes; it lists what the viewer needs so 003 can check its contract
covers it. On conflict, 003 wins and this file is corrected.

**State (measured 2026-09-18)**: not on trunk
(`grep -c 'v1/threads' csi-spl-api/src/go/spool-hub-api/internal/hub/server.go -> 0`).
Implemented on branch `GRK-3349-hub-wui-read-api` (`2ecf59f`: `GET /v1/threads`,
`GET /v1/messages?task_id=`, CORS in the middleware, a `http-v1.md` §2.7 draft).
When it lands, 003's contract section is the citation for every row below.

## 1. Needs

| # | Need | For |
|---|---|---|
| N1 | List the tenant's threads (one row per `task_id`): first message's `from`/`from_box`/`to`/`to_box`/`kind`/body, message count, first and last activity time; newest activity first; bounded `limit` | US1 |
| N2 | One thread's messages, oldest first: the inner `v:1` object plus envelope `from_box` / `to_box`, without the envelope `sig` | US2, US4 |
| N3 | Tenant = request Host; no tenant id anywhere in the request; another tenant's rows invisible | FR-004 |
| N4 | Empty tenant / unknown task → empty list, not an error; unknown Host → 404 with the 003 error token | US1 |
| N5 | CORS for a browser on another origin with `credentials: include` (lde `:3000` → hub; Firebase Hosting → Cloud Run), incl. `OPTIONS` | FR-007 |
| N6 | Blob download: `GET /v1/files/{file_id}` as already in 003 §3 | US3 |
| N7 | Read-only, and **not** a send/recv dialect: OQ-02 still holds for boxes | FR-002 |

## 2. Wanted later (not blocking the viewer MVP)

- Human-session gate on N1/N2 (spec §5 G1, with 006) — required before prd.
- Pagination for N1 (`before=`) and long threads.
- A browser live-follow channel to replace polling (US4).
- A read-only roster for humans (spec §5 G4).

## 3. Naming note for 003 and the integrator

The branch names N2 `GET /v1/messages?task_id=`. The 003 contract lists
`GET /v1/messages?as=&task_id=` as **removed** (OQ-02), and README §7 checks
that no FR cites a removed endpoint. Whether the viewer read keeps that path or
takes a distinct one (e.g. under `/v1/threads/{task_id}`) is 003's call; 005
consumes whichever lands.

<!-- version: 1.0.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:25:00Z -->
