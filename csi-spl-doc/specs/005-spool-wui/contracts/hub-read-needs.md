# What 005 consumes from the 003 viewer API (citation map, not a contract)

**The wire is 003's**: `../../003-spool-message-bus/contracts/view-v1.md`
(seam: `../../README.md` §5). This file only maps each 005 story to the
view-v1 section it uses, so either side can see a break. It restates no path
parameters, shapes or error tokens; on any doubt view-v1 wins.

## 1. Story → view-v1

| 005 | view-v1 | Note |
|---|---|---|
| US1 thread list | §4.3 `GET /v1/view/threads` | `before` paging; `channel` / `parent_task_id` are null in M1 and the viewer does not rely on them (FR-005) |
| US2 thread view | §4.4 `GET /v1/view/threads/{task_id}` | render `env.msg`; show `env.from_box` / `env.to_box`; `deliveries[]` shown read-only |
| US3 download | §1 `GET /v1/files/{file_id}` (http-v1 §3) | `mode:"blob"` only |
| US4 live follow | §4.4 poll with `after=`, ≥ 2 s | no browser WS in the first cut |
| US5 door | §2 view token (PROPOSED, 003 OQ-16); social session as the M3 successor door | token held in memory / `sessionStorage`, never `localStorage`, never in a URL |
| roster / DMs (later) | §4.1 `GET /v1/view/roster` | closes spec §5 G4 when implemented |
| channels (later) | §4.2 `GET /v1/view/channels` | empty in M1 (no `channel` in `v:1`, spec §5 G3) |
| cross-origin | §3 CORS from cnf `hub.view_cors_origins`, no credentials mode | the WUI calls with a bearer header, not cookies |

## 2. Status (measured 2026-09-18)

- view-v1: **Planned** (its own header; `grep -c '/v1/view' csi-spl-api/src/go/spool-hub-api/internal/hub/server.go -> 0` on trunk `03657c6`).
- A different, earlier read API exists **on a branch only**:
  `GRK-3349-hub-wui-read-api` (`2ecf59f`) adds `GET /v1/threads`,
  `GET /v1/messages?task_id=` and credentialed, Origin-reflecting CORS. It does
  not match view-v1 (paths, door, CORS mode). Which one lands is 003's call;
  005 codes against view-v1 as the contract of record.

<!-- version: 1.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:50:00Z -->
