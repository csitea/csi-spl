# Feature Specification: spool hub cloud estate (iac)

**Feature ID**: `007-spool-hub-api-infra` (the "007-iac" area of the redo;
the dir keeps its name, `../README.md` §4)

**Created**: 2026-09-18 · **Redone**: 2026-09-18 (git-spec redo)

**Status**: **Partial** (restamped 2026-09-19, §1.3) — the hub serves on
both envs through `031` (`https://spool-hub.ai/version` and
`https://dev.spool-hub.ai/version` -> 200, commit `c972f24`); option A is in
effect (apex -> prd hub LB); `017` is on trunk and not applied; the WUI
Hosting estate (`016`, `019`, the `031` WUI route, §3) and the Cloud Armor
stage-1 narrowing (§4) are written and wait on an owner GCP re-auth to apply;
the secrets step, IAM users and domain verification are Planned.

**Changelog**: `1.6.0` (2026-09-19) — owner infra provisioning requirements R1–R8 (`infra-provisioning-requirements.md`, FR-025–FR-032).

**Narrative**: `../../doc/md/SPEC-spool-hub-api-infra.md` (copy csi-rel +
pas-psf infra, not the shop). **Index, seams, canon**: `../README.md`.

**Depends on**: `002` (local mode, frozen), `003` (hub binary: `spool serve`,
`spool migrate`), `004` / `006` (tenant host, pins). **Consumed by**: `008`
(its pipeline reads the WIF repo variables step `017` exports).

This spec owns **every terraform step, the DNS zone and its records, secrets,
WIF, the lde stack (`csi-spl-orc` `do_setup_app_inf`) and the pointer to the
`csi-spl-rdb` schema**. Wire formats, pin semantics and tenancy rules are
cited, never restated (README §5).

M1 is not done until this estate is **applied on both `dev` and `prd`**
(`SPEC-spool-milestones.md`, M1 item 5).

---

## 1. Canonical provisioning order

Per environment; **dev fully, then prd**. DNS before anything that needs a
name; ingress last. Binding (README §6). The exact commands and gates per
step are in `contracts/provisioning-order.md`.

| # | Step | Terraform dir / action | dev | prd |
|---|---|---|---|---|
| 1 | remote state | `000-gcp-remote-bucket` | Implemented | Implemented |
| 2 | enable services | `001-enable-gcp-services` | Implemented (re-apply for iamcredentials + sts, `2a7888c`) | Implemented 19:21Z (12 services in state); re-apply for iamcredentials + sts |
| 3 | **DNS managed zone** (import, never create) + NS handoff | `025-gcp-dns-zone` (new) | n/a — dev records live in the prd zone | **Partial** — zone imported into prd state 19:14Z (1 instance), NS unchanged; step code not yet on trunk; TLD now delegates to it, apex record missing (§2) |
| 4 | Cloud SQL Postgres | `040-cloud-sql-postgres` | Implemented | Implemented (3 in state) |
| 5 | GCS files bucket | `050-gcs-files` | Implemented | Implemented (1 in state) |
| 6 | Artifact Registry | `028-gcp-artifact-registry` | Implemented | Implemented (1 in state) |
| 7 | build + push the hub image | `do_build_push_hub_image` | Implemented (`spool-hub:0.1.0`) | Planned |
| 8 | DB user + DSN secret version + `spool migrate` | `do_spl_db_bootstrap` | Implemented (secret v1 enabled) | Planned |
| 9 | Cloud Run hub | `030-cloud-run-hub` | Implemented | Planned |
| 10 | ingress: LB + Cloud Armor + wildcard cert + records | `031-gcp-hub-ingress` | **Partial** — 15 instances in state, cert `csi-spl-dev-hub-cert` ACTIVE for `dev.` + `*.dev.`, records in the prd zone; allowlist `0.0.0.0/0` since `37e2e58` (documented M1 exception, FR-012): `/v1/health` 200 from any IP | Planned |

Outside the chain: `020-gcp-relay-bucket` (git-rel, spec `001`, Implemented
in both envs); `016` / `019` Firebase (M3 WUI, spec `005`);
`017-github-wif-deploy` (after `028` and `030`, before the first CI deploy; spec `008` consumes it);
`003-gcp-iam-users`, `005-gcp-domain-verification`, `029-create-gcp-secrets`.

### 1.1 Evidence (first pass)

Measured 2026-09-18 ~19:00–19:15Z, n=1 each, on trunk `bbc41e7`. Every
gcloud call ran read-only with `--account=$GCP_ACCOUNT`.

| Claim | Command -> result |
|---|---|
| Steps that have tf state | `gcloud storage ls -r gs://csi-spl-<env>-tfstate/` -> `000 001 020 025 028 030 031 040 050` in both envs |
| Resources in state, dev | resource count of each `default.tfstate` -> 000:1 001:1 020:3 **025:0** 028:1 030:6 **031:0** 040:3 050:1 |
| Resources in state, prd | same -> 000:1 001:1 020:3; **every other step 0** |
| prd APIs | `gcloud services list --enabled --project=csi-spl-prd` -> no run, sqladmin, compute, secretmanager, artifactregistry, certificatemanager |
| dev hub | `gcloud run services describe csi-spl-hub-dev --region=europe-north1` -> image `…/csi-spl-dev-hub/spool-hub:0.1.0`, minScale=1 maxScale=1, cloudsql `csi-spl-dev:europe-north1:csi-spl-dev-pg` |
| dev SQL | `gcloud sql instances list --project=csi-spl-dev` -> `csi-spl-dev-pg` db-f1-micro RUNNABLE |
| dev DSN | `gcloud secrets versions list csi-spl-hub-db-dsn --project=csi-spl-dev` -> `1 enabled` |
| dev LB, cert, WIF | `compute addresses list`, `certificate-manager certificates list`, `iam workload-identity-pools list --location=global` -> `Listed 0 items` each |
| DNS zones | `gcloud dns managed-zones list` -> prd: `spool-hub` `spool-hub.ai.` public, NS `ns-cloud-e1..e4.googledomains.com`, records NS+SOA only, created 2026-09-18T18:52Z out of band; dev: none |
| Delegation | `dig +norec NS spool-hub.ai @v0n1.nic.ai` -> `ns-166-a`, `ns-194-b`, `ns-143-c` `.gandi.net` |
| Module tests | `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` -> `6/6`; `bash csi-spl-orc/src/bash/tests/run-all-tests.sh` -> `6/6` |

### 1.2 Re-measure (2026-09-18 ~19:45Z, n=1 each, trunk `cd38303`)

| Claim | Command -> result |
|---|---|
| prd state | managed instances per `default.tfstate` -> 001:12 025:1 040:3 028:1 050:1 030:0 |
| prd APIs | `gcloud services list --enabled --project=csi-spl-prd` -> 7 of run, sqladmin, compute, secretmanager, artifactregistry, certificatemanager, dns present |
| dev ingress | 031 state 15 instances; `gcloud certificate-manager certificates list --project=csi-spl-dev` -> `csi-spl-dev-hub-cert` ACTIVE `dev.spool-hub.ai`, `*.dev.spool-hub.ai` |
| dev probe | `curl -so /dev/null -w '%{http_code}' https://t1.dev.spool-hub.ai/v1/health` from a box never allowlisted -> `403` at ~19:45Z; `200` at ~20:20Z after `37e2e58` (documented M1 exception, FR-012) |
| Delegation | `dig +norec NS spool-hub.ai @v0n1.nic.ai` -> `ns-cloud-e1..e4.googledomains.com` (was Gandi at 19:00Z) |
| Zone records | `gcloud dns record-sets list --zone=spool-hub --project=csi-spl-prd` -> NS, SOA, `dev.` A, `*.dev.` A, `_acme-challenge.dev.` CNAME; **no apex, no www** |
| Apex | `dig +short @ns-cloud-e1.googledomains.com A spool-hub.ai` -> empty |

### 1.3 Restamp (2026-09-19 ~06:06Z, n=1 each, trunk `f5cba39`; C7 of the M3 gap analysis)

No GCP identity was usable this session (`gcloud … --account=<owner>` ->
"Reauthentication failed"; ADC expired), so these rest on public probes, not
on terraform state.

| Claim | Command -> result |
|---|---|
| prd hub live (T020c, T036, T042 were stale "Planned") | `curl -s https://spool-hub.ai/version` -> `{"commit":"c972f24…","version":"0.1.0-dev"}`; `www.`, `api.` -> 200 |
| apex -> prd LB | `dig +short A spool-hub.ai @ns-cloud-e1.googledomains.com` -> `34.54.10.95` (= `www.`, `api.`) |
| dev hosts -> dev LB | same for `dev.`, `t1.dev.`, `dev.api.` -> `136.68.5.155` |
| T071 stale | `command grep -c api/v1/auth csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh` -> `2` (`1dbc29a`) |
| WUI not hosted (before §3) | `curl -s -o /dev/null -w '%{http_code}' https://csi-spl-{dev,prd}-site.web.app/` -> `404` `404`; `https://spool-hub.ai/login` -> `404` (05:44Z) |

---

## 2. The DNS gap and its decision

No terraform on trunk creates or adopts the product zone.
`031-gcp-hub-ingress/06-dns.tf` only writes records into
`var.dns_managed_zone`, and cnf sets it empty in both envs
(`grep -n 'dns_managed_zone:' csi-spl-cnf/csi-spl/{dev,prd}.env.yaml` ->
`""` twice), so today `031` would create no record at all.

**The fix — Partial, in flight.** A new step **`025-gcp-dns-zone`**
**imports** the existing `spool-hub` zone in `csi-spl-prd` (an `import`
block plus `prevent_destroy`) and **never creates one**: a recreate would get
new name servers and break any delegation made to the old ones. dev has no
zone of its own; its `*.dev.spool-hub.ai` records are written into the prd
zone by `031` across projects. That step and the matching `031` change sit
**uncommitted** in the `CLE-3335-m1-cloud-standup` worktree (`git -C
<CLE-3335 worktree> status --short` -> `?? csi-spl-iac/src/terraform/025-gcp-dns-zone/`,
` M …/031-gcp-hub-ingress/06-dns.tf`); both envs' `025` state objects exist
with 0 resources (init only). Until it lands on trunk it is not Implemented.

**Decided 2026-09-18: option A.** The owner set the registrar NS to the
zone (the TLD answers `ns-cloud-e1..e4`, §1.2) and chose to point the **apex
at the hub load balancer**, not at Gandi parking; `api.<domain>` (prd) and
`dev.api.<domain>` (dev) are served by the same LBs (T020c, T020d). Until
prd `030` + `031` are applied the apex resolves to nothing. The refusal in
`do_gandi_set_nameservers` is lifted (`1b78621`). The options as first
written, kept for the record:

**NS handoff — owner-gated question (README §6.1):**

- **A — hand off.** Gandi NS -> `ns-cloud-e1..e4`; Cloud DNS (terraform)
  is authoritative for every record, including a copy of today's apex
  parking record; the `ns-cloud-*` refusal in `do_gandi_set_nameservers`
  is lifted.
- **B — stay on Gandi.** The zone is imported but not delegated; the ACME
  CNAME and the `*.` / `*.dev.` A records are written with `do_gandi_*`.

Trunk currently encodes B (`git show 300a998 cb25346 04f7dca`;
`grep -n ns-cloud csi-spl-orc/src/bash/run/gandi-set-nameservers.func.sh`
-> the refusal at line 23). The redo brief asks for A. Until the owner
answers, both are written as tasks (T020a / T020b) and neither is executed.
Either way the **apex stays Gandi parking** until the owner attaches the hub
or WUI; since prd `env.dns.fqdn` is the apex, `031` in prd must not write an
apex A record before that go.

---

## 3. WUI hosting and routing (M3; 005 T009, a1 Gap 8, a2 B4 / G17)

**Decision (T072), recommended default implemented on dev: the `031` load
balancer is the one front door; Firebase Hosting is its WUI origin.**

On `<fqdn>` and `<tenant>.<fqdn>` a URL-map path matcher sends
`/v1/*`, `/api/*`, `/healthz`, `/version` to the hub backend (Cloud Armor
policy, serverless NEG -> `030`) and **every other path** to a second backend:
a global internet NEG (`INTERNET_FQDN_PORT`) at `<site_id>.web.app:443` with
the Host rewritten to that name, so Firebase serves the `019` site and its SPA
fallback. Extra hosts (`api.`, `dev.api.`) keep the plain hub default.

```
browser -> https://t1.dev.<domain>/...        (cert: 031 wildcard, LB 031)
   /v1/*  /api/*  /healthz  /version  ->  hub backend (Cloud Armor) -> Cloud Run 030
   /v1/ws, /v1/wui/ws (WebSocket)     ->  same hub backend (ALB passes WS natively)
   anything else                      ->  wui backend -> <site_id>.web.app (Host rewritten)
```

Why the LB path matcher and not Firebase Hosting rewrites to Cloud Run
(the other T072 option, "rewrites"):

1. **WebSocket.** `/v1/ws` (boxes) and `/v1/wui/ws` (browser live feed) must
   pass. Firebase Hosting rewrites to Cloud Run are documented as not
   supporting WebSocket upgrades (unmeasured here, n=0; the LB path needs no
   such claim — the ALB already carries `/v1/ws` today).
2. **Tenant Host.** The hub routes on `Host` = `<tenant>.<fqdn>` (006). A
   Hosting rewrite reaches Cloud Run with the service host; the LB path keeps
   the browser's Host untouched on hub paths.
3. **Wildcard.** `*.<fqdn>` cannot be a Firebase custom domain; tenant hosts
   must stay on the `031` wildcard certificate anyway.
4. **Ingress.** `030` is `internal-and-cloud-load-balancing` (FR-011); a
   Hosting rewrite would need it opened past the LB and its Cloud Armor.

Consequences: same origin (the rendered CSP keeps `connect-src 'self'` and
adds `https://*.<fqdn> wss://*.<fqdn>` for a page on the bare `<fqdn>`); `019`
binds **no** custom domain (`bind_custom_domain: false`); the render's `run`
rewrites stay (010 T016) but act only on the bare `web.app` host; `GET /` on
a product host is now the WUI, not the hub's plain-text hello.

**OQ-H1 — which host serves the WUI (owner; also closes T072).**
(a) **Recommended, implemented on dev:** the env's own names —
`<fqdn>` + `<tenant>.<fqdn>` — through the LB as above; in prd the apex
`<domain>` and `<tenant>.<domain>` serve the WUI at `/` and the hub at
`/v1/*`; `api.<domain>` stays hub-only. prd flag: cnf
`steps.031-gcp-hub-ingress.wui_origin_host` = `""` (off) until answered.
(b) A separate WUI host (`app.<domain>`) bound straight to Firebase
(`019 bind_custom_domain: true`), reading the hub cross-origin on
`<tenant>.<domain>`: needs hub CORS for that origin, the CSP widened and
cross-site cookies for sign-in (see 010 OQ-A4 for the cookie Domain question).

## 4. Cloud Armor: from the M1 open ingress to tenant-authenticated L7

The hub backend's policy is `031 03-cloud-armor.tf`. Rules evaluate by
priority, first match wins. The WUI backend (§3) carries none: it serves the
same public bytes as `<site_id>.web.app`.

| Stage | What | Rules | Where |
|---|---|---|---|
| 0 — M1 (FR-012) | IP allowlist `0.0.0.0/0`; the data plane gates itself (box hello signed by a pinned key, file ids are capabilities, view door) | 1000+ allow, default deny | prd today |
| **1 — L7 host + path** | deny(403) a `Host` that is not `<fqdn>`, `<tenant>.<fqdn>` or an extra host (LB-IP scans, foreign Hosts), and a path outside `^/(v1/\|api/v1/\|healthz$\|version$)`. Boxes are unaffected: they dial `https://<tenant>.<fqdn>/v1/ws` | 900 host, 910 path | **dev (cnf `l7_narrowing: true`)**; prd = OQ-H2 |
| 2 — rate + WAF | `throttle` per source IP on `/v1/ws` handshakes and `/api/v1/auth/*` (e.g. 120/min, exceed deny(429)); preconfigured WAF `sqli-v33-stable` / `xss-v33-stable` at sensitivity 1 on `/api/*` only (never on the WS paths) | 800–850 | M2, both envs |
| 3 — tenant-authenticated | the Host rule lists only **registered** tenants (rendered from the 006 tenant registry into the policy on every tenant create, like the DNS-free wildcard: a policy update, not a record); `/v1/view/*` without an `Authorization` header or session cookie is refused at the edge; Adaptive Protection on. Cryptographic auth stays in the hub (Ed25519 hello, view token, session): Cloud Armor only refuses what can never succeed | 700–790 | after 006 rental + 010 sessions |
| M2 IP allowlist (FR-012) | 403 for a non-allowlisted source, per SC-004; only once box egress CIDRs are known per tenant | 1000+ | owner |

**Dev proof of stage 1** (T076): a box-style WebSocket upgrade to
`https://<tenant>.dev.<domain>/v1/ws` still gets `101`, while the control
requests `https://dev.api.<domain>/wp-login.php` (path) and a request to the
LB IP with `Host: evil.example` (host) get `403` from the policy.

**OQ-H2 — prd stage 1 (owner).** (a) **Recommended:** apply it now — it
refuses only requests the hub cannot serve. (b) Keep prd on stage 0 until M2.
Ready-to-apply (T077): set `l7_narrowing: true` in
`csi-spl-cnf/csi-spl/prd.env.yaml` (`031-gcp-hub-ingress`), then
`ENV=prd ./run -a do_tpl_gen`, `ENV=prd STEP=031-gcp-hub-ingress ./run -a
do_tf_plan` (expect `1 to change`, the security policy, 2 rules added, 0
destroy), apply that plan, and re-run the §4 probes against `<tenant>.<domain>`.

---

## User Story 1 — lde matches pas-psf / csi-rel (P1) — Implemented

The operator runs `./run -a do_setup_app_inf` from `csi-spl-orc`: compose
brings up Postgres and fake-gcs, builds `spool` and the hub image (bundling
the `csi-spl-rdb` DDL), runs `spool migrate` twice, `spool serve`, and a box
`hub-sync` with an unpinned-box control. No GCP, no credential.

**Acceptance**: exit 0 with checks `pg gcs migrate serve hello` all PASS;
`$SPOOL_HUB_URL` unset keeps 002 local mode working.
**Evidence**: `ls csi-spl-orc/src/docker` -> `docker-compose-api.yaml
docker-compose-infra.yaml docker-compose-rdb.yaml spool-hub-api`;
`lde-stack.tst.sh` in the orc suite (6/6 green); the action header records a
measured n=3 run on 2026-09-18.

## User Story 2 — numbered steps in provisioning order (P1) — Partial

`csi-spl-iac` carries the numbered steps of §1; `./run -a do_tf_plan`
renders the cnf tfvars and plans. **Apply is the owner's go**; there is no
apply action.

**Acceptance**: every row of §1 has a step dir (or orc action), a cnf
tfvars pair per env, a render+validate test, and state in the order of §1
on both envs.

## User Story 3 — DNS zone early, records and TLS last (P1) — Partial

The zone is adopted at step 3; `031` issues a Certificate Manager wildcard
certificate (`<fqdn>` + `*.<fqdn>`, DNS-authorized) and writes the tenant
records at step 10; `do_wait_for_cert` waits for ACTIVE. A new tenant is a
new Host name and **no new DNS record** (wildcard from M1).

## User Story 4 — hub on Cloud Run with SQL, files, secrets (P1) — Partial (dev only)

`030` runs the hub (WS + REST, `min = max = 1` per OQ-05, Cloud SQL socket,
DSN from Secret Manager, files-bucket IAM) with ingress
`internal-and-cloud-load-balancing`, so only the `031` load balancer
(Cloud Armor allowlist; `0.0.0.0/0` under the documented M1 exception, FR-012) reaches it.

## User Story 5 — CI deploys without keys (P1) — Partial (code on trunk, not applied)

`017-github-wif-deploy` creates the WIF pool / provider and the deploy SA
`csi-spl-deploy-<env>` per env, granted only what the deploy job does
(artifactregistry.writer on the `028` repo, run.developer on the `030`
service, serviceAccountUser on the hub runtime SA), and and exports the repo variables `GCP_WIF_PROVIDER_<ENV>` and
`GCP_DEPLOY_SA_EMAIL_<ENV>` that spec `008`'s `20_hub-build-deploy.yml`
reads (`grep -c GCP_WIF_PROVIDER .github/workflows/20_hub-build-deploy.yml`
-> 5). While they are unset the deploy jobs skip.

## User Story 6 — Postgres holds spool tables only (P1) — Implemented (pointer)

The schema is `csi-spl-rdb/src/sql/postgres/spool-hub/NNNN_*.sql`
(`ls` -> `0001_hub_core.sql 0002_channels.sql 0003_payment.sql`), applied by
`spool migrate` (spec `003`) locally and by `do_spl_db_bootstrap` in cloud.
Table semantics belong to `003/data-model.md` and `006`; this spec owns only
where the files live and how they reach each env.

---

## 5. Infra provisioning requirements (owner, 2026-09-19)

Owner direction 2026-09-19. Every apply of this estate follows R1–R8.
The source lines, one-line CHECKs, and the 2026-09-19 ADC / native-tf-plan
context are in [`infra-provisioning-requirements.md`](./infra-provisioning-requirements.md).
FR-025–FR-032 bind them.

Context: in csi-spl (2026-09-19) agents had applied raw terraform on the
owner's user ADC and written a native tf-plan; the owner ordered a full
destroy + re-apply of dev and prd under R1-R7 because IAM was likely broken.

## Requirements

| FR | Requirement | Status |
|---|---|---|
| FR-001 | Provisioning follows §1 per env, dev then prd; no step applies before its predecessors hold state | Partial — dev 1–10 (10 partial); prd 1–6 except 3 partial |
| FR-002 | `000` remote state per env, local-state copy kept | Implemented — state in both envs |
| FR-003 | `001` enables storage, iam, orgpolicy, run, sqladmin, secretmanager, artifactregistry, dns, compute, certificatemanager, iamcredentials, sts (`2a7888c` adds the last two for `017`) | Partial — dev enabled; prd cnf lists them, prd services do not |
| FR-004 | `025-gcp-dns-zone` **imports** the existing prd `spool-hub` zone, `prevent_destroy`, never creates; dev has no own zone | Implemented — `9ed50ac`; prd state holds the zone (19:14Z), NS unchanged |
| FR-005 | Option A: registrar NS -> the `025` zone; the apex, `api.` and `dev.api.` point at the hub LBs | Partial — NS delegated (19:45Z), refusal lifted (`1b78621`); apex / `api.` / `dev.api.` records Planned (T020c, T020d) |
| FR-006 | `040` Cloud SQL (db-f1-micro both envs), DB `spool`, empty DSN secret slot; no user, password or secret version in tf | Implemented dev + prd (state) |
| FR-007 | `050` files bucket `csi-spl-<env>-files`, prefix `t/<tenant>/files/`; never the `020` relay bucket | Implemented dev + prd (state) |
| FR-008 | `028` Artifact Registry `csi-spl-<env>-hub` | Implemented dev + prd (state) |
| FR-009 | `do_build_push_hub_image` builds and pushes the hub image with bundled DDL | Implemented dev (`43b9296`) |
| FR-010 | `do_spl_db_bootstrap`: DB user, DSN secret version, `spool migrate`; secrets never in argv, log or state; dry-run by default | Implemented dev (`9f8f492`) |
| FR-011 | `030` Cloud Run hub, runtime SA, min = max = 1, ingress LB-only | Implemented dev; Planned prd |
| FR-012 | `031` global LB + serverless NEG + Cloud Armor allowlist + wildcard managed cert + records into the `025` zone. **M1:** the allowlist is `0.0.0.0/0`, a documented exception (`../../doc/md/SPEC-spool-milestones.md` M1 Ingress); the **data plane stays gated**: a WS needs a hello signed by a root-pinned box key, `GET /v1/files/{id}` is a capability by sha256, `/v1/view/*` needs a view token **in prd**. **Exception: dev runs `SPOOL_HUB_VIEW_DOOR=off`** (`csi-spl-cnf/csi-spl/dev.env.yaml`; the hub refuses `off` outside lde/dev), so dev thread reads are open to anyone who knows a dev tenant host. 403-for-a-non-allowlisted-IP is an **M2** expectation | Partial — dev and prd applied; `curl …/version` 200 on `spool-hub.ai`, `www.`, `api.`, `dev.`, `dev.api.` (~20:20Z, n=1); narrowing the allowlist is M2 |
| FR-013 | `017` WIF deploy identity per env: creates `csi-spl-deploy-<env>`, scoped grants, exports the repo variables `008` reads; no SA key | Partial — on trunk `2a7888c` (the orphaned draft bound WIF to a `<project>@<project>` SA that `gcloud iam service-accounts list` shows does not exist; corrected); `terraform validate` PASS; not applied |
| FR-014 | `029` Secret Manager slots (no shop captcha / BIN; M2 payment slots empty or omitted) | Planned — no step dir on trunk |
| FR-015 | `003-gcp-iam-users`, `005-gcp-domain-verification` | Planned, not needed for M1 — certificates use Certificate Manager DNS authorization, not Search Console verification; `005` draft on unmerged `GRK-3341-007-tf-005-domain`; `003` not started |
| FR-016 | lde: `do_setup_app_inf` / `do_teardown_app_inf`, compose api + rdb + infra, no GCP | Implemented |
| FR-017 | DNS ops: `do_export_all_dns_settings`, `do_flush_dns`, `do_wait_for_cert`, `do_gandi_*` | Implemented (`f68affe`, `04f7dca`) |
| FR-018 | Nothing mutates GCP without the owner; every gcloud call carries `--account`; no key in git, tf state or log | Implemented — rule in repo `CLAUDE.md`; gates `no-keys-in-tf`, `rdb-no-store-entities`, `no-baked-hostname` (`6646f41`) |
| FR-019 | The domain lives only in `env.dns.BASE_DOMAIN`; no hostname literal in Go | Implemented (`domain-single-source.tst.sh`) |
| FR-020 | `016` Hosting deploy SA per env (no key); its WIF binding to the `017` pool's trunk principal set behind `bind_github_wif` | Partial — code on trunk; not applied (owner re-auth) |
| FR-021 | `019` site per env; custom domains only with `bind_custom_domain` (default false, §3) | Partial — code on trunk; not applied |
| FR-022 | `031` WUI route (§3): internet NEG to `<site_id>.web.app`, path matcher keeps `/v1/*` `/api/*` `/healthz` `/version` on the hub; cnf `wui_origin_host` (dev on, prd off, OQ-H1) | Partial — code + cnf on trunk; dev not applied |
| FR-023 | Cloud Armor stage 1 (§4) behind `l7_narrowing` (dev on, prd off, OQ-H2) | Partial — code + cnf on trunk; dev not applied |
| FR-024 | `30_wui-build-deploy.yml`: test, nuxt generate per env, render firebase.json from cnf, `firebase deploy --only hosting`, probe the deployed commit on `web.app` and the product host. Auth (owner direction 2026-09-19): the per-project SA key secret `GCP_KEY_CSI_SPL_<ENV>` published by iac step `120-github-general-secrets` (DEPLOY lane) is primary; WIF (017 pool + the 016 Hosting SA) is the alternative when the key secret is absent. No Firebase-specific key or token: the project SA's `roles/owner` covers Hosting | Implemented (workflow); deploy jobs skip until the key secret or the WIF variables exist |
| FR-025 | R1: deploy and terraform use the per-project IaC SA key `$HOME/.gcp/.csi/key-csi-spl-<env>.json` (0600), minted by gcp-000..004 after one human `gcloud auth login` as `<owner-account>`; relay keys (`key-csi-spl-<env>-rel.json`) are bucket-scoped and never deploy keys. See `infra-provisioning-requirements.md` | Planned |
| FR-026 | R2: those keys reach GitHub Actions only through terraform step `120-github-general-secrets` as secret `GCP_KEY_CSI_SPL_<ENV>`; never a hand-run `gh secret set`; workflows authenticate with `credentials_json` from that secret; WIF is the alternative. See `infra-provisioning-requirements.md` | Partial — workflows read the secret (`00`/`20`/`30`); `120` exists; apply of `120` still pending |
| FR-027 | R3: terraform is never run natively on the host; only `cd csi-spl-orc && make do-setup-app-inf` then `ENV=<env> STEP=<step> make do-tf-plan \| do-provision \| do-deprovision` -> docker exec into tf-runner -> iac `./run`. See `infra-provisioning-requirements.md` | Partial — iac tf-* / provision wrappers on trunk; orc make + tf-runner compose still to wire |
| FR-028 | R4: csi-rel gcp-*, tf-*, provision and make actions are canonical and copied unchanged; a failure is a config/setup defect, never a script edit. See `infra-provisioning-requirements.md` | Partial — tf-* wrappers landed as copies |
| FR-029 | R5: every terraform variable of every step is set in the rendered `<env>/tf/<step>.vars.tfvars` (+ backend-config.tfvars) from `*.tfvars.tpl` via tpl-gen; no hand-edited tfvars; a fresh render equals the committed files. See `infra-provisioning-requirements.md` | Partial — tpl-gen + `tf-steps-render-and-validate.tst.sh` exist |
| FR-030 | R6: deploy order is local first (dev, then prd), then the GitHub pipeline; CI/CD must pass with the deploy job actually running (a skipped deploy is not green). See `infra-provisioning-requirements.md` | Planned |
| FR-031 | R7: all steps run in numeric order 000 -> last; each step is applied across both envs, dev first then prd; the ONE exception is the DNS zone step (applied prd/apex before dev/sub-zone, destroyed dev before prd); a full rebuild destroys last -> 000 then re-applies 000 -> last, with backups taken first. See `infra-provisioning-requirements.md` | Planned |
| FR-032 | R8: all GCP objects are created in the owner's designated realm only (`csi-spl-<env>` under the designated org and billing account, via `<owner-account>`); account and org id come from `env.gcp.gcp_account_owner_email` / `env.gcp.gcp_org_id`; every gcloud/terraform wrapper resolves `--account` from them (CI may override with `GCP_ACCOUNT`); bootstrap never creates a project in another org; a rebuild destroys objects inside the projects, never the projects. See `infra-provisioning-requirements.md` | Planned |

## Success Criteria

- **SC-001**: `do_setup_app_inf` exits 0 (lde).
- **SC-002**: `run-all-tests.sh` green in `csi-spl-iac` and `csi-spl-orc`.
- **SC-003**: `terraform state list` per step per env matches §1 with every
  row Implemented, on dev **and** prd.
- **SC-004**: `GET /v1/health` (003 FR-023) on `https://<tenant>.dev.spool-hub.ai` and
  `https://<tenant>.spool-hub.ai` returns 200. **M1:** from any IP (documented `0.0.0.0/0` exception, FR-012).
  **From M2:** 200 from an allowlisted IP and 403 from any other.
- **SC-005**: the `20_hub-build-deploy.yml` deploy jobs run (not skip) for
  dev and prd.

## Out of Scope

Shop steps (a storefront `019`, `021`, `032`, `060`–`063`, `130` / `131`),
store SQL, M2 payment drivers, the WUI app itself (spec `005`; its hosting
estate is §3 here), hub CI job design (spec `008`), wire and tenancy
semantics (`003` / `004` / `006`).

<!-- version: 1.6.0 · updated: 2026-09-19 · last-edit: 2026-09-19T08:40:00Z -->
