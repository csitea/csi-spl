# Tasks 026: tenant from identity

| id | task | status |
|---|---|---|
| T001 | spec 026 + amendment notes in 003 FR-015 / OQ-07, 010 SEC-001, 024 header | done |
| T010 | store: `Humans.Memberships(ctx, humanID)` (memory + Postgres, operator scope) | done |
| T011 | auth: active tenant (bind `t` at sign-in, `ActiveTenant`), session response `active_tenant` + `tenants` | done |
| T012 | hub: resolution per §2 on every door (view, WUI ws, channels, files, dispatch, pins, ws, cicd); Host = equality check | done |
| T013 | hub tests: CONTROLS §9 | done |
| T020 | box client + CLI: `X-Spool-Tenant`, api-host URL, legacy URL accepted | done |
| T030 | WUI: api base without `{tenant}`, tenant from the session | done (dcfbe0a, workflow 30 flip 0e061e3 after hub 0.1.12 was live) |
| T040 | deploy dev then prd (deploy lane), `do_spl_m3_e2e` on the api host dev + prd | done: hub 0.1.12 (253d5d0) dev+prd; m3 e2e api host dev/t1 14 PASS, prd/e2e 15 PASS (before and after T050); live WUI proof dev + prd |
| T050 | measure tenant-host traffic; retire mappings via cnf + make 032/025 (dev, prd) | done: 0e09b33 cnf; make do-provision dev 032 -8, dev 025 -8, prd 032 -2, prd 025 -2 (api records kept) |
| T060 | tenant `csitea` dev + prd, owner invited as owner | done: created (no DNS), invited biz_owner (025 live) on both |
| P2-1 | phase 2: `POST /api/v1/auth/tenant` switch + `last_active_at` + WUI rail | not now |

## Left for other lanes (not 026 scope)

- 024 leftovers: rdb 0015 `tenant_hosts` (triggers still queue rows), workflow 40 (disabled, dispatch only),
  `do_spl_tenant_host_{provision,deprovision,reconcile}` - obsolete now that `mapped_tenants` is `[]`.
- WUI `withSessionRetry` race (pre-existing): a concurrent read can stay 401 until its next poll; reported to CLE-55 / CLE-3412.
