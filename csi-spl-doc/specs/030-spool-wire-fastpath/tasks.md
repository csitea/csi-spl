# Tasks: the wire fast path (030)

Status lives in `spec.md` §0.5–§0.7. This file exists so the index in
`../README.md` has a task list to point at. It does not add requirements.

| id | item | status | evidence |
|---|---|---|---|
| T001 | FP-2 warm submit on the sidecar socket, byte-identical envelope | Implemented | `spec.md` §0.5–§0.6; hub image tag noted there as `0.1.18` |
| T002 | box keepalive so a black-holed socket ends | Implemented | `spec.md` §0.7; ships in the image after `0.1.18` |
| T003 | hello `caps` negotiation, absent caps = old path | Implemented in the contract | `contracts/fastpath-v1.md`; hub envelope unchanged |
| T004 | FP-1 notifier must not block the sidecar read | see 028 / spec FR-002 | owned with the terminal leg |

No open task in this lane asks for a new hub frame.

<!-- version: 0.1.0 · updated: 2026-09-23 · last-edit: 2026-09-23T07:23:09Z -->
