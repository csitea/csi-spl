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
- [x] T042 Implemented (2026-09-25 ~16:50Z) — `/opt/csi/csi-spl` carries
  `spool-agent.sh`, so the spawner starts claude / grok through it
  (`BOX_AGENT_WRAPPER`, overlay `d68b8c0`). An installer for other users: 037.
- [x] T043 Implemented (csi-spl `963234d2`, `50009c82`; engine `f25fe4f`,
  CLE-34980) — agy (antigravity) gets the wrapper: `spool-agent.sh ... agy`
  seats it on every env with the desk (dev,prd), splits the notice strip
  right after seating and before the CLI paints (for claude and grok too),
  marks the pane `@spool_strip 1`, and merges the named hook `spool-mirror`
  (PreInvocation + Stop -> `spool-mirror.py hook --agy pre|stop`, CLE-3496's
  reader, `680a6211`) into `~/.gemini/config/hooks.json`, keeping other named
  hooks; a non-JSON file is moved to `hooks.json.bad.<ts>`. The engine's
  spawn-agy and restore-agy start agy through `BOX_AGENT_WRAPPER`.
  Check: `test-spool-agent.sh` -> `46 passed, 0 failed`; engine
  `test-spawn-wrapper.sh` -> `11 passed, 0 failed`. Live (n=1, 2026-09-25
  17:49-17:55Z, test window AGY-34980): strip `%213` present when agy
  started, tailing the dev AND prd logs; seated dev + prd (prd sidecar
  roster lists it); `ENV=dev do_spl_desk_probe DRY_RUN=0` every step PASS
  (DM shown in the strip, typed into agy); `do_spl_desk_mirror_check` ->
  `OK agent-typed -> HUM-4` then `OK answer -> HUM-4` (242 chars). Not proven on
  prd: no web UI DM was sent there.
- [ ] T044 Planned — agy windows spawned BEFORE engine `f25fe4f` (AGY-3493..
  3497) run plain agy: they pick up the hook file (it is global) but have no
  wrapper-made strip (unchecked: the desk should add one on the next delivery, 8c8e1530).
  Restore them through `restore-agy.sh` to get the full harness.

## Phase 3c — Attribution (FR-009..FR-012)

- [x] T050 Done (1e438b7) — migration 0040: `messages.typed_by`, `box_operators` (RLS as 0037). Applied on dev AND prd with `do_spl_db_bootstrap` before the 0.5.5 bump; `do_spl_db_query` shows the column + table on both (6 rows each).
- [x] T051 Done (4336d9f) — hub: frame `typed_by`; FR-010 (roster, membership, binding) refuses with `typed_by_not_bound` (403) and stores nothing; stored, in the view API and the WUI frame, never to a box. Test `internal/hub/typed_by_test.go` (memory + postgres).
- [x] T052 Done (4336d9f, b079601) — `spool send --typed-by HUM-n` on the dial, submit-socket and pending paths (`<pending>.json.typed_by`); `do_spl_box_operator_{grant,revoke,list}` (owner / admin or `operator` grants a member).
- [x] T053 Done (19daf4a, shipped in 0.5.5) — web UI: the row renders as the human + "via terminal <agent>" badge; e2e `tests/e2e/typed-by.test.mjs` in the 10 ci wui-e2e job.
- [x] T054 Implemented (`348fe5d`, `bedcd7f`) — mirror: `--typed-by <operator>`
  on prompts (no prefix), re-post the old way on `typed_by_not_bound` / an old
  binary; `operator` subcommand; `spool-agent --operator`. Live on dev
  2026-09-25 16:53-16:56Z (release 0.5.5, desk sidecar rebuilt, desk operator
  HUM-17 bound by CLE-34976): DB rows `from_id=CLE-3496, typed_by=HUM-17`, n=2
  in topic `0eabdd04-…`. `bedcd7f` fixes a box-wide silent outage (16:43-16:58Z):
  the hook took the script's file owner for the box user. Check:
  `test-spool-mirror.sh` -> 65; fleet posting again from 16:58:05Z.

## Phase 3d — Recipient, authorship, agy, speed (FR-013..FR-016)

- [x] T060 Implemented (`680a6211`, `ea35f7c4`) — FR-013 per-env human (desk
  `mirror-to`: dev HUM-9, prd HUM-10), FR-014 `[typed by <agent>]`, FR-015
  `hook --agy`, FR-016 parallel seats. Proof dev + prd (tree 680a6211, n=5
  per env, DB): prompts `typed_by` = the env owner, answers unclaimed, the
  CLE-001 doorbell `[typed by CLE-001]`. Check: `test-spool-mirror.sh` -> 78,
  `desk-mirror-actions.tst.sh` PASS.
- [x] T061 Implemented (`bedcd7f`) — FR-016 box user from the checkout root.
- [x] T062 Implemented (`ff5880c1`) — FR-014: a doorbell naming a HUMAN sender
  (the desk announcing that human's own message to a pane not on the
  alternate screen, e.g. agy) is dropped, never posted back as
  `[typed by HUM-n]` (prd topic 4335f075, reported by CLE-34973).
  Check: `test-spool-mirror.sh` section 4.
- [x] T063 Implemented (`fb5ecb44`) — FR-001: `human_text()` strips CLI-injected
  blocks (`<system-reminder>`, `<task-notification>`, `<local-command-*>`,
  `<command-*>`, `<bash-*>`, closed or cut off) and drops injection-only
  prompts, in the hook and before every post. Live leak measured by CLE-100
  (dev 166 rows, prd 18 agent/human pairs); after 19:25:05Z 0 on both envs
  (DB, n=1 probe pair per env). Check: `test-spool-mirror.sh` section 16
  (85 passed). Open: purge of the leaked rows - owner decision.

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
- [x] T032 Superseded (2026-09-25) — the mirror now follows the DM peer or the
  desk human per env (FR-013), so adopting the 12:16Z backfill topics is moot.
  Was: the ad hoc backfill of 2026-09-25 12:16Z put each
  transcript in a new DM topic. Adopt that topic for the mirror without
  re-uploading: `spool-mirror.py remember <seat>/spool/<agent> HUM-9 <task>`
  (as the box user). A seat with no backfill yet runs
  `do_spl_desk_session_upload`, which lands in the mirror's topic by itself.

<!-- version: 1.0.0 · updated: 2026-09-25 · last-edit: 2026-09-25T19:55:00Z -->
