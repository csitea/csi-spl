# Spec 105: one wildcard certificate for every workspace host

**Feature**: `specs/105-wildcard-tenant-hosts` · **Created**: 2026-10-07 · **Lane**: c-504 · **Version**: v0.1 (design, no build yet)

**Origin**: owner HUM-10, t1 topic `c7b6e8db`. c-002 listed seven options for
"a new workspace usable in minutes" (msg `491b6def`). The owner answered
"Let's add them all, especially the thing with the certificates. There is no
point to have different certificates for each of the workspaces" (`8fcdce3a`)
and "Make sure, though, that the current certificate and the current
workspaces will work" (`c3bbe5bc`). c-002's plan: `e3331df0`, correction
`6396842c`. This spec is option 3 of that list.

Read first: spec 024 (per-tenant hosts, the record of the pre-026 design),
spec 007 FR-012 / FR-034 (the removed `031` load balancer and what replaced
it), SPL-959 (the per-tenant WUI hosts on Firebase).

**Scope of this document**: design, migration and tasks. Nothing here changes
terraform, cnf, an orc action or a workflow. Every build step is a task in
`tasks.md`, one lane each, and every GCP mutation in them needs the owner's go
(repo `CLAUDE.md`: "Nothing mutates GCP without the owner").

---

## 1. Today, measured

Every measurement below: tree `456331a8` (origin/master, 2026-10-07), n=1
per probe unless stated.

### 1.1 How a workspace host is served now

| host | served by | DNS (025) | certificate |
|---|---|---|---|
| `<fqdn>` (apex = t1) | Firebase Hosting site `019`, default custom domain | A `199.36.158.100` + TXT `hosting-site=<site>` | Firebase-minted |
| `<tenant>.<fqdn>` | `019` `google_firebase_hosting_custom_domain.additional`, one per `env.dns.mapped_tenants` entry (SPL-959 option B) | A `199.36.158.100` + TXT, per tenant | Firebase-minted, per host |
| `www.<fqdn>` | `019` `redirect` custom domain -> apex | A + TXT | Firebase-minted |
| `api.<fqdn>` / `dev.api.<fqdn>` | Cloud Run domain mapping `032` -> the hub `030` | A/AAAA Cloud Run anycast / CNAME `ghs.googlehosted.com.` | Google-managed (domain mapping) |

- prd `mapped_tenants` has 12 entries, dev has 2:
  `grep -n mapped_tenants: csi-spl-cnf/csi-spl/{prd,dev}.env.yaml`.
- A new tenant needs a cnf edit, a push, workflow `40` (019 + 025
  terraform), then Firebase's certificate. Spec 024 §1 measured ~9-11 min to
  issue plus ~5-8 min edge propagation per host (n=1 per host, CLE-3382).
  On 2026-10-07 aleko-gik lost 1 h 40 min because the cnf commit was never
  pushed (c-002, `491b6def`).
- **"The current certificate" is not one certificate.** `openssl s_client
  -servername <host>` on 2026-10-07: the apex and `luka.<fqdn>` are each
  served a Google Trust Services WR3 certificate whose SAN list holds ~100
  unrelated customers' domains (Firebase batches custom domains into shared
  certificates). The apex certificate also carries `dev.<fqdn>`; the `luka`
  one also carries `csitea.dev`, `spool`, `ora-cam`, `csi-rel`, `pas-psf` and
  `csitea`. Expiry: Dec 18 and Dec 25 2026. `api.<fqdn>` has its own
  single-SAN certificate. So "keep the current certificate working" means:
  keep each host's Firebase custom domain (and with it its SAN entry) alive
  until that host is proven on the new path.
- No wildcard exists today: `nosuch-xyz.<fqdn>` -> NXDOMAIN, and
  `_acme-challenge.<fqdn>` / `_acme-challenge.dev.<fqdn>` have no TXT and no
  CNAME (DNS over HTTPS, `dns.google/resolve`, 2026-10-07). So a Certificate
  Manager DNS authorization CNAME collides with nothing.

### 1.2 The hub is already wildcard-ready

The WUI calls the hub **cross-origin on the one api host**
(`curl https://<fqdn>/config.json` -> `apiBase` and `authBase` =
`https://api.<fqdn>`), for REST and for the live WebSocket (`/v1/wui/ws`,
`csi-spl-wui/src/utils/live-ws.mjs:101`) alike.

- The page tenant comes from the request's `Origin` by **pattern**, not by
  list: `internal/hub/origin_tenant.go` `OriginTenant.Of` cuts the `.<fqdn>`
  suffix and accepts any label `msg.ValidTenantID` accepts. It is a
  selection, never a grant: membership is still checked.
- Credentialed CORS uses the same pattern (`TenantHost`, called by
  `allowAuthOrigin` in `internal/hub/auth_cors.go`).
- The WUI CSP already writes the hub source as `https://*.<fqdn>`
  (`csi-spl-wui/nuxt.config.ts` lines 63-70: `{tenant}` becomes `*`).
- The session cookie is `Domain=<BASE_DOMAIN>` (prd cnf
  `SPOOL_HUB_AUTH_COOKIE_DOMAIN: "{base_domain}"`), so it already reaches
  every subdomain.
- Reserved labels (`dev`, `www`, `api`, `app`, `auth`, `mail`, ... in
  `internal/msg/msg.go` `reservedTenants`) can never be a tenant.

So the hub, the CSP and the cookies need **no change** for a wildcard host.
A wildcard changes only how the page's bytes and TLS reach the browser.

### 1.3 Why `031` was removed

`70b84824` (2026-09-19): owner "exactly csi-rel: no load balancer". It
destroyed 14 resources per env via `make do-deprovision` (forwarding rule,
proxy, ssl policy, url map, backend service, serverless NEG, Cloud Armor
policy, global address, Certificate Manager cert / map / entry / dns-auth,
the `_acme-challenge` CNAME, the `*.<fqdn>` A); `do_spl_lb_absent_check`
listed 0 of 13 LB kinds in dev and prd. The commit message and spec 007
give the csi-rel parity rule as the reason; **neither cites cost or a
defect**. The `031` design had the WUI on Firebase behind the LB through an
internet NEG (`08-wui-origin.tf`, 007 T072: "default (a) implemented on
dev"). The terraform is recoverable from `70b84824^`.

Consequence: this spec **reverses an owner decision** of 2026-09-19. The
owner's 2026-10-07 answer is the go for the design; each apply still needs
its own go.

`csi-spl-doc/doc/md/availability-plan-20261004.md` R16 already lists
"ingress via a preview domain mapping" with "~+18 if the LB is chosen".

---

## 2. Requirements

- **FR-001** One Certificate Manager certificate per env covers the env's
  apex and every workspace host: prd `[<fqdn>, *.<fqdn>]`, dev
  `[dev.<fqdn>, *.dev.<fqdn>]`, issued by DNS authorization (DNS-01), so it
  is active **before** any workspace exists.
- **FR-002** A workspace created after cutover is served on
  `https://<tenant>.<fqdn>` the moment its tenant row exists: no cnf edit, no
  terraform, no workflow, no per-host certificate.
- **FR-003** Every host that works today keeps working at every step of the
  migration: no host is ever without a valid certificate or a DNS answer.
- **FR-004** A host moves only after it is proven on the new path (§5.2), one
  at a time, dev before prd, t1 (the apex) last in each env.
- **FR-005** Every move has a rollback that takes one DNS TTL (300 s) plus
  one apply, until the host's old Firebase custom domain is removed.
- **FR-006** The hub, its api host (`032`), its cookies, CORS and the WUI
  CSP are unchanged by this spec.
- **FR-007** Everything is terraform via the make / tf-runner path plus
  named actions with tests (repo `CLAUDE.md`). No gcloud by hand.
- **FR-008** An unknown label (`<anything>.<fqdn>` with no tenant row) gets
  the WUI page and the hub's refusal, never another tenant's data. This is
  already true: `OriginTenant` selects, membership decides.

---

## 3. Design

### 3.1 Shape (per env, in the env's own project)

```
browser -> <fqdn> / *.<fqdn>   (DNS A -> the LB's global IPv4)
        -> global external Application LB (EXTERNAL_MANAGED)
             certificate map -> one certificate [<fqdn>, *.<fqdn>]
             url map: hosts <fqdn>, *.<fqdn> -> backend "wui"; others -> 404
             backend "wui" = global internet NEG <site_id>.web.app:443,
                             Host rewritten to <site_id>.web.app
        -> Firebase Hosting site 019, unchanged (headers, CSP, i18n,
           the /api/v1/auth/** rewrite to the hub)
   :80  -> a second forwarding rule on the same IP -> 301 to https
```

`api.<fqdn>` stays on the `032` domain mapping and is **not** behind the LB
(FR-006, §7 Q3).

### 3.2 Why the WUI backend is Firebase via an internet NEG

- It is what `031` ran on dev (007 T072), so it is the shortest proven path.
- Firebase keeps serving the headers it serves today (CSP, HSTS
  `includeSubDomains; preload`, the cache rules in `firebase.json`), the
  `cleanUrls` and `i18n` behaviour, and the `/api/v1/auth/**` rewrite to the
  hub. A GCS backend bucket would need every header and rewrite rebuilt as LB
  config.
- Deploy stays one `firebase deploy` (workflow 30): the LB serves whatever
  the site serves; there is no second artefact.

Rejected: a serverless NEG to the hub for `/api/v1/auth/**` on the LB. It
would change the client-IP chain the hub's per-IP limits key on
(`SPOOL_HUB_TRUSTED_PROXY_HOPS` is one number for the whole hub, "1" for the
api host; `all.env.yaml` lines 396-402 note the Firebase chain is
`[client, firebase]`) and the cookie set the callback sees (Firebase forwards
only `__session`, which is why the state cookie has that name). Keeping the
callback on Firebase keeps both as they are; §5.2 step 10 measures the chain
once more with the LB in front.

### 3.3 DNS, and why the migration is safe by construction

- prd apex zone: one new record `*.<fqdn>` A -> the LB IP, plus the
  `_acme-challenge.<fqdn>` CNAME of the DNS authorization.
- dev subzone `dev.<fqdn>`: `*.dev.<fqdn>` A -> dev's LB IP, plus
  `_acme-challenge.dev.<fqdn>`.
- **An explicit record beats the wildcard** (RFC 4592: a wildcard answers
  only names that do not exist in the zone). Every current host has its own
  explicit A + TXT, so adding the wildcard changes **no** current host's
  answer. A host moves when, and only when, its explicit records are removed.
- The prd wildcard does not reach into `dev.<fqdn>` (a delegated subzone
  with its own NS records) and does not touch `api`, `dev.api` or `www`
  (explicit records).
- The DNS wildcard also answers multi-label names (`a.b.<fqdn>`). The TLS
  wildcard does not cover them and `ValidTenantID` refuses a dot, so those
  get a certificate error. Acceptable: nothing links there.

### 3.4 Terraform

A new step `031-gcp-wildcard-ingress` (the number `031` has been free since
`70b84824`; the new name says what the step is now):

| file | holds |
|---|---|
| `04-certificate.tf` | `dns_authorization` (domain `<fqdn>`), `certificate` `[<fqdn>, *.<fqdn>]`, `certificate_map` + one PRIMARY entry (recoverable from `70b84824^`) |
| `05-load-balancer.tf` | global address, url map (the hosts above -> wui, default -> 404), target HTTPS proxy with the certificate map, HTTPS forwarding rule; HTTP redirect url map + proxy + forwarding rule |
| `08-wui-origin.tf` | internet NEG + endpoint `<site_id>.web.app:443`, backend service, Host rewrite (from `70b84824^`) |
| `07-outputs.tf` | the LB IP and the DNS-auth CNAME, read by `025` |

No Cloud Armor policy: the edge limits stay in the hub, and the backend is
static files anyone can already fetch from `<site_id>.web.app`. `025` gets a
`wildcard_ingress_ip` input (empty = no records) for the `*` A and the
`_acme-challenge` CNAME, and its tenant records get the split of §5.1. `019`
is not touched by the build; only the final cleanup shrinks its
`additional_fqdns`.

The `certificatemanager` and `compute` APIs stayed enabled after the removal
(`70b84824` message), so `001` needs no change. Order per env: `031` apply,
then `025` (the DNS-auth CNAME; the certificate cannot go ACTIVE without
it), then wait for ACTIVE.

### 3.5 What breaks, checked one by one

| concern | verdict | why |
|---|---|---|
| WebSockets | unaffected | the WUI's socket is `wss://api.<fqdn>/v1/wui/ws` on `032`, never on the page host (§1.2). An LB in front of a WebSocket caps it at the backend timeout (30 s by default), one reason the api host stays off the LB |
| CSP | unaffected | served by Firebase as today; `connect-src` already holds `https://*.<fqdn>` (§1.2), and `'self'` is the page host either way |
| auth cookies | unaffected | the session cookie is `Domain=<BASE_DOMAIN>` and is set by the api host; the state cookie `__session` rides the Firebase rewrite as today |
| OAuth callbacks | unaffected; proven per host | `<P>_REDIRECT_URI` = `<APP_URL>/api/v1/auth/<p>/callback` with APP_URL = the apex. The URL does not change, so no provider console edit. The apex moves last (§5.3) and is proven with a real sign-in |
| client IP for rate limits | measure | the LB adds a GFE hop before Firebase: `do_spl_probe_client_ip` on the first moved host per env. A mismatch affects only requests through the WUI host's rewrite (the OAuth callbacks), never the api host |
| Firebase redirects | measure | a `cleanUrls` 301 must not name `<site_id>.web.app` in `Location` after the Host rewrite (§5.2 step 4) |
| HSTS preload | unaffected | same header, same names |
| unknown label | acceptable | the page loads, the hub refuses (FR-008); the WUI wording is T007 |

### 3.6 Cost per env, from the pricing pages

Source: `https://cloud.google.com/vpc/network-pricing`, section "external
Application Load Balancer", and
`https://cloud.google.com/certificate-manager/pricing`, both read 2026-10-07
(n=1). The load-balancer table read is the page's default region (the page
says its examples "use US pricing"); T001 re-reads the europe-north1 SKU
before the go.

| item | list price (USD) | per env per month |
|---|---|---|
| forwarding rules (HTTPS + HTTP redirect = 2, inside the "first 5" tier) | $0.025 / hour for the first 5 | **$18.25** (730 h) |
| data processed by the LB | $0.008 / GiB inbound + $0.008 / GiB outbound | ~$0.16 per 10 GiB of page traffic |
| internet egress LB -> browser | "normal data transfer rates" (not fetched; n=0) | small: the bundle is cached `immutable` |
| Certificate Manager | 0-100 certificates per month: free | $0.00 (one certificate) |
| global IPv4 on a forwarding rule | "No Charge" | $0.00 |
| Cloud Armor | not used | $0.00 |

**Fixed cost: $18.25 per env per month, $36.50 for dev + prd**, plus cents
per 10 GiB served. This confirms c-002's unmeasured "$18-25" and the
availability plan's R16 "~+18". Firebase Hosting's own transfer is unchanged
(it now serves the LB instead of the browser).

---

## 4. Obsolete once every host has moved

| thing | becomes | when |
|---|---|---|
| `env.dns.mapped_tenants` (cnf), `019` `additional_fqdns`, `025` per-tenant A + TXT | empty lists, then removed | after the last host's soak (§5.4) |
| workflow `40_tenant-host-reconcile.yml`, `do_spl_tenant_host_provision` / `_deprovision` / `_reconcile` | deleted | in the commit that empties the lists |
| option 4, the pre-warmed host pool | dropped (c-002 `e3331df0` already says so) | now |
| options 1 + 7, push the mapping and close the status | still needed **until** the cutover ends, then moot for hosts | - |
| "your address is being prepared" (option 5, `CheckoutHostStatus`) | never shown for a new tenant: the host works at once | after T006 |
| `tenant_hosts` rows | `ready` at insert while the wildcard is on; the table may go in a later forward-only migration | T006 |
| `052` `workspaces` | **not** obsolete (per-workspace docs buckets, a different concern) | - |

**The tenant create path afterwards**: create the tenant row (checkout,
`CreateTenant`, `do_spl_tenant_create`) and the host serves. Nothing else.

---

## 5. Migration that keeps every host working

### 5.1 The cnf split that makes a per-host move possible

Today one list, `mapped_tenants`, drives both the `019` Firebase custom
domain and the `025` explicit records. The move needs them apart for a
while. T003 adds `env.dns.wildcard_tenants` (flow style, one line):

- a tenant in `mapped_tenants` **and** in `wildcard_tenants`: `019` keeps
  its Firebase custom domain (the rollback path; its old SAN stays alive),
  `025` writes **no** explicit records for it, so DNS answers via the
  wildcard;
- a tenant only in `mapped_tenants`: as today;
- a tenant only in `wildcard_tenants`: fully moved, its Firebase domain gone.

The apex gets a separate flag, `env.dns.wildcard_apex: false|true`, because
the apex is not a wildcard name: moving it changes the apex A from
`199.36.158.100` to the LB IP.

### 5.2 Proof per host (a named action, T004: `do_spl_wildcard_host_probe`)

**Before** the move, without touching DNS, through `curl --resolve
<host>:443:<LB IP>`:

1. TLS: the chain is valid, the served certificate is the env's Certificate
   Manager one, its SAN matches `*.<fqdn>` (or `<fqdn>` for the apex), and it
   does not expire within 30 days.
2. `GET /` -> 200, and `Content-Security-Policy`,
   `Strict-Transport-Security` and `X-Frame-Options` are byte-equal to what
   the Firebase path serves for the same host now.
3. `GET /config.json` is byte-equal to the Firebase path's.
4. No `Location` header on `/index.html` or a `cleanUrls` path names
   `web.app`.
5. `GET /api/v1/auth/google/start` -> 302 to the provider (the rewrite
   reaches the hub).

**After** the move (records removed; wait one TTL plus the negative cache):

6. The DNS-over-HTTPS answer for the host is the LB IP.
7. Steps 1-5 again, without `--resolve`.
8. Sign-in: the WUI e2e sign-in spec passes with `BASE_URL=https://<host>`.
9. Live updates: a message posted to that tenant through the hub reaches
   the open WUI page over `/v1/wui/ws` within 5 s (the e2e live spec).
10. Once per env, on the first moved host: `do_spl_probe_client_ip` through
    the WUI host's rewrite, the hop count recorded in this spec.

A failed step after the move triggers the rollback (§5.5) at once.

### 5.3 Order

1. **dev**: build `031` and the `025` wildcard records (owner go); the
   certificate goes ACTIVE. Then a canary: a fresh dev test tenant that was
   never mapped, which proves FR-002 (it works the moment the row exists, no
   apply). Then `e2e`, `csitea`, then the dev apex (`dev.<fqdn>`, its t1).
2. **prd**: build, certificate ACTIVE, a canary as in dev. Then `e2e`,
   `demo`, then the remaining tenants in ascending order of their
   last-30-day active sessions (measured with `do_spl_db_query` on the day,
   lowest first), then **t1, the apex, last**.
3. One host at a time: the next host starts only after the previous host's
   after-move proof is green.

### 5.4 When an old Firebase custom domain may be removed

All of: the host has served through the LB for **7 days**; the probe (§5.2
steps 6-9) ran green daily in that window (T005); no explicit `025` record
for the host remains. Then the tenant leaves `mapped_tenants` (T010), which
destroys its `019` custom domain. The owner is told per batch, not per host.

The Firebase certificates expire on Dec 18 and Dec 25 2026 (§1.1). A host
whose DNS no longer points at Firebase may not get its SAN renewed; a 7-day
window sits well inside that, so a rollback during the soak still lands on a
valid certificate. Rolling back after the Firebase domain is removed means
re-adding it and waiting for a fresh Firebase certificate (spec 024: ~15-20
min), which is why removal comes last.

### 5.5 Rollback

- One host during its soak: take it out of `wildcard_tenants`; `025`
  re-creates its A + TXT; answers return to Firebase after one TTL (300 s).
  Its Firebase custom domain never left.
- The apex: `wildcard_apex: false`; the apex A returns to `199.36.158.100`.
- The whole env: every tenant out of `wildcard_tenants`, the apex flag
  false. The LB, the certificate and the `*` record can then stay (they
  serve only unmapped labels) or go with `make do-deprovision` on `031`
  (owner go).

---

## 6. Checks and controls

- iac tests for `031` and the `025` split (T002, T003): the rendered tfvars
  for a tenant in both lists carry the `019` domain and no `025` record.
  **CONTROL**: a plan that destroys the `019` domain of a tenant still in
  its soak is refused; plant one and the gate reports it.
- `do_spl_wildcard_host_probe` test (T004): each of the ten steps fails on a
  planted bad input (a wrong certificate, a CSP one byte different, a
  `Location` naming `web.app`, a DNS answer that is still Firebase's).
- `wui-hosting-019-031.tst.sh` currently fails if `031` or its cnf block
  returns (`70b84824`). T002 changes that assertion to the new step's
  shape; it does not delete it.

## 7. Open questions for the owner

1. **Money**: a fixed **$18.25 per env per month ($36.50 for dev + prd)**
   for the two load balancers (§3.6). Both envs, so dev proves every step
   first? Recommendation: yes, both.
2. **Unknown address**: with a wildcard, `anything.<fqdn>` loads the WUI and
   the hub refuses it. Show "no workspace at this address" with a link to
   the apex (recommended), or redirect straight to the apex?
3. **The api host**: keep `api.<fqdn>` on the Cloud Run domain mapping (a
   preview product, availability plan R16), or also put it behind the new
   load balancer (no extra forwarding-rule cost, but it changes the client-IP
   hop count and needs a WebSocket timeout)? Recommendation: keep it off the
   LB here and decide R16 separately.

<!-- version: 0.1.0 · updated: 2026-10-07 -->
