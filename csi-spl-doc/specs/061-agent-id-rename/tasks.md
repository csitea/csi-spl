# 061: agent id rename: tasks

Spec: [spec.md](spec.md). Plan: [plan.md](plan.md).
Deadline marker: legacy ids end `2026-10-03T20:59:59Z` (spec section 0; moved
from 2026-10-02 by the owner, 2026-10-02 ~06:52Z).

## 0. Plan (CLE-77952)

- [x] T001 Spec, plan, tasks; inventory with commands; owner questions Q1-Q7

## 1. Wave A: accept both forms (parallel, file-disjoint)

- [x] T010 L1 `internal/agentid`: grammar, letter map, legacy grammar, `LegacyUntil` (the cutoff instant; T016 sets it to `2026-10-03T20:59:59Z`), injectable `Now` (FR-001, FR-004) + tests
- [x] T011 L1 the 6 Go regex sites call `agentid` (FR-001)
- [x] T012 L1 rdb migration: widen CHECKs in 0001/0005/0047/0096/0097 to both grammars; table `agent_id_aliases` (FR-006) + PG test
- [x] T013 L1 alias resolve at the edge (send, recv, lease, lane, ask, `cmd/spool` flags); FR-003 refusal after the deadline; `GET /api/v1/agent-aliases`
- [x] T014 L1 deploy hub dev+prd; live check: `c-004` and a legacy id both accepted
- [x] T015 L1b rdb migration: lanes keyed on (agent_id, agent_box); back-fill the box of every existing roster, lane, ask and lease row (spec 3.3.1, FR-015) (rdb 0102, 3bffda3a; applied dev+prd 2026-10-02 07:47Z)
- [x] T016 L1b store look-ups by bare id take the box, resolve rule single box / refused when ambiguous; `spool` + HTTP API accept `c-004@<box>`; `agentid.LegacyUntil` (and its bash/WUI copies) = `2026-10-03T20:59:59Z` (af5018c3, 3bffda3a; the cutoff constant moved with L1 0d4a4cb9 / L3a 3dbb82d8)
- [x] T017 L1b PG collision test: `c-004@box-desk` and `c-004@<sat box>` coexist in roster, lanes, asks, leases; each one's mail reaches only that agent (`TestAgentAtBoxCollision` store, `TestSendToAgentAtBoxReachesOnlyThatAgent` hub; hub-pg.tst.sh green)
- [x] T018 L1b deploy hub dev+prd; migration applied with `do_spl_db_bootstrap` on both; dev `spool send` to `c-004@box-desk` and a legacy id (`/version` dev+prd = 3bffda3a v6.3.8; dev proof on probe boxes box-l1b-a/b: each c-004@box got only its mail, legacy CLE-77962 delivered, bare c-004 refused ambiguous_to_box, two c-004 lane rows)
- [x] T020 L2 `src/utils/agent-id.mjs` + the FR-005 pin test against the Go constant
- [x] T021 L2 the 15 WUI regex sites call it; mention chips for `@c-004@<box>`
- [x] T022 L2 deploy WUI dev+prd; e2e on the generated bundle
- [x] T030 L3a `spool-env.inc.sh`: `spl_is_agent_id`, `spl_is_participant_id`, `SPOOL_LEGACY_ID_UNTIL`, `SPOOL_NOW` + FR-005 pin test
- [x] T031 L3a spawn-agents scripts, libs and python parsers use the helpers; window parsing accepts `c-NNN`
- [x] T032 L3b the about 40 `run/spl-*.func.sh` validators use the helpers (not the rotation files)
- [ ] T040 Deploy gate (FR-007): wave A and L1b dev+prd live, satellite pulled and `spool` rebuilt

## 2. Wave B: emit the new form

- [x] T050 L4 `next-agent-id.sh`: per-machine cursor over `004-999` (no bands), rollover `999 -> 004`, the 5 skip rules, 24 h quarantine (FR-008) + tests (`SPOOL_ID_COUNTER` / `SPOOL_ID_ROLE_LETTERS` are the Q2 / Q1 switches; `spawn-window.sh` and `spool-agent.sh` take the new ids)
- [x] T051 L4 `do_spl_agent_id_retire` (spec 3.6) + the `/exit-clean` hook + test (`scripts/agent-id-retire.sh`, `tmux-close-window.sh --retire`; the reaper of 3.6 and the in-quarantine `reject` bounce are not built)
- [ ] T052 L4 skills: count regex and examples (FR-010)
- [ ] T060 L5 `do_spl_agent_id_map` (DRY_RUN default; written once) + test
- [ ] T061 L5 `do_spl_agent_id_rename` (FR-011) + test; run it for every live non-role agent (owner go for the prd hub rows)
- [ ] T062 L5 `do_spl_agent_id_legacy_report` (FR-013)
- [ ] T070 L6 rotations claim `c-001` / `c-002` / `c-003`; `lease.conf` updated; satellite done before 2026-10-03T20:00Z
- [ ] T080 L7 docs: grammar, fleet roles, identity map, ISGs, README, repo CLAUDE.md count command; each points at spec 061 section 0

## 3. Cutoff and removal

- [ ] T090 L8 at 2026-10-03T21:00Z: legacy report on every machine shows 0
- [ ] T100 L9a api: remove the alias path; convert `_test.go` fixtures
- [ ] T101 L9b wui: remove the alias path; convert test fixtures
- [ ] T102 L9c orc: remove the alias path and the `old -> new` spool symlinks; convert test fixtures
- [ ] T110 L10 hub `seated_at` + WUI "new holder since" divider for reused ids
