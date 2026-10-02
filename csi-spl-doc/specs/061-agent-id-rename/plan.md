# 061: agent id rename: plan

Spec: [spec.md](spec.md). Tasks: [tasks.md](tasks.md).

## 1. The order that keeps everything working

1. **Accept** (wave A): every reader accepts BOTH forms and resolves aliases.
   Nothing emits the new form yet. Wave A lanes are file-disjoint and run in
   parallel.
2. **Deploy gate**: wave A is live on dev AND prd (hub, WUI), and the `spool`
   binary plus orc tree are current on EVERY machine (home and satellite).
   This is FR-007. Nothing in wave B starts before it.
3. **Emit** (wave B): the allocator hands out `c-NNN`, the mapping is written
   once, live agents are renamed, and the roles move last via rotation.
4. **Cutoff** (`2026-10-02T20:59:59Z`): the constant flips the write paths to
   refuse legacy ids. No deploy is needed at that instant. L8 checks the count
   is 0.
5. **Remove** (2026-10-03): L9 deletes the alias path and converts the test
   fixtures.

## 2. Lanes

| lane | wave | launcher | owns (files) | must NOT touch | done when |
|---|---|---|---|---|---|
| L1 api-accept | A | claude | new `internal/agentid/` (+ tests); the 6 Go regex sites (`msg/msg.go`, `hub/channel_members.go`, `store/fleet_ask.go`, `store/fleet_lease.go`, `store/fleet_lane.go`, `store/issues.go`); `cmd/spool` flag edge; the alias resolve on send / recv / lease / lane / ask; `GET /api/v1/agent-aliases`; ONE new rdb migration (widen the 5 CHECKs to both grammars + table `agent_id_aliases`) | WUI, orc, any `_test.go` fixture rewrite (L9) | `PRE_PUSH_TIER=full ./run -a do_check_pre_push` green on PG; hub deployed dev+prd (`/version` shows the tag); `c-004` and `CLE-77952` both accepted on dev with `spool send`; with the clock pinned past the deadline, `CLE-77952` is refused with the FR-003 text |
| L2 wui-accept | A | claude | new `src/utils/agent-id.mjs` (+ unit test incl. the FR-005 pin against the Go constant); the 15 WUI regex sites; `avatar.mjs` / `agent-kind.mjs` letter map | Go, orc; `stores/roster.ts` and other files that CLE-77932 (`<ID>@<box>` WUI) still has open, unless it has landed | typecheck + unit + `test:e2e` on the generated bundle green; WUI deployed dev+prd; `@c-004@box-desk` renders as a mention chip and `@CLE-001` still does |
| L3a orc-spawn-accept | A | claude | `features/spawn-agents/lib/spool-env.inc.sh` (`spl_is_agent_id`, `spl_is_participant_id`, `SPOOL_LEGACY_ID_UNTIL`, `SPOOL_NOW`), `lib/agent-state.inc.sh`, `lib/agent-identity.inc.sh`, `scripts/agent-identity.py`, `scripts/spool-mirror.py`, `pane-scan.sh`, `agent-top.sh`, `tmux-close-window.sh`, `kill-your-self-report.sh`, `spool-mcp.sh`, `spool-fleet-relay.sh`, `spool-agent.sh`, `lane-map.sh`, `spawn-core.inc.sh` (TITLE check) | `next-agent-id.sh` (L4), `spawn-claude.sh` line 18, `run/spl-rotate-lib.func.sh` and `run/spl-dispatch-rotate.func.sh` (rotation lanes CLE-77940 / CLE-77951) | spawn-agents tests + `do_check_pre_push` green; a fake `c-004` window is counted, badged, sorted and closable |
| L3b orc-run-accept | A | qwen (mechanical, no secrets) | the about 40 `csi-spl-orc/src/bash/run/spl-*.func.sh` validators: replace each inline `^[A-Z]{2,4}-[0-9]+$` with `spl_is_agent_id` / `spl_is_participant_id` (sourced from L3a) | every file L3a owns; `spl-rotate-lib.func.sh`; `spl-dispatch-*.func.sh` (rotation lanes); `spl-orch-rotate.func.sh` | `command grep -rnE '\[A-Z\]\{2,4\}-' csi-spl-orc/src/bash/run \| wc -l` -> 0; orc suite green. Starts after L3a has landed (it sources the helper) |
| L4 allocator + retire | B | claude | `scripts/next-agent-id.sh` (cursor, band, rollover, the 5 skip rules, quarantine), new `run/spl-agent-id-retire.func.sh`, the `/exit-clean` call into it, `test-next-agent-id.sh`; band lines in 058 `spec.md` 3.3 and box.env docs; the 7 skill files (`assets/commands/*.md`: the count regex, examples) | rename of live agents (L5) | rollover, quarantine, full-band and race tests green; a dry spawn prints `c-NNN` |
| L5 map + rename live | B | claude | new `run/spl-agent-id-map.func.sh` (`DRY_RUN=1` default), new `run/spl-agent-id-rename.func.sh` (FR-011), new `run/spl-agent-id-legacy-report.func.sh` (FR-013) + tests | roles `001`-`003`; the rotation files | the alias table is written once (tsv + hub rows, dev and prd with the owner's go); every live non-role agent renamed, with the FR-011 note sent; legacy report shows only the 3 role ids |
| L6 roles | B, last | claude | the id that `spl-orch-rotate.func.sh` and `spl-dispatch-rotate.func.sh` claim, plus `lease.conf` (`LEASE_ORCH`, `LEASE_MASTER`, `LEASE_FAILOVER` -> `c-001`..`003`) | anything else | starts only after CLE-77940 / CLE-77951 have closed (they own the rotation files this hour); the next orchestrator rotation seats `c-001`; dispatch rotation seats `c-002`/`c-003` on the satellite; `LEASE_CMD=show` prints `c-00N@<box>` |
| L7 docs | B | qwen | `SPEC-spool-identity-routing.md` section 2 grammar, `SPEC-spool-fleet-roles.md`, `SPEC-agent-identity-map.md`, `isg/*agent-setup.ISG.md`, `spawn-agents/README.md`, the repo `CLAUDE.md` count command; plus one line in each pointing at spec 061 section 0 (the deadline) | code | `do_check_dist_hygiene` + `lint-mdlinks` green |
| L8 cutoff check | at 21:00Z | the orchestrator | runs `do_spl_agent_id_legacy_report` on each machine and posts the counts | code | report shows 0 legacy ids live; any non-zero line is handed to its owner |
| L9a/b/c remove alias | 2026-10-03 | claude (a: api, b: wui), qwen (c: orc) | per module: delete the legacy regex, the alias resolve and the `LegacyUntil` branch; convert the module's test fixtures through the alias table (`CLE-001` -> `c-001`, other legacy ids -> `c-9NN` fixtures); drop the `old -> new` spool symlinks | other modules | module suite green; `command grep -rnE '(CLE\|GRK\|AGY\|QWN)-[0-9]+' <module> --include=<code globs> \| wc -l` -> 0 outside spec / changelog prose |
| L10 reuse divider | after | claude | hub `seated_at` on the agent seat row + the WUI divider (spec 3.6) | | a DM with a reused id shows "new holder since <ts>" |

Outside the repo (the orchestrator, not a lane): the global `~/.claude/CLAUDE.md`
40-window count regex (FR-010), and the seed prompt template in the spawn
skills' installed copies.

## 3. Collisions with live lanes (from `lane-map.sh`, 2026-10-02 ~06:00Z)

| live lane | overlap | handling |
|---|---|---|
| CLE-77940 dispatch-hourly-rotation, CLE-77951 rotate-end-input | `spl-rotate-lib.func.sh`, `spl-dispatch-rotate.func.sh` | L3b and L6 never touch them; L6 waits for both to close |
| CLE-77924 naming-whole-stack | `<ID>@<box>` through the local stack: the same orc scripts as L3a | L3a starts after CLE-77924's files have landed, or takes its file list from that lane's worktree |
| CLE-77932 wui-agent-at-box | `<ID>@<box>` in the WUI | L2 rebases onto it and avoids its open files |
| CLE-77926 / 77927 / 77928 clean-code rounds | broad refactors in api / orc / tests | each L-lane rebases often; fixture conversion waits for L9 |

## 4. Timeline for today (UTC)

| time | step |
|---|---|
| 06:30 | spawn L1, L2, L3a in parallel |
| ~09:30 | L1 hub live dev+prd; L2 WUI live dev+prd; L3a landed. Spawn L3b. Satellite pulls trunk and rebuilds `spool` |
| ~10:30 | deploy gate (section 1, step 2) checked by the orchestrator. Spawn L4, L5, L7 |
| ~13:00 | L4 landed; L5 dry run read by the owner, then the real rename (owner go for the prd hub rows) |
| ~15:00 | L6 at the next rotations after CLE-77940 / CLE-77951 close |
| 20:59:59 | the constant cuts legacy ids off on its own |
| 21:00 | L8 report |
| 2026-10-03 | L9a/b/c, then L10 |

**Is today realistic?** For the cutoff, yes, if wave A is spawned by about
07:00Z. Each wave A lane is one module with one deploy (roughly 2-3 h with CI
and both deploys). Wave B needs about 4 h more. What is NOT realistic tonight
is the code deletion plus about 500 fixture files with green CI. That is L9,
on 2026-10-03, and it is safe to wait because the clock is pinned (FR-004).
The tight spot is the satellite. If its `spool` binary is not rebuilt before
21:00Z, its agents and its role ids `CLE-002`/`003` are refused at the
cutoff. L6 must therefore finish on the satellite before 20:00Z, or the owner
moves the constant.

## 5. Risk of rollover reuse

- **Mail to the wrong holder.** A peer replies late to `c-004` after the id
  has passed to a new agent. Mitigation: the 24 h quarantine, and the bounce
  `reject` during quarantine. Residual risk: a reply older than 24 h still
  reaches the new holder. It is visible, because the task_id is foreign, but
  it is not prevented.
- **Merged DM history** in the hub, for the same `c-004` from two holders.
  The L10 divider fixes the display. The rows are never rewritten.
- **A stuck retire** (dir not movable, window still open) only SKIPS that
  number (3.5). With 696 numbers and about 40 live agents, the band fills only
  if retire stops working entirely, and then allocation fails loudly (exit 1).
  It never reuses silently.
- **Ticket keys** (spec Q4): an agent id stops being a durable key.
  `git log --grep c-004` will return several lanes. The commit convention must
  change on the same day.
