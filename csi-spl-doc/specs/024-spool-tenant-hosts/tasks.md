# Tasks: per-tenant hosts, automated (024)

**Feature**: `specs/024-spool-tenant-hosts` · **Created**: 2026-09-19 · **Lane**: CLE-3404

`[x]` Implemented (sha + check) · `[~]` Partial (missing part named) · `[ ]` Planned

## Phase 1: queue (hub side, no GCP)

- [x] T001 rdb `0015_tenant_hosts.sql`: table + RLS + INSERT/DELETE triggers on `tenants`, existing tenants queued. c7bd400. Check: `hub-pg.tst.sh` green; `TestTenantHostQueue`, `TestTenantHostTriggers`.
- [x] T002 0015 applied dev + prd 16:10Z (`do_spl_db_bootstrap DRY_RUN=0`, env SA). Check: `do_spl_db_query` lists dev 8 rows, prd 2 (t1, e2e) pending.
- [x] T003 `store.TenantHost` / `SetTenantHost` (memory + Postgres). c7bd400.
- [x] T004 Checkout §1.3 / §1.4 carry `tenant_host` + `host_status`; checkout-v1 amended. da13814. Check: `TestCheckoutHostStatus` (CONTROL: ready flips). Ships with the next hub image roll (the deploy lane's tag bump).

## Phase 2: named actions

- [x] T010 `do_spl_tenant_host_provision`, `_deprovision`, `_reconcile` (gate, flock, cnf line edit, cnf push). 9fe1a2f, de06bd7 (tagged-row parser). Check: `tenant-host.tst.sh` (CONTROL: a re-apply with a new tenant keeps t1; a plan dropping t1 is refused before any apply).

## Phase 3: trigger (owner option 2)

- [x] T020 `40_tenant-host-reconcile.yml`: every 10 min + dispatch, dev → prd, a concurrency group per env, key secrets only. 7ed9d2e. Check: `tenant-host-workflow-40.tst.sh` (CONTROL); dispatch dry run 35454954283: dev open=8, prd open=2 as the env SAs (key, gcloud, SQL proxy, psql on the runner).
- [ ] T021 First real scheduled / dispatched apply green in both envs (tf infra stack on the runner, cnf push, WUI dispatch).

## Phase 4: WUI

- [x] T030 `CheckoutHostStatus` on /checkout/success + /checkout/claim, `pollHostReady`, keys `checkout.host.preparing` / `.ready`. 1ad609f; 18 locales translated by the i18n lane in 5bbb421. Check: WUI unit runner 28/28, `nuxi typecheck` clean.

## Phase 5: backfill + proof

- [x] T040 dev cnf: the 7 dark payment-test tenants (all `active`) → `mapped_tenants`. 4c5b914.
- [~] T041 dev apply from the main checkout (`do_spl_tenant_host_reconcile DRY_RUN=0`): 032 +7, 025 +7, 0 destroyed. Cert wait + probe + ready: in progress.
- [ ] T042 prd: t1 + e2e adopted (no-op plan, probe → ready).
- [ ] T043 End-to-end proof, dev: a NEW tenant bought via `do_spl_checkout_fake_buy` → pending → the workflow maps it → probe PASS → `host_status` ready.
- [ ] T044 End-to-end proof, prd: a new tenant → the workflow → ready.

## Spec

- [x] T050 This spec + tasks.
