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

## Phase 4 — Rollout (owner actions)

- [ ] T030 Planned — the hooks in the agent user's `~/.claude/settings.json`
  through the org overlay's claude-config settings fragment, applied with the
  owner's go. Live sessions take them on their next restore / spawn.
- [ ] T031 Planned — restart the `box-desk` sidecar from the main checkout
  (`do_spl_desk_up`), so its notifier records `typed` / `peer`. Until then a
  web UI message typed into a mirrored agent's prompt echoes back into the DM
  once. `do_spl_desk_mirror_check` names both conditions.
- [ ] T032 Planned — the ad hoc backfill of 2026-09-25 12:16Z put each
  transcript in a new DM topic. Adopt that topic for the mirror without
  re-uploading: `spool-mirror.py remember <seat>/spool/<agent> HUM-9 <task>`
  (as the box user). A seat with no backfill yet runs
  `do_spl_desk_session_upload`, which lands in the mirror's topic by itself.

<!-- version: 1.0.0 · updated: 2026-09-25 · last-edit: 2026-09-25T12:45:00Z -->
