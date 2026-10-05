# 092 Box power loss is routine: tasks

One task per fix, each one small lane. Topic:
`368e1565-ea4a-4ea6-8570-9cd81a7ce9ec`. Paths: `orc/` = `csi-spl-orc/`,
`doc/` = `csi-spl-doc/`. Every task runs
`bash csi-spl-orc/src/bash/tests/run-all-tests.sh` (its own `*.tst.sh` alone
while iterating) and `cd csi-spl-iac && ./run -a do_check_pre_push`. Design
for N boxes (spec section 0): no box name in code, tests or docs.

- [x] **T001 (US1, fix 1) desk-gated lease, handback hold-down, intermittent class.**
  Files: `orc/src/bash/run/spl-dispatch-lease.func.sh` (`spl_fleet_candidate`,
  `spl_fleet_role_tick`, new `spl_fleet_desk_able`),
  `orc/src/bash/tests/fleet-lease.tst.sh` (section 19),
  `doc/doc/md/SPEC-spool-fleet-roles.md` sections 4 and 4.1.
- [x] **T002 (US2, fix 2) restart policy on the tf infra containers.**
  Files: `orc/src/docker/docker-compose-tf-infra.yaml`. Takes effect at the
  next `make do-setup-app-inf`; the lane never runs that.
- [ ] **T003 (US3, fix 3) handover of in-flight relays on takeover.**
  Files: `orc/src/bash/run/spl-dispatch-lease.func.sh` (the takeover branch
  of `spl_fleet_role_tick`), `orc/src/bash/features/spawn-agents/scripts/spool-send.sh`,
  `orc/src/bash/tests/fleet-lease.tst.sh` (a new section). After T001 (same
  function).
- [ ] **T004 (US4, fix 4) owner DM on a dispatch failover.**
  Files: `orc/src/bash/run/spl-dispatch-lease.func.sh` (the
  `spl_fleet_owner_dm` call in `spl_fleet_role_tick`),
  `orc/src/bash/tests/fleet-lease.tst.sh` section 15. After T001; serialise
  with T003 (same function).
- [ ] **T005 (US5, fix 5) the 3-minute guard.**
  Files: `orc/src/bash/features/dispatch/brief-dispatcher.tpl.md`,
  `orc/src/bash/run/spl-unanswered-sweep.func.sh`,
  `orc/src/bash/tests/unanswered-sweep*.tst.sh`.
- [ ] **T006 (US6, fix 6) relay hygiene in the briefs.**
  Files: `orc/src/bash/features/dispatch/brief-dispatcher.tpl.md`, the
  orchestrator brief template. Serialise with T005 (same template).
- [ ] **T007 (US7, fix 7) fleet-wide sweep freshness.**
  Files: `orc/src/bash/run/spl-dispatch-check.func.sh` and its test.
- [ ] **T008 (US8, fix 8) cron parity check across boxes.**
  Files: a new `orc/src/bash/run/check-cron-parity.func.sh`
  (`do_check_cron_parity`) and its `*.tst.sh`; the box classes come from the
  same setting as `LEASE_INTERMITTENT`.
- [ ] **T009 (R1-R5) research.** Read-only; the answers go into `spec.md`
  section 3.
