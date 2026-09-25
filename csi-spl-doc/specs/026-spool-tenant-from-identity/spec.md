# Spec 026: the tenant comes from the identity, not the Host

**Feature**: `specs/026-spool-tenant-from-identity` · **Created**: 2026-09-19 · **Lane**: CLE-3415
**Amends**: 003 FR-015 / OQ-07 (tenant from the Host), 004 (box addressing), 010 SEC-001 (`session.t`).
**Supersedes**: 024 (per-tenant hosts, automated) — paused by the same decision.

## 1. Why

Owner, 2026-09-19 (verbatim):

> "would it be possible to not have to change the DNS per tenant ... but the
> users could be able to login to one tenant only"

> "can we use tenant per identity, but also in the future add the capability
> to switch identities the same way in slack one can switch workspaces in the
> left most vertical strip"

Until now the hub resolved the tenant from the request Host
(`<tenant>.<fqdn>`, 003 FR-015). With no load balancer and no wildcard
(CLE-3382), every tenant needed its own Cloud Run domain mapping, CNAME and
certificate (024). A self-serve tenant stayed dark for ~15-20 minutes, and
each one was a terraform apply.

After this spec there is ONE hub host per environment — `env.dns.api_fqdn`
(`api.spool-hub.ai`, `dev.api.spool-hub.ai`) — and the tenant is a property
of WHO is calling.

## 2. Resolution order (FR-001)

| caller | tenant = | proven by |
|---|---|---|
| human (WUI, browser) | the session's **active tenant** (§3) | the signed session cookie + a membership row, re-checked on every request |
| box / CLI on `/v1/ws` | the tenant the box names (`X-Spool-Tenant` header, §4) | the hello signature against THAT tenant's pin of the box id |
| box on REST with an upload token | the tenant the token was minted in | the token (minted on an authenticated socket) |
| pin / revoke (`POST /v1/pins`, `DELETE /v1/pins/{box}`) | the tenant named by `X-Spool-Tenant` | the tenant ROOT key signature |
| operator / admin CLI (`spool hub-tenant`, `hub-invite`, `do_spl_*`) | explicit argument | the operator DB role / project SA (unchanged) |

The Host header **stops deciding the tenant**. It remains a *consistency
check* during the transition (§5).

- **FR-002** A query string, a JSON body field, a header or a Host never
  *grants* a tenant. A caller-named tenant (the box's header, a legacy Host)
  is only accepted when the caller's credential proves it: a pin, a root
  signature, a token, or a membership. Humans cannot name a tenant per
  request at all (only at sign-in, §3; phase 2 adds an explicit switch, §6).
- **FR-003** Errors (003 error envelope):
  - `403 tenant_mismatch` — a legacy tenant Host names a different tenant
    than the identity resolves to; or the box header and the tenant Host
    disagree; or an upload token is presented on another tenant's Host.
  - `409 tenant_required` — a human session with more than one membership and
    no bound active tenant (the picker is phase 2, §6). The detail tells the
    client to sign in again with `?tenant=`; `GET /api/v1/auth/session`
    lists the choices.
  - `400 tenant_required` — a box request on the api host with no
    `X-Spool-Tenant` and no tenant Host.
  - `401 view_door` / `unauthorized` — unchanged (no session, not a member,
    bad signature).
- **FR-004** `SPOOL_HUB_VIEW_DOOR=off` (lde only) keeps the legacy Host
  resolution for anonymous reads, because there is no identity to resolve
  from.

## 3. Human sessions: the active tenant (FR-005)

- The session cookie's `t` claim is now the **active tenant**. It is bound
  at sign-in: the `?tenant=` of `/start` or native login; otherwise, when the
  human has **exactly one** membership at sign-in, that one.
- `t` is a *selection*, never an authorisation (010 SEC-001 stands): on every
  request the hub re-checks `(human, t)` membership, so a removed member is
  out at once.
- Per request, in order: `t` when still a member → the only membership when
  there is exactly one → the legacy tenant Host when the human is a member of
  it (§5) → `409 tenant_required` when there are several → `401 view_door`
  when there are none.
- `GET /api/v1/auth/session` adds `active_tenant` (string or null) and
  `tenants` (`[{ "tenant_id", "role" }]`, the caller's memberships). The WUI
  reads its tenant from here instead of from its own host.
- Data model: `tenant_memberships (tenant_id, human_id)` already allows many
  tenants per human (rdb 0006). No migration is needed for phase 1. Listing a
  human's memberships (`Humans.Memberships`) is an operator-scope read keyed
  by the session's `HUM-*`; it spans tenants by design, like sign-in.

## 4. Boxes and the CLI (FR-006)

- Box config `SPOOL_HUB_URL` is the api host (`https://api.spool-hub.ai`).
  The box's tenant is `SPOOL_TENANT`; the client sends it as `X-Spool-Tenant`
  on the WS upgrade and on every REST call.
- Backward compatible: an old per-tenant URL (`https://t1.spool-hub.ai`)
  keeps working while that mapping exists; the hub then only requires the
  Host tenant to equal the named tenant. A box that sends no header on a
  tenant host keeps the old behaviour (the Host tenant, proven by the pin).
  With no `SPOOL_TENANT`, the client derives it from a per-tenant URL.
- A box pinned in tenant A that names tenant B fails the hello
  (`unpinned_box` / `bad_sig`): the pin is per `(tenant, box_id)`.

## 5. Transition: legacy tenant hosts (FR-007)

- A Host that matches `SPOOL_HUB_TENANT_HOST_PATTERN` and is not the api
  host is a *legacy tenant host*. The hub still answers on it, but only when
  the Host tenant EQUALS the identity's tenant; otherwise
  `403 tenant_mismatch`.
- The api host (and any Host that does not match the pattern) carries no
  tenant; identity alone decides.
- Retirement (§8): once the measured traffic on the tenant hosts is zero,
  the mappings are removed through terraform via make.

## 6. Phase 2: the workspace switcher (Implemented: hub 0.5.9, WUI drop box)

- `POST /api/v1/auth/tenant {"tenant": "<id>"}` re-issues the session cookie
  with `t=<id>` when the human is a member of `<id>` (else 403); logs
  `auth.tenant_switch`. Idempotent. The same CORS as the other auth routes.
  **Implemented** (hub 0.5.8, CLE-34983): `internal/auth/tenant.go`
  `switchTenant`; answers the GET session body for the new cookie; the cookie
  keeps its expiry; an unknown tenant is `403 not_member` like a foreign one.
  Check: `TestWorkspaceSwitch` (memory + `hub-pg.tst.sh`).
- "Last used": the hub records `last_active_at` per membership on the
  switch; a session without `t` and with several memberships then gets the
  most recent one instead of 409. **Implemented**: rdb 0044
  `tenant_memberships.last_active_at` (applied dev + prd 2026-09-25 via
  `do_spl_db_bootstrap`), `fallbackTenant` -> `lastActive`. A legacy Host
  that names one of the memberships still wins over "last used". CONTROL:
  the fallback disabled turns `TestWorkspaceSwitch` red.
- WUI: the left-most vertical strip lists `tenants` from the session (one
  icon per workspace); a click calls the switch endpoint and reloads the
  feeds. **Implemented** as the sidebar tenant drop box, not a separate
  strip (the owner's box, be3e3f0e, sits where that strip would):
  `tenantSwitchOptions` lists every membership when there are two or more
  (a blank first row when none is active), a pick calls
  `authClient.switchTenant` and then loads `/` of the new tenant; a refusal
  keeps the old tenant and shows `sidebar.tenant_switch_failed` (19
  locales). One membership = the fixed one-row box, choosing it does
  nothing. Checks: `tests/unit/tenant-switcher.test.mjs` (options, guard
  before the call, client body + headers, CONTROL 403), e2e
  `tenant-switcher.test.mjs` 12/12 (single-membership box unchanged at
  1280 and 390).

## 7. RLS and RBAC (FR-008)

- RLS (017, rdb 0014) is unchanged: every tenant statement runs under
  `inTenant(<resolved tenant>)`; the resolved tenant now comes from §2.
- RBAC (025, CLE-3414) evaluates `(human, active tenant)`. The hub helper
  `humanTenant(r)` returns both.

## 8. Rollout (FR-009)

1. Hub with identity resolution (tenant hosts still mapped, so nothing
   breaks), deployed dev then prd by the deploy lane (image tag + 030).
2. Box client + CLI send `X-Spool-Tenant`; box configs move to the api host.
3. WUI: `NUXT_PUBLIC_API_BASE` = the api host (no `{tenant}`); tenant from the
   session. lde keeps `{tenant}.localhost` + door off.
4. `do_spl_m3_e2e` runs on the api host (dev, prd): every step PASS.
5. Measure traffic on each tenant host (hub request log `host=`); at zero,
   remove the per-tenant mappings from cnf `env.dns.mapped_tenants` and apply
   032 + 025 through make (dev, then prd).
6. First real tenant `csitea` on dev and prd, created as a normal tenant (no
   DNS), with the owner invited as `owner` (= `biz_owner` under 025).
7. Checkout (CLE-3405): `tenant_url` becomes the WUI sign-in URL
   `<app_url>/login?tenant=<id>`; `tenant_url_pattern` and the host status
   copy are dropped. Landed by CLE-3405 in 8081310.

## 9. Tests and CONTROLS (FR-010)

- A member of A with a session can never read or write B: not with B's Host
  (403 tenant_mismatch), not with `?tenant=B` / `X-Spool-Tenant: B` (ignored
  for humans), on every door (view, WUI ws, channels, files, dispatch).
- A box pinned to A that names B is refused at hello; an upload token of A on
  B's Host is 403.
- Legacy Host mismatch → 403; Host equal → 200 (the transition works).
- A two-tenant human with no bound `t` → 409 tenant_required on the api host;
  with `t` → only `t`.
- Each control first proves the positive path on the same fixture, so a
  refusal is not an unrelated failure.

<!-- version: 0.3.0 · updated: 2026-09-25 · last-edit: 2026-09-25T19:05:00Z -->
