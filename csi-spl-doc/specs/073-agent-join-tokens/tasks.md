# 073 agent join tokens: tasks

Authority for what is built (`spec.md` holds the behaviour). Each task names
its lane, the files it owns and its done check. Status vocabulary:
`../README.md` §2.3. Open owner questions: `spec.md` section 8 (Q1-Q4); every
task builds behind the recommended default.

- [x] T001 **spec** (c-179, spec 072 T012 / L17): `spec.md` and this file.
- [ ] T002 **rdb**: the `agent_join_tokens` migration (next free prefix), RLS,
      `pins_history.reason` += `join`, `wui-revoke`. Done: the migration lint
      and the postgres store tests are green.
- [ ] T003 **hub** (after T002): store methods, the five routes of spec 4.3,
      `wire.JoinPayload`, the refusal table, the redeem window. Done: AC1-AC7
      green on postgres (`PRE_PUSH_TIER=full ./run -a do_check_pre_push`).
- [ ] T004 **CLI** (after T003): `spool join`, token from env / stdin, usage
      line. Done: a CLI test against a test hub seats a box with no root key.
- [ ] T005 **orc** (after T004): `do_spl_desk_pin` join mode and its test in
      `desk-pin.tst.sh`; then `install.sh --join` with the lane that holds the
      installer. Done: hermetic suite seats via a stub `spool join`.
- [ ] T006 **WUI** (after T003): New join token, open tokens list, Revoke
      seat, the guide's join line (spec 4.6). Done: typecheck + e2e for
      mint / copy / revoke, then AC8 live on dev and prd.
- [ ] T007 **close 037 T005** and 072 A5 once AC8 is green; Q3 (`for_human`)
      as its own task if the owner keeps the default.

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T11:35:00Z -->
