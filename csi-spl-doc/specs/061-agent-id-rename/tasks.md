# 061: agent id rename: tasks

Spec: [spec.md](spec.md). Plan: [plan.md](plan.md).
Deadline marker: legacy ids end `2026-10-02T20:59:59Z` (spec section 0).

## 0. Plan (CLE-77952)

- [x] T001 Spec, plan, tasks; inventory with commands; owner questions Q1-Q7

## 1. Wave A: accept both forms (parallel, file-disjoint)

- [ ] T010 L1 `internal/agentid`: grammar, letter map, legacy grammar, `LegacyUntil = 2026-10-02T20:59:59Z`, injectable `Now` (FR-001, FR-004) + tests
- [ ] T011 L1 the 6 Go regex sites call `agentid` (FR-001)
- [ ] T012 L1 rdb migration: widen CHECKs in 0001/0005/0047/0096/0097 to both grammars; table `agent_id_aliases` (FR-006) + PG test
- [ ] T013 L1 alias resolve at the edge (send, recv, lease, lane, ask, `cmd/spool` flags); FR-003 refusal after the deadline; `GET /api/v1/agent-aliases`
- [ ] T014 L1 deploy hub dev+prd; live check: `c-004` and a legacy id both accepted
- [ ] T020 L2 `src/utils/agent-id.mjs` + the FR-005 pin test against the Go constant
- [ ] T021 L2 the 15 WUI regex sites call it; mention chips for `@c-004@<box>`
- [ ] T022 L2 deploy WUI dev+prd; e2e on the generated bundle
- [ ] T030 L3a `spool-env.inc.sh`: `spl_is_agent_id`, `spl_is_participant_id`, `SPOOL_LEGACY_ID_UNTIL`, `SPOOL_NOW` + FR-005 pin test
- [ ] T031 L3a spawn-agents scripts, libs and python parsers use the helpers; window parsing accepts `c-NNN`
- [ ] T032 L3b the about 40 `run/spl-*.func.sh` validators use the helpers (not the rotation files)
- [ ] T040 Deploy gate (FR-007): dev+prd live, satellite pulled and `spool` rebuilt

## 2. Wave B: emit the new form

- [ ] T050 L4 `next-agent-id.sh`: cursor, bands `004-699` / `700-899` / `900-999`, rollover, the 5 skip rules, 24 h quarantine (FR-008) + tests
- [ ] T051 L4 `do_spl_agent_id_retire` (spec 3.6) + the `/exit-clean` hook + test
- [ ] T052 L4 skills: count regex and examples (FR-010)
- [ ] T060 L5 `do_spl_agent_id_map` (DRY_RUN default; written once) + test
- [ ] T061 L5 `do_spl_agent_id_rename` (FR-011) + test; run it for every live non-role agent (owner go for the prd hub rows)
- [ ] T062 L5 `do_spl_agent_id_legacy_report` (FR-013)
- [ ] T070 L6 rotations claim `c-001` / `c-002` / `c-003`; `lease.conf` updated; satellite done before 20:00Z
- [ ] T080 L7 docs: grammar, fleet roles, identity map, ISGs, README, repo CLAUDE.md count command; each points at spec 061 section 0

## 3. Cutoff and removal

- [ ] T090 L8 at 21:00Z: legacy report on every machine shows 0
- [ ] T100 L9a api: remove the alias path; convert `_test.go` fixtures
- [ ] T101 L9b wui: remove the alias path; convert test fixtures
- [ ] T102 L9c orc: remove the alias path and the `old -> new` spool symlinks; convert test fixtures
- [ ] T110 L10 hub `seated_at` + WUI "new holder since" divider for reused ids
