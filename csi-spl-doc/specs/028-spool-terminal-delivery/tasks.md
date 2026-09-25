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

## Phase 6 — The strip garbles a live pane (D-07)

- [x] T060 Implemented (diagnosis, no code in this repo) — the owner's report
  "the window gets distorted as soon as the right strip is added" traced to
  agents started with plain `su - <agent> -c`, which never get SIGWINCH (D-07).
  Evidence, 2026-09-25, tmux 3.5a, Claude Code 2.1.282, csi-spl `cf33a5f`,
  ysg-box `5ed638c`, n=1 each: private-server plain `su -` idle garbled,
  `su --pty` clean; live CLE-010 (`su --pty`, TT `pts/34`) clean on split and
  unsplit; a lobby broadcast at 10:28:58Z split a strip into CLE-100 (plain
  `su -`, TT `?`) and `kill -WINCH <cli pid>` repaired it. The fix landed in
  the ysg-box launchers [lane CLE-3492].
- [ ] T061 Planned — correct the comments that still blame the renderer:
  `spawn-agents/scripts/spawn-window.sh` ("a WIDTH split … clips every
  transcript line … permanently"), `lib/spool-poke-queue.inc.sh` and
  `scripts/spool-strip-resize-proof.sh`. Make the proof script's Ink-style
  subject receive SIGWINCH the way a `su --pty` agent does, so the gate
  measures the real case [unowned]

## Phase 7 — Every agent reachable, on dev AND prd (D-08)

Measured by CLE-100 on box-desk, 2026-09-25, trunk as named per line.

- [x] T070 Implemented — setup guides for agents,
  `csi-spl-doc/doc/md/isg/{claude,grok,antigravity}-agent-setup.ISG.md`
  (`dabd51a`, `d708f8c`, `ef7d902`; grok updated by GRK-333 `71e5c63`). Claude
  verified step by step; grok/agy carry a NOT TESTED banner. Confirmed by
  CLE-3494 (all steps), CLE-120 and CLE-555 (local seat ok, 5.1 hit the
  fleet-wide login 429 -> section 5.0).
- [x] T071 Implemented — a stranded desk heals itself: `c7f2767` (hubclient
  redials when the hub no longer knows the session), `8bc66ab` (reconcile
  restarts a stranded sidecar) [lane CLE-34964]. First live self-heal:
  15:01:26Z, back up in 2 s, no repair (n=1).
- [x] T072 Implemented — box-desk seated on **prd** t1 (first pin 15:41:30Z,
  `do_spl_desk_up` from origin/master `5a4fecb`, `do_spl_desk_check ENV=prd` ->
  reachable, n=1). CLE-001 seats the rest box-wide.
- [x] T073 Implemented — all 18 box-desk agents picked into dev #lobby (201
  x18); the how-to post reached 18/18 inboxes (`51e7e8cc`). prd lobby post
  `1c4e58e5` (is_parent 1) + reply `4abecaee` with the three guides attached,
  because the GitHub links 404 for anyone outside the private repo; member GET
  200 x3 with sha256 == file_id, anonymous 401 (dev reply `43e9a33c` the same).
- [x] T074 Implemented — agents talk to the hub through seated MCP servers:
  `779bbab` (`spool mcp --as`), `db63e2c` (tracked `spool-mcp.sh` +
  `do_spl_agent_mcp_install` + test), `1414523`, `b6b2b4f`, `9c24bad`
  (`do_spl_agent_mcp_probe`) [lane CLE-34975]. Control `as=<other agent>`
  REFUSED dev n=4, prd n=2, fresh session n=1; recv <1 ms, send p50 90-400 ms.
  grok/agy registered, untested live. Guide 6.0 updated (CLE-100).
- [x] T075 Implemented — one strip shows both envs, records tagged
  `[dev]`/`[prd]`: `fbec9e5`, `4a500e5` (test-strip-two-envs.sh, control 9/19
  red on the old code) [lane CLE-34974]; the owner's strip %129 respawned in
  place 16:32Z.
- [x] T076 Implemented — the reply no longer rebuilds or re-merges:
  `ede979e` (build only when the tree is newer, refuse a downgrade, atomic
  rename; cnf merge cached), `7e5c923` (./run header parse without forks).
  Pre-send overhead 2.14-2.34 s -> 0.031-0.033 s; dry-run reply 0.98-1.14 s ->
  0.42-0.46 s (n=3) [lane CLE-34974].
- [ ] T077 Planned — a terminal-typed line shows as the human (spec 036
  `typed_by`) [lane CLE-3496].
- [ ] T078 Planned — the shared checkout /opt/csi/csi-spl is 40+ commits
  behind and dirty (24 files of other lanes), and the 5-minute reconcile cron
  runs from it, so the cron runs neither T071 fix [owner decision: who
  cleans it].
- [x] T079 Implemented — prd reconcile cron (`2-59/5`, tag
  `csi-spl:desk-reconcile-prd`) from a dedicated self-updating checkout
  `/opt/csi/csi-spl-desk-cron`; first cron tick 16:37:17Z exit 0, online, 28/28
  seated (CLE-100). prd #lobby agents: still to pick.

<!-- version: 1.3.0 · updated: 2026-09-25 · last-edit: 2026-09-25T17:15:00Z -->
