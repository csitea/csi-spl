# Tasks: terminal delivery — a message is VISIBLE in the recipient agent's pane (028)

**Feature**: `specs/028-spool-terminal-delivery` · **Created**: 2026-09-20 · **Lane**: MSG-TO-TERMINAL (CLE-3428)

`[x]` Implemented (sha + the check that proves it) · `[~]` Partial (missing part
named) · `[ ]` Planned (`../README.md` §2.3). Tasks owned by another lane name
the owner.

## Phase 1 — Spec and contract

- [x] T001 Implemented (`31355bd`) — `spec.md` (FR-001..FR-008, SC-001..SC-004)
  and `contracts/poke-line.md` (the rendered line, its sanitisation, its bounds
  and the outcomes 0/5/6/7).

## Phase 2 — The renderer and the safe-poke rules (orc)

- [x] T010 Implemented (`31355bd`) — `lib/spool-notify.inc.sh`:
  `spool_notify_render` (five-step sanitisation, bounded excerpt, the inert
  `: 'SPOOL …'` wrapper) and `spool_notify_poke` (registry-first pane id,
  refuse on unsent typed text, skip a pane that runs only shells).
  `scripts/spool-notify.sh` is the entry point for a message that is ALREADY in
  an inbox — which is every message the hub sidecar writes.
  Check: `bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-notify.sh`
  -> `37 passed, 0 failed`. FR-002, FR-004, FR-007.
- [x] T011 Implemented (`31355bd`) — `scripts/spool-send.sh` delegates to the
  lib and runs its own `spool send` with `SPOOL_NOTIFY_CMD=off`, so a message
  is shown exactly once and the exit codes 0/5/6/7 stay the script's own.
  Check: `bash …/tests/test-spool-send.sh` -> `26 passed, 0 failed`. FR-008.

## Phase 3 — The hook in the binary, and the wiring

- [x] T020 Implemented (`d5b6042`) — `internal/notify` runs `$SPOOL_NOTIFY_CMD`
  with the message's fields as flags and the body on stdin, hooked at
  `spool.Store.writeBox` for `box == "inbox"` — the single place a message
  enters a local agent's inbox. argv, never a shell; `WaitDelay` bounds a
  notifier whose children hold the output pipe.
  Check: `go test ./internal/notify/ ./internal/spool/ ./internal/config/`
  -> `ok` x3 (9 new cases, incl. the redelivery that must ring nothing).
  FR-001, FR-003, FR-005, FR-006.
- [x] T030 Implemented — `lib/spool-env.inc.sh` resolves `SPOOL_NOTIFY_CMD` to
  this feature's `scripts/spool-notify.sh`, and `scripts/spool-harness.sh`
  exports it for the agent session AND for the `spool hub-run` sidecar it
  starts. Check: `bash …/tests/test-spool-harness.sh` -> `47 passed, 0 failed`
  (rows "SPOOL_NOTIFY_CMD exported to the agent", "an explicit
  SPOOL_NOTIFY_CMD wins", "the sidecar carries SPOOL_NOTIFY_CMD"). FR-005.

## Phase 4 — Proof

- [x] T040 Implemented (`8bb82ba`, timings `001ddca`) — `do_spl_m3_e2e` step
  `f-visible-in-agent-terminal`, in the existing harness, not a second one.
  Run: `ENV=dev TENANT_ID=t1 ROOT_KEY_JSON=… ./run -a do_spl_m3_e2e` against
  `https://dev.api.spool-hub.ai`, 2026-09-21T07:43Z, tree `8bb82ba`, n=1 —
  **every step PASS**, `rc=0`. SC-004.
- [x] T041 Implemented — every way a person or an agent addresses an agent,
  each measured as "the BODY is visible in the recipient's pane":

  | case | how it is addressed | kind | result |
  |---|---|---|---|
  | a | agent -> agent, ACROSS boxes | task | PASS |
  | b | human, `@mention` in #lobby | note | PASS |
  | c | human, directed task (box-wui signed, written by the sidecar) | task | PASS |
  | d | human, DM (no channel) | note | PASS |

  Evidence: `results.json` step `f`, four `: 'SPOOL EZB-1: … :: <body> :: run:
  spool recv --as EZB-1'` lines captured from the pane. Plus
  `tests/live-terminal-proof.sh` on the box user's REAL tmux server (n=1,
  2026-09-21T07:51Z, `001ddca`): local send 0.53 s, cross-box over the dev hub
  2.59 s, both visible. SC-001, SC-002.
- [x] T042 Implemented — the controls, all on the live runs above:
  `leaked_into_EZA-1_pane: []` (SC-003); an agent pane mid-sentence keeps its
  half-typed line and is not poked, while the message IS delivered; a pane
  whose tty runs only shells is skipped as an exited agent (exit 7).
  **Bound recorded, not glossed**: the unsent-text rule fires on a TUI input
  line, so a bare SHELL prompt is not protected — measured, and written into
  `contracts/poke-line.md` §4 with why widening the detector was rejected.

## Phase 5 — Deploy

- [x] T050 Implemented — **served on dev AND prd**. The terminal leg itself
  runs in the box's own `spool` binary (built by `csi-spl-api/src/bash/build.sh`,
  wired by `spool-harness`), so the feature never needed a Cloud Run roll; the
  hub links the same `internal/spool` but never sets `SPOOL_NOTIFY_CMD`.
  `d5b6042` nonetheless shipped with CLE-3355's `0.1.17`. Measured here, not
  relayed, at 2026-09-21T07:58Z:

  ```
  GET https://dev.api.spool-hub.ai/version -> 0.1.17 commit 39a5a25a built 2026-09-21T07:54:34Z
  GET https://api.spool-hub.ai/version     -> 0.1.17 commit 39a5a25a built 2026-09-21T07:54:26Z
  git merge-base --is-ancestor d5b6042 39a5a25a                       -> exit 0
  ENV=dev SHA=$(git rev-parse origin/master) ./run -a do_check_deploy_lag
    -> dev hub current served=39a5a25a n=0                             rc=0
  ENV=prd SHA=$(git rev-parse origin/master) ./run -a do_check_deploy_lag
    -> prd hub current served=39a5a25a n=0                             rc=0
  ```

  CI on the lane's last code sha `001ddca`: `10 ci: quality gate` success
  (3m41s, run `35575064998`), `20 ci-cd: spool hub build + deploy` success
  (5m22s, run `35575065210`).

<!-- version: 1.0.0 · updated: 2026-09-21 · last-edit: 2026-09-21T08:00:00Z -->
