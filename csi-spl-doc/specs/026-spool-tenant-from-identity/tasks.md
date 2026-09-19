# Tasks 026: tenant from identity

| id | task | status |
|---|---|---|
| T001 | spec 026 + amendment notes in 003 FR-015 / OQ-07, 010 SEC-001, 024 header | done |
| T010 | store: `Humans.Memberships(ctx, humanID)` (memory + Postgres, operator scope) | |
| T011 | auth: active tenant (bind `t` at sign-in, `ActiveTenant`), session response `active_tenant` + `tenants` | |
| T012 | hub: resolution per §2 on every door (view, WUI ws, channels, files, dispatch, pins, ws, cicd); Host = equality check | |
| T013 | hub tests: CONTROLS §9 | |
| T020 | box client + CLI: `X-Spool-Tenant`, api-host URL, legacy URL accepted | |
| T030 | WUI: api base without `{tenant}`, tenant from the session | |
| T040 | deploy dev then prd (deploy lane), `do_spl_m3_e2e` on the api host dev + prd | |
| T050 | measure tenant-host traffic; retire mappings via cnf + make 032/025 (dev, prd) | |
| T060 | tenant `csitea` dev + prd, owner invited as owner | |
| P2-1 | phase 2: `POST /api/v1/auth/tenant` switch + `last_active_at` + WUI rail | not now |
