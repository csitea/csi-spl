# Tasks: terminal ⇄ web UI mirror of a seated agent (036)

**Feature**: `specs/036-spool-terminal-mirror` · **Created**: 2026-09-25 · **Lane**: CLE-3496

`[x]` Implemented (sha + the check that proves it) · `[~]` Partial (missing part
named) · `[ ]` Planned (`../README.md` §2.3).

## Phase 1 — The mirror

- [x] T001 Implemented (`f8da6b4`) — `spawn-agents/scripts/spool-mirror.py`
  (`hook` / `post`), `lib/spool_redact.py` (moved out of the ad hoc session
  export), `scripts/spool-session-export.py`. FR-001..FR-007.
  Check: `bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-mirror.sh`
  -> `45 passed, 0 failed`.
- [x] T002 Implemented (`f8da6b4`) — the notifier records each pasted web UI
  line (`spool_notify_mark_typed`) and the human + topic of the last human
  DIRECT message (`spool_notify_mark_peer`; a broadcast is ignored). FR-003,
  FR-004. Check: the same test, sections 9-10; `test-spool-notify.sh` -> `75 passed`.

## Phase 2 — Named actions

- [x] T010 Implemented (`5add6fb`) — `do_spl_desk_session_upload` (the
  backfill, into the mirror's topic), `do_spl_desk_mirror_settings` (the hooks
  JSON), `do_spl_desk_mirror_check` (per-seat state + sidecar notifier WARN).
  FR-008. Check: `bash csi-spl-orc/src/bash/tests/desk-mirror-actions.tst.sh`.
- [x] T011 Implemented (`a9fe40a`) — the hook command is a silent no-op when
  its script is absent. FR-006. Check: the same test, section 3.

## Phase 3 — Proof

- [x] T020 Implemented (tree `5add6fb`) — live on dev, claude + grok, hub DB
  counts in `spec.md` §Proof.

## Phase 3b — The wrapper

- [x] T040 Implemented (`02d709a`, `2205be3`) — `scripts/spool-agent.sh`;
  one-post-per-(session, event, text) in `spool-mirror.py`.
  Check: `bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-agent.sh`
  -> `27 passed, 0 failed`; `test-spool-mirror.sh` -> `48 passed`.
- [x] T041 Implemented (engine `2946445`, overlay `d68b8c0`) — the box
  spawner starts claude / grok through `BOX_AGENT_WRAPPER`.
  Check: engine `tests/test-spawn-wrapper.sh` -> `8 passed, 0 failed`.
- [~] T042 Partial — takes effect for new spawns once `/opt/csi/csi-spl`
  carries `spool-agent.sh` (on 2026-09-25 14:25Z that checkout was 24 behind
  with 22 files of another lane's uncommitted edits; until then the spawner
  falls back to the plain CLI). An installer for other users: CLE-34966.

## Phase 3c — Attribution (FR-009..FR-012)

- [x] T050 Done (1e438b7) — migration 0040: `messages.typed_by`, `box_operators` (RLS as 0037). Applied on dev AND prd with `do_spl_db_bootstrap` before the 0.5.5 bump; `do_spl_db_query` shows the column + table on both (6 rows each).
- [x] T051 Done (4336d9f) — hub: frame `typed_by`; FR-010 (roster, membership, binding) refuses with `typed_by_not_bound` (403) and stores nothing; stored, in the view API and the WUI frame, never to a box. Test `internal/hub/typed_by_test.go` (memory + postgres).
- [x] T052 Done (4336d9f, b079601) — `spool send --typed-by HUM-n` on the dial, submit-socket and pending paths (`<pending>.json.typed_by`); `do_spl_box_operator_{grant,revoke,list}` (owner / admin or `operator` grants a member).
- [x] T053 Done (19daf4a, shipped in 0.5.5) — web UI: the row renders as the human + "via terminal <agent>" badge; e2e `tests/e2e/typed-by.test.mjs` in the 10 ci wui-e2e job.
- [~] T054 Partial — mirror: `--typed-by <operator>` on prompts (no prefix),
  re-post the old way on `typed_by_not_bound` / an old binary; `operator`
  subcommand; `spool-agent --operator`. Check: `test-spool-mirror.sh` -> 62,
  `test-spool-agent.sh` -> 29. Missing: the live proof once the hub side is
  deployed (CLE-34976: migration 0040 + grant action + version bump).

## Phase 4 — Rollout

- [~] T030 Partial (2026-09-25 13:02Z, owner go "well go than") — the
  `hooks` key of `30-spool-mirror.agent.json` merged into the agent user's
  `~/.claude/settings.json` (backup `settings.json.bak.20260925T130215Z`, no
  other key changed). Missing: claude-config still HOLDS that file (edited
  locally since the last apply: `switchModelsOnFlag`, `hooks`) until those
  edits are carried into the overlay. Running Claude sessions picked the
  hooks up without a restart: 6 seats posted by 13:25Z (`.mirror/mirror.log`).
  Check: `do_spl_desk_mirror_check` -> `hooks_in_settings: true`; the
  configured command as CLE-3496 -> `OK answer -> HUM-9 task f3b889a8-…`.
- [x] T031 Implemented (2026-09-25 13:01Z) — the `box-desk` sidecar
  restarted from the main checkout (`do_spl_desk_down` + `do_spl_desk_up`,
  seat CLE-3496; the other seats kept their state and mute flags). Check:
  `do_spl_desk_mirror_check` -> `sidecar_notify: /opt/csi/csi-spl/…`, `warn: []`,
  12 seats mirroring.
- [ ] T032 Planned — the ad hoc backfill of 2026-09-25 12:16Z put each
  transcript in a new DM topic. Adopt that topic for the mirror without
  re-uploading: `spool-mirror.py remember <seat>/spool/<agent> HUM-9 <task>`
  (as the box user). A seat with no backfill yet runs
  `do_spl_desk_session_upload`, which lands in the mirror's topic by itself.

<!-- version: 1.0.0 · updated: 2026-09-25 · last-edit: 2026-09-25T16:45:00Z -->
