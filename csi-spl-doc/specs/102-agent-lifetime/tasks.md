# 102 Agent lifetime: tasks

What gets built. [spec.md](spec.md) v1.0 holds the behaviour; its section 15
records the panel consensus. Each task is one lane: one agent, one small
task, the files it owns, the test that proves it, its control, and how it is
proven live. Topic: t1 `637269bb-d97b-4861-b45e-87200652b169`. Owner rule
(consensus, then build, no go): the build starts now.

Paths: `orc/` = `csi-spl-orc/src/bash/`, `rdb/` =
`csi-spl-rdb/src/sql/postgres/spool-hub/`, `api/` =
`csi-spl-api/src/go/spool-hub-api/`, `wui/` = `csi-spl-wui/`, `doc/` =
`csi-spl-doc/`.

## Rules for every task

- **Gate before every push, and again after the mandatory rebase**: `cd
  csi-spl-iac && ./run -a do_check_pre_push`, plus the tree's own gate (repo
  `CLAUDE.md`): `orc/` -> `bash csi-spl-orc/src/bash/tests/run-all-tests.sh`
  and `./run -a do_check_pre_push_lint`; `api/`, `rdb/` ->
  `PRE_PUSH_TIER=full ./run -a do_check_pre_push` (store tests on Postgres)
  and the clean-code gate for new Go functions; `wui/` -> `pnpm run
  typecheck` and the e2e of the touched view; `doc/` -> `do_check_dist_hygiene`.
- **Nothing ad hoc**: every step is a `do_<verb>_<noun>` action in
  `orc/run/<verb>-<noun>.func.sh` plus its test in the same commit; every cron
  line is installed by an `_install_cron` action.
- **Test seams, never a live pane**: reuse `ROTATE_SPAWN`, `ROTATE_TMUX`,
  `ROTATE_KILL`, `WD_PS_CMD`, `WD_SEND`, `WD_TAKEOVER_CMD`, `LEASE_PROC_ROOT`;
  new scripts take the same kind of seam. Tests run under the `SPOOL_TEST`
  guard and never on the live spool root.
- **Each test has a control**: one input flipped so the check DOES fire (or
  does NOT), so a test cannot pass vacuously. The table names it.
- **Live changes on the boxes** (a cron, a settings entry, a loop restart) go
  through the orchestrator on each box with the exact command; nothing on
  another box is changed by a lane directly. Every brief that touches GCP
  carries the per-env service-account rule (repo `CLAUDE.md`).
- **Migration numbers**: on `8f32ffd8` the last is `0143_messages_search_index.sql`.
  Check again at build time (`ls rdb | tail -1`) and take the next free one.
- Commits: the repo's canonical author (repo `CLAUDE.md`), no AI trailers,
  explicit pathspecs. No personal names, box tags or hosts in shipped files.

## Order

```
P0  T001 flags + autoupdater env ─► T002 mode check
    T003 id lock in every actor ──┬─► T008 restart action ─► T009 session-age rule ─► T010 over-2h backlog
    T004 S9 + input.log ──────────┤        ▲      ▲
    T005 done / rebirth markers ──┘        │      │
P1  T006 handoff files ────────────────────┘      │
    T007 wip job + pre-push exemption ────────────┘
P2  T011 settings (rdb+store) ─► T012 admin messages (hub+wui) ─► T016 S2 buttons (box side)
    T013 hub handoff copy (after T006, T011)
    T015 seats onto the path (after T003, T009)
P3  T017 box beat + fence ─► T018 guests + lane CAS (after T007, T013)
    T014 reboot path + drill (after T008, T017)
    T019 controlled CLI update (after T002, T004)
    T020 shared memory
    T021 doc (fleet-roles, 060/093 status) after T015; T022 live drill after T018
```

T001, T003, T004, T005, T006, T011 and T020 start in parallel; they own
disjoint files.

## Tasks

| id | phase | task | owns (files) | test | control | deploy + prove |
|---|---|---|---|---|---|---|
| **T001** ✓ `25ecce6d` | P0 | **Flags and the updater off.** Restore `spool_claude_perm_flags` (060 FR-061) and export `DISABLE_AUTOUPDATER=1` in the launch path; add the `env` block to `00-fleet.json`; every spawn/restore script calls the helper (spec 9.1, 9.2) | `orc/features/spawn-agents/lib/spool-env.inc.sh`, `orc/features/spool-install/assets/claude/settings/00-fleet.json`, the `spawn-*.sh` / `restore-*.sh` call sites, `orc/features/spawn-agents/tests/test-spawn-dry-run.sh` (new cases) | dry-run spawn of each harness: the command line carries the helper's flags and the env carries `DISABLE_AUTOUPDATER=1`; `grep -rn 'spool_claude_perm_flags()' orc/` -> 1 | a spawn script that bypasses the helper (fixture copy with a literal flag) is caught by the test's grep | lands; installed by `do_spl_box_update` on each box; the proof of 9.1: `ls ~/.local/share/claude/versions` as the agent user unchanged for 24 h while a newer version exists, n = 1 per box |
| **T002** | P0 | **Mode check.** `do_spl_agent_mode_check`: per live agent process, flags (`cmdline`), `DISABLE_AUTOUPDATER` (`environ`), the settings keys of 9.2; re-assert from `00-fleet.json`, one report per mismatch; called by spawn before it starts (refuse when still wrong) | `orc/run/spl-agent-mode-check.func.sh`, `orc/tests/agent-mode-check.tst.sh` + `/proc` fixtures | fixtures: a bypass process + good settings -> clean; `defaultMode=auto` -> re-asserted + one report; a process without the flag -> reported | the good fixture with ONE key flipped fails; the flipped fixture after re-assert passes | `./run -a do_spl_agent_mode_check` on each box by the orchestrator: 0 mismatches, or each one named and fixed |
| **T003** ✓ `c66c8ea2` `6679cc11` | P0 | **One id lock.** `spl_agent_id_lock <id>` (`<id>/lifetime/restart.lock`, `flock -n`, exit 4) taken by the takeover, `do_spl_lane_restart`, both rotations, `do_spl_peer_restart`, the identity restore and the reaper; every one logs its phases to `rotate.log`; the reaper skips held-out ids (spec 4.2, 13) | `orc/run/spl-rotate-lib.func.sh` (the helper only), the lock call in `spl-wd-takeover`, `spl-lane-restart`, `spl-orch-rotate`, `spl-dispatch-rotate`, `spl-peer-restart`, `spl-agent-identity-restore`, `spl-agent-id-reap`; `orc/tests/agent-id-lock.tst.sh` | two actors on one id at once: exactly one runs, the other exits 4; the watchdog's `spl_wd_rotating` sees a lane restart in `rotate.log` | the same two actors on two different ids both run | lands; each box's crons pick it up at their next run (detached `csi-spl-desk-cron` checkout); prove with one dry-run lane restart and `tail rotate.log` |
| **T004** ✓ `65bf7c74` | P0 | **S9 stuck.** `situations/s9.sh` (spec 8.1, 8.2); every poke sender appends `<ts> <kind>` to `<id>/lifetime/input.log`; the watchdog pokes an un-poked unread file once; non-claude harnesses use conditions 1-4 at 2 x `stuck_min`; the S7 fast path stays | `orc/features/watchdog/situations/s9.sh`, its wiring in `orc/run/spl-watchdog.func.sh` (order + act only), `orc/features/spawn-agents/scripts/spool-send.sh` (the input.log line only), `orc/tests/wd-situations.tst.sh` (new section), fixtures under `orc/tests/fixtures/wd-situations/s9-*` | spec 8.3: the hit fixture -> `HIT S9` | spec 8.3 controls 1-6 (control 1: today's S7 misses the same pane) | lands; the watchdog picks it up at its next keeper restart on each box; prove: `WD_TICKS=1 ./run -a do_spl_watchdog` -> no S9 on a healthy fleet, and one scratch lane with a planted unknown dialog -> S9 within `stuck_min` + 1 tick |
| **T005** ✓ `a651ca97` | P0 | **Done and rebirth markers.** (Built: the marker is written by `tmux-close-window.sh` (`--defer` -> `done`, `--rebirth` -> `rebirth`), the script the exit-clean skill runs; `spl_wd_gather` fills the ctx; live dry-run drill 2026-10-07 n=1 per case.) `/exit-clean --rebirth` writes `lifetime/rebirth`; plain `/exit-clean` keeps removing the rundir and also writes `lifetime/done`; S3 widened to a gone pane with an open registry row; a `done` older than `session.json` is ignored (spec 4.3) | `orc/features/watchdog/situations/s3.sh`, the exit-clean skill script (marker lines only), `orc/tests/wd-situations.tst.sh` (S3 section) | rundir gone -> no hit; rebirth marker -> verdict `rebirth`; no marker, pane gone -> `HIT S3` | a stale `done` older than the session -> still `HIT S3` | lands; prove on a scratch lane: `/exit-clean` -> never restarted; `/exit-clean --rebirth` -> marker present |
| **T006** [x] `5342fcd8` | P1 | **Handoff files.** `do_spl_agent_handoff` (compose under flock, tmp + rename, `handoff.prev.md`, sections of 5.2, scrubbed terminal lines) and `do_spl_agent_handoff_note SECTION=...` (agent files only); the PostToolUse hook triggers a detached compose at most every 60 s | `orc/run/spl-agent-handoff.func.sh`, `orc/run/spl-agent-handoff-note.func.sh`, `orc/features/spawn-agents/scripts/spool-agent-hook.sh` (the trigger only), `orc/tests/agent-handoff.tst.sh` | compose with a fixture lane: every section present; a note survives 100 composes byte for byte; KILL mid-compose (seam) leaves the previous complete file | a compose without the lock (seam off) racing a second compose loses a section: the test proves the lock matters | lands; hooks re-installed by `do_spl_agent_hooks_install` via the orchestrator; prove: a fresh lane's `handoff.md` refreshes within 60 s of a tool call |
| **T007** ✓ `df8aef3f` | P1 | **Wip job + pre-push exemption.** `do_spl_lane_wip_push ID=<id>`: temp index, canonical author, `--force-with-lease` to `refs/heads/wip/<lane branch>` only (refuses any other refspec); the pre-push hook skips a push whose refs are all `refs/heads/wip/*`; run by the watchdog at 30 min, 1 h, 1 h 50 when the diff changed (spec 5.4) | `orc/run/spl-lane-wip-push.func.sh`, `orc/features/spawn-agents/hooks/pre-push` (the exemption only), `orc/tests/lane-wip-push.tst.sh` (a bare remote) | dirty tree -> one wip commit on the remote, the lane's index and HEAD unchanged; a second run with no change -> no push; mid-rebase -> `ORIG_HEAD` + a patch file | a refspec of `master` -> refused, exit 1; a mixed push (`wip/*` + a branch) still runs the gate | lands; prove on a scratch lane: `git ls-remote origin 'refs/heads/wip/*'` shows its ref; CI shows no run for it (`gh run list --branch wip/<branch>` -> 0) |
| **T008** | P1 | **The restart action.** `do_spl_agent_restart` (spec 4.1): lanes GATE, RETIRE, CLEANUP, WIP, HANDOFF (consume the marker), SEED (`session.json`), SPAWN, REPORT, LOG; seats start-first with ack and `rotate.hold`; `RESTART_SLOTS`; ONE counter `restart_max_per_hour` replacing both 093 counters; a hold that does not expire; `task_restart_max` and `rebirth_max` (env defaults until T011); the watchdog calls it instead of the takeover | `orc/run/spl-agent-restart.func.sh`, `orc/run/spl-watchdog.func.sh` (`spl_wd_takeover` -> the new action; the counter), `orc/tests/agent-restart.tst.sh` | with the ROTATE seams: a lane rebirth ends in one process, same id and worktree, wip pushed before spawn, the rebirth marker consumed; a seat: new acks before old retires; 4 lanes restart at once on 4 slots; the 4th restart in an hour -> held out, still held 2 h later | a 3rd restart in an hour runs (limit not reached); a crash right after a rebirth is reported as `S3`, not `rebirth`; a failed lane spawn leaves no process and the next tick retries | lands; the watchdog loop restarted on each box by the orchestrator; prove: one scratch lane `CAUSE=rebirth`, `rotate.log` shows `RS-*` phases and the orchestrator gets one `REBORN` line |
| **T009** | P1 | **Session-age rule.** `session.json` read by the watchdog; at 1 h inject + poke the rebirth request, at 1 h 50 the final notice, at 2 h `CAUSE=hard-end` (R3: no human hold at 2 h); seats start at `HARD_END - WD_START_WAIT - ROTATE_ACK_TIMEOUT`; the seed's lifetime text (spec 3 row 0) in every spawn template | `orc/features/watchdog/situations/s10-age.sh` (verdict only), its act branch in `orc/run/spl-watchdog.func.sh`, the seed templates under `orc/features/spawn-agents/`, `orc/tests/wd-situations.tst.sh` (age section) | fixtures at 59, 61, 111, 121 min: nothing, request, final, hard end; a resumed process (new pid, same `session.json`) keeps its age | the 121 min fixture with a `.human-hold` still ends (R3); the 61 min fixture with a human active gets no keystroke | lands; prove: a scratch lane spawned with `session.json` backdated 59 min gets the request within 2 ticks |
| **T010** | P1 | **The over-2 h backlog (A4).** Turn the age rule on for lanes on each box: `RESTART_SLOTS` at a time, oldest session first, starts 60 s apart (Q9) | the switch in `<spool root>/dispatch/wd.conf` (via an action), `doc/specs/102-agent-lifetime/rollout-<date>.md` | dry run first: the list of ids it would reborn, oldest first | `WD_AGE=0` -> nothing reborn | the orchestrator on each box flips it; the lane records per box: n reborn, n failed, time to clear; `do_spl_lane_map` shows no lane over 2 h afterwards |
| **T011** | P2 | **Done** (`ee586a83`, rdb 0145 on dev and prd; the watchdog read waits for T008, the hub box read via `store.ReadLifetimeSettings` for T012). **Settings.** rdb: 5 columns on `agent_lifecycle_config` (spec 11.1); store keys and bounds; read from the operator workspace only; the box read caches 5 min | `rdb/<next>_agent_lifetime_settings.sql`, `api/internal/store/agent_lifecycle.go` (+ postgres, test), `orc/run/spl-watchdog.func.sh` (the settings read only, after T008) | memory + Postgres: defaults when NULL, bounds enforced, a non-operator workspace's row ignored | a value out of bounds -> rejected; a non-admin write -> 403 | `ENV=dev DRY_RUN=0 ./run -a do_spl_db_bootstrap`; prd: the exact command to the orchestrator; prove with the catalog query on dev and prd |
| **T012** | P2 | **Admin messages.** Message type "agent needs the admin" (web app DM to each operator admin + email via `internal/mail`), the buttons of spec 11.2, one hub event per press, read by the box; the Workspace settings page shows the 5 settings | `api/internal/hub/agent_admin.go` (+ test), `wui/` the message card and the settings block (lazy), its e2e | one message per (id, cause); a press writes one event; a second press is a no-op | a non-admin press -> 403; a message for a resolved cause is not re-sent | hub via wf 20, WUI via wf 30, dev then prd; prove with a planted cause on dev: the DM, the email (mail log) and the event |
| **T013** | P2 | **Hub handoff copy.** Move the KMS seal to a shared package; the box sends a changed, scrubbed `handoff.md` next to the lane row; read back only by a watchdog under 10.2 and the operator admin; keep 3, prune 7 days after done | `api/internal/seal/` (moved from `internal/marketing`), `api/internal/hub/handoff_copy.go` (+ test), `rdb/<next>_agent_handoff_copy.sql`, `orc/run/spl-agent-handoff.func.sh` (the send only, after T006) | round trip: send, read back by a box key, equal; a file with a planted key pattern -> scrubbed; one that still matches -> not sent | a read by a member who is not an admin and not a box -> 403 | hub via wf 20 dev then prd; prove: one lane's copy present on dev, `do_spl_db_query` shows a sealed blob, not plain text |
| **T014** | P3 | **Reboot path + drill.** The watchdog restarts open, not-done agents whose `running_box` is this box after a boot (cause `reboot`, new session, not `--resume`); after the drill the `@reboot` boot-restore cron line is removed by its installer | `orc/run/spl-watchdog.func.sh` (the boot branch only), `orc/run/spl-agent-boot-restore-install-cron.func.sh` (removal), `orc/tests/wd-reboot.tst.sh`, `doc/specs/102-agent-lifetime/drill-reboot-<date>.md` | simulated boot: every open agent restarted once, a done one not, a guest-elsewhere one not | the same boot with `running_box` = another box -> nothing started | drill on one box by the orchestrator (owner's go only for the reboot itself), n >= 1: agents back, count and time recorded |
| **T015** | P2 | **Seats onto the path (R11).** The rotations' crons stop being the trigger: the age rule triggers seats with `SEAT_STAGGER`; measure each box's crontab first; remove `orch-rotate`, `dispatch-rotate`, `dispatch-heal`, `peer-restart` lines by their installers | the installers' `CRON_REMOVE=1` runs via an action, `orc/run/spl-watchdog.func.sh` (seat stagger only), `orc/tests/wd-situations.tst.sh` (seat section) | 4 seats of one box over age: started at least 15 min apart, each start-first with ack | a seat younger than its slot -> not started | the orchestrator on each box: crontab before/after (`crontab -l \| grep -oE 'csi-spl:[a-z-]+' \| sort -u`), then one hour of `rotate.log` with one `RS-` per seat. Dropped if the owner flips R11 to (b) |
| **T016** | P2 | **S2 buttons, box side.** S2 sends the admin message (T012) instead of the owner DM; `login-reset` restarts held-out agents of that OS user + harness; an S2 re-hit after it re-arms the hold and does not count; "no tokens left" pushes the lane's wip ref | `orc/features/watchdog/situations/s2.sh` (unchanged detection), the S2 act branch in `orc/run/spl-watchdog.func.sh`, `orc/tests/wd-situations.tst.sh` (S2 section) | login fixture -> one admin message, no restart; a planted `login-reset` event -> one restart each | an S2 re-hit after the reset -> counter unchanged | lands after T012 is live; prove on dev with a scratch agent whose login is expired |
| **T017** | P3 | **Box beat + fence.** `box_beats` table and frame; the watchdog beats every tick and reads the ack; no ack for `box_down_min` -> fenced: start nothing, TERM lanes after their wip push, one admin message | `rdb/<next>_box_beats.sql`, `api/internal/hub/box_beat.go` (+ test), `orc/run/spl-watchdog.func.sh` (beat + fence only), `orc/tests/wd-fence.tst.sh` | hub stub silent for 2 min -> fenced, lanes TERMed, seats untouched, nothing started | hub stub answering -> never fenced; a 1 min gap -> not fenced | migration + hub dev then prd; prove: `box_beats` rows per box every 30 s on dev and prd; one fence drill with the hub blocked for one box (owner's go) |
| **T018** | P3 | **Guests + lane CAS.** `running_box` on the lane row (keyed by home); CAS with the second witness (branch not moved); guest rundir `guest/<id>@<home>/`, window `<id>@<home>`, worktree from branch + wip ref, handoff from the hub copy; hub routes `<id>@<home>` to `running_box`; back home at the next rebirth; a surviving partitioned copy -> killed, `-fenced-` ref | `rdb/<next>_fleet_lane_running_box.sql`, `api/internal/store/fleet_lane*.go`, `api/internal/hub/` routing, `orc/run/spl-agent-restart.func.sh` (guest branch, after T008), `orc/tests/wd-guest.tst.sh` | two simulated boxes: box A down -> exactly one of B/C runs the lane; A back -> not started at A; next rebirth -> home | the lane branch moved within `box_down_min` -> no CAS; a box without the harness -> no CAS | migration + hub dev then prd; prove in the T022 drill |
| **T019** | P3 | **Controlled CLI update.** `do_spl_cli_update` (hub lease `cli-update`, install beside, test agent with `do_spl_cli_selftest`, symlink switch, roll back on fail) and its `_install_cron` (`csi-spl:cli-update`, 02:00-05:00 UTC) | `orc/run/spl-cli-update.func.sh`, `orc/run/spl-cli-update-install-cron.func.sh`, `orc/run/spl-cli-selftest.func.sh`, `orc/tests/cli-update.tst.sh` | stub installer: a good version -> switched, the live agents untouched; two boxes -> one updates per window | a test agent that shows a dialog -> rolled back, one admin message, symlink unchanged | the orchestrator installs the cron on each box; prove the next night: `cli-update` lease rows, one box per night, `readlink ~/.local/bin/claude` per box |
| **T020** ✓ `51835a5f` | P3 | **Shared memory.** Hub table + `spool memory add/show/index`; merge by normalised title; seeds get the index | `rdb/<next>_shared_memory.sql`, `api/internal/store/shared_memory*.go`, `api/cmd/spool/memory.go`, their tests | add twice with the same title -> one lesson, merged text; index lists titles only | a different title -> two lessons | hub dev then prd; CLI via the box update; prove: one lesson added on dev and read back from another box |
| **T021** | doc | **Fleet-roles and status.** SPEC-spool-fleet-roles.md: the lifetime rule, the restart path, the seat trigger; 060 and 093 status lines pointing to 102 | `doc/doc/md/SPEC-spool-fleet-roles.md`, `doc/specs/060-role-rotation/spec.md` and `doc/specs/093-agent-watchdog/spec.md` (status lines only) | `do_check_dist_hygiene`, `lint-mdlinks` | - | lands on master |
| **T022** | drill | **Live drill.** On both boxes: rebirth at 1 h (n >= 3), hard end at 2 h (n >= 3), S9 on an unknown dialog (n >= 3), a box down 3 min with lanes moving and coming home (n >= 1); delays recorded against the spec | `doc/specs/102-agent-lifetime/drill-<date>.md` | the drill log vs spec 3, 8, 10 | each case's control run beside it (a healthy idle lane untouched) | the orchestrator on each box runs the destructive steps; the lane writes the log |

## What blocks what

| task | needs |
|---|---|
| T001, T003, T004, T005, T006, T011, T020 | nothing |
| T002 | T001 |
| T007 | nothing (the watchdog call waits for T008) |
| T008 | T003, T005, T006, T007 |
| T009 | T008 |
| T010 | T009, T004 |
| T012 | T011 |
| T013 | T006, T011 |
| T014 | T008, T017 |
| T015 | T003, T009 |
| T016 | T012, T008 |
| T017 | T008 |
| T018 | T007, T013, T017 |
| T019 | T002, T004 |
| T021 | T015 |
| T022 | T010, T014, T018 |

## Not built here

The 068 claim cut-over (093 P2); moving the per-user memory files into the
hub (spec 16 Q7); any harness switch on a quota stop (W6 forbids it).

<!-- version: 1.0.1 · updated: 2026-10-07 · last-edit: 2026-10-07T09:10:00Z -->
