# Feature Specification: spool hub cloud estate (iac)

**Feature ID**: `007-spool-hub-api-infra` (the "007-iac" area of the redo;
the dir keeps its name, `../README.md` §4)

**Created**: 2026-09-18 · **Redone**: 2026-09-18 (git-spec redo)

**Status**: **Partial** (re-measured 2026-09-18 ~19:45Z, §1.2) — dev runs
through ingress (cert ACTIVE); prd holds 001, the imported zone, 040, 050,
028 and is short of the image, DB bootstrap, 030 and 031; the NS handoff has
happened but the apex record has not been carried over; `017` is on trunk and
not applied; the secrets step, IAM users and domain verification are Planned.

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
| 10 | ingress: LB + Cloud Armor + wildcard cert + records | `031-gcp-hub-ingress` | **Partial** — 15 instances in state, cert `csi-spl-dev-hub-cert` ACTIVE for `dev.` + `*.dev.`, records in the prd zone; 403 from a non-allowlisted IP, the allowlisted 200 not yet measured | Planned |

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
| dev probe | `curl -so /dev/null -w '%{http_code}' https://t1.dev.spool-hub.ai/v1/health` from a non-allowlisted box -> `403` |
| Delegation | `dig +norec NS spool-hub.ai @v0n1.nic.ai` -> `ns-cloud-e1..e4.googledomains.com` (was Gandi at 19:00Z) |
| Zone records | `gcloud dns record-sets list --zone=spool-hub --project=csi-spl-prd` -> NS, SOA, `dev.` A, `*.dev.` A, `_acme-challenge.dev.` CNAME; **no apex, no www** |
| Apex | `dig +short @ns-cloud-e1.googledomains.com A spool-hub.ai` -> empty |

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

**Update 19:45Z — the handoff has happened (option A in effect)**, made
outside the repo: the TLD delegates to the zone (§1.2). Its other half, the
apex parking record and `www`, was not carried over, so the apex no longer
resolves. Owner confirmation asked; the fix is an apex + `www` record in the
zone (T020a). The options as first written:

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
(Cloud Armor IP allowlist in M1, removed in M2) reaches it.

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

## Requirements

| FR | Requirement | Status |
|---|---|---|
| FR-001 | Provisioning follows §1 per env, dev then prd; no step applies before its predecessors hold state | Partial — dev 1–10 (10 partial); prd 1–6 except 3 partial |
| FR-002 | `000` remote state per env, local-state copy kept | Implemented — state in both envs |
| FR-003 | `001` enables storage, iam, orgpolicy, run, sqladmin, secretmanager, artifactregistry, dns, compute, certificatemanager, iamcredentials, sts (`2a7888c` adds the last two for `017`) | Partial — dev enabled; prd cnf lists them, prd services do not |
| FR-004 | `025-gcp-dns-zone` **imports** the existing prd `spool-hub` zone, `prevent_destroy`, never creates; dev has no own zone | Partial — imported in prd state (apply lane, 19:14Z); the step's code is not yet on trunk |
| FR-005 | NS handoff per owner decision, with the apex parking record carried into the zone; apex stays parking until owner go | **Partial** — TLD delegates to `ns-cloud-e1..e4` (19:45Z), made outside the repo; **no apex / www record in the zone**, so the parking page no longer resolves; owner confirmation asked |
| FR-006 | `040` Cloud SQL (db-f1-micro both envs), DB `spool`, empty DSN secret slot; no user, password or secret version in tf | Implemented dev + prd (state) |
| FR-007 | `050` files bucket `csi-spl-<env>-files`, prefix `t/<tenant>/files/`; never the `020` relay bucket | Implemented dev + prd (state) |
| FR-008 | `028` Artifact Registry `csi-spl-<env>-hub` | Implemented dev + prd (state) |
| FR-009 | `do_build_push_hub_image` builds and pushes the hub image with bundled DDL | Implemented dev (`43b9296`) |
| FR-010 | `do_spl_db_bootstrap`: DB user, DSN secret version, `spool migrate`; secrets never in argv, log or state; dry-run by default | Implemented dev (`9f8f492`) |
| FR-011 | `030` Cloud Run hub, runtime SA, min = max = 1, ingress LB-only | Implemented dev; Planned prd |
| FR-012 | `031` global LB + serverless NEG + Cloud Armor IP allowlist (M1) + wildcard managed cert + records into the `025` zone | Partial — dev applied (cert ACTIVE, 403 non-allowlisted); prd Planned |
| FR-013 | `017` WIF deploy identity per env: creates `csi-spl-deploy-<env>`, scoped grants, exports the repo variables `008` reads; no SA key | Partial — on trunk `2a7888c` (the orphaned draft bound WIF to a `<project>@<project>` SA that `gcloud iam service-accounts list` shows does not exist; corrected); `terraform validate` PASS; not applied |
| FR-014 | `029` Secret Manager slots (no shop captcha / BIN; M2 payment slots empty or omitted) | Planned — no step dir on trunk |
| FR-015 | `003-gcp-iam-users`, `005-gcp-domain-verification` | Planned — `005` on unmerged `GRK-3341-007-tf-005-domain`; `003` not started |
| FR-016 | lde: `do_setup_app_inf` / `do_teardown_app_inf`, compose api + rdb + infra, no GCP | Implemented |
| FR-017 | DNS ops: `do_export_all_dns_settings`, `do_flush_dns`, `do_wait_for_cert`, `do_gandi_*` | Implemented (`f68affe`, `04f7dca`) |
| FR-018 | Nothing mutates GCP without the owner; every gcloud call carries `--account`; no key in git, tf state or log | Partial — rule in repo `CLAUDE.md`; gate tests on unmerged `GRK-3355-007-hygiene-tests` |
| FR-019 | The domain lives only in `env.dns.BASE_DOMAIN`; no hostname literal in Go | Implemented (`domain-single-source.tst.sh`) |

## Success Criteria

- **SC-001**: `do_setup_app_inf` exits 0 (lde).
- **SC-002**: `run-all-tests.sh` green in `csi-spl-iac` and `csi-spl-orc`.
- **SC-003**: `terraform state list` per step per env matches §1 with every
  row Implemented, on dev **and** prd.
- **SC-004**: `GET /v1/health` (003 FR-023) on `https://<tenant>.dev.spool-hub.ai` and
  `https://<tenant>.spool-hub.ai` returns 200 from an allowlisted IP and 403
  from any other.
- **SC-005**: the `20_hub-build-deploy.yml` deploy jobs run (not skip) for
  dev and prd.

## Out of Scope

Shop steps (a storefront `019`, `021`, `032`, `060`–`063`, `130` / `131`),
store SQL, M2 payment drivers, M3 WUI hosting (spec `005`), CI job design
(spec `008`), wire and tenancy semantics (`003` / `004` / `006`).

<!-- version: 1.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:50:00Z -->
