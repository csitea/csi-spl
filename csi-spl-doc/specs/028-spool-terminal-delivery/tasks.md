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

- [ ] T040 Planned — `do_spl_m3_e2e` gains a "delivered to the agent terminal"
  assertion rather than a second harness. SC-004.
- [ ] T041 Planned — live on a box, with `capture-pane` evidence and timings,
  for every way a person or an agent addresses an agent: a cross-box message,
  a WUI DM, a WUI `@mention` in a channel, `kind=note` and `kind=task`.
  SC-001, SC-002.
- [ ] T042 Planned — the controls: a message for another agent never appears in
  that pane (SC-003), and a pane holding a half-typed line is never clobbered.

<!-- version: 0.2.0 · updated: 2026-09-20 · last-edit: 2026-09-20T06:55:00Z -->
