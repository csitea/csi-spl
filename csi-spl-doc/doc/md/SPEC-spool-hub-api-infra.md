# SPEC: spool-hub-api infra — copy csi-rel + pas-psf (not the shop)

Status: binding for Milestone 1 hub hosting and Milestone 2 public DNS  
Git-spec: `csi-spl-doc/specs/007-spool-hub-api-infra/`  
Code: `csi-spl-api` (Go hub), `csi-spl-iac` (terraform + `./run`), `csi-spl-orc` (lde / docker / deploy), `csi-spl-cnf`, `csi-spl-rdb` (Postgres **spool** schema only)

**Re-implement the same infra and DNS as `csi-rel` and `pas-psf`.** Local
dev, terraform, docker, Cloud Run, Cloud SQL, secrets, GitHub WIF — the
lot. **Do not copy** online-store business logic or store tables.

Reference only (do not import those modules):

| Tree | Take |
|---|---|
| `csi-rel-iac/src/terraform/` | Numbered TF steps, tpl-gen, `./run` tf-plan |
| `csi-rel-orc/` | Deploy actions, `wait-for-cert`, DNS export/flush, Cloud Run ship |
| `csi-rel-cnf/` | `dev`/`prd`/`all` yaml + tfvars; fail-fast; no keys in git |
| `pas-psf-iac/src/terraform/` | Same step numbers; Artifact Registry `028`; Cloud SQL `040` |
| `pas-psf-orc/src/docker/` | `docker-compose-api.yaml`, `-rdb.yaml`, `-infra.yaml`; `gen-docker-env` |
| `pas-psf-orc/src/bash/run/` | lde bring-up, docker install checks, `wait-for-cert`, DNS export |
| `pas-psf-doc/specs/001-gcp-infrastructure/` | Project bootstrap pattern (`dev`/`prd`/`all`) |
| `csi-rel-doc/specs/022-orc-app-deployment/` | Cloud Run / CI deploy |
| `csi-rel-doc/specs/033-orc-dns-certificates/` | DNS snapshot, flush, wait for managed TLS |

Mechanical copy may use the existing **morph** actions in those orc trees,
then **delete** shop-only paths.

---

## 1. Copy (terraform)

Keep the **same step numbers** so operators are not re-trained.

| Step | Job | Spool use |
|---|---|---|
| `000-gcp-remote-bucket` | tf state bucket | already in csi-spl-iac |
| `001-enable-gcp-services` | APIs | already; add run, sql, dns, secretmanager, artifactregistry |
| `003-gcp-iam-users` | operators | copy |
| `005-gcp-domain-verification` | Google domain verify | copy for spool-hub.ai |
| `007-dns` | Cloud DNS zone + records | **product zone** `spool-hub.ai`; **wildcard `*.spool-hub.ai` from M1** (not one host then migrate) |
| `017-github-wif-deploy` | CI deploy identity | copy |
| `028-gcp-artifact-registry` | API images | copy (pas-psf) |
| `029-create-gcp-secrets` | Secret Manager slots | copy; **no** store captcha/BIN; payment slots in **M2** |
| `030-gcp-cloud-run` | **spool-hub-api** service | HTTPS + WebSocket; min instances cnf (default 1) |
| `031-gcp-cloud-run-domain-mapping` | map host → Cloud Run | **wildcard TLS** `*.spool-hub.ai` (and `*.dev.spool-hub.ai`) from M1. If Cloud Run mapping is per-host, use LB + wildcard cert — still M1, not later. |
| `040-gcp-cloud-sql` | Postgres | spool schema only (`tenants`, `pins`, `messages`, …) |
| files bucket | object store | one bucket, prefix `t/<tenant>/files/`; copy bucket TF from `015` / `020`, not public-site ACLs |

csi-spl already has `020-gcp-relay-bucket` for **git-rel**. That stays a
**different** bucket. Do not mix relay objects and spool files.

**Do not copy:** `019-firebase-static-site` (shop), `032-recaptcha`,
`021-bin-dataset`, `060-stock-janitor`, `061-vertex-*`, `062`/`063` agent
shop alarms, `130`/`131` WordPress VM, store report buckets as shop dumps.

---

## 2. Copy (local dev / docker)

From `pas-psf-orc` (and the same compose shapes in `csi-rel-orc`):

| Artifact | Spool |
|---|---|
| `docker-compose-rdb.yaml` | Postgres for spool migrations |
| `docker-compose-api.yaml` | `spool-hub-api` / `cmd/spool hub` |
| `docker-compose-infra.yaml` | shared network / deps |
| `gen-docker-env.func.sh` | env files from cnf, no secrets in compose |
| docker check-install actions | copy |

**Do not copy:** `docker-compose-wui.yaml`, WordPress compose, shop mail
pipeline, **stripe-mock** (that arrives with M2 payment copy if still
wanted). Adminer optional (pas-psf has it; allowed as lde-only).
M1 image need **not** include `gh`. That binary is the **later** CI-logs
feature (`SPEC-spool-cicd-logs.md`).

lde: `./run -a do_*` to start rdb + api, run tests, no GCP required for
**local mail (002)**. Hub lde = compose API + Postgres talking to boxes on
localhost / published ports. `$SPOOL_HUB_URL` unset remains valid (M1 local
proof).

---

## 3. Copy (orc deploy / DNS ops)

| Action family | Source |
|---|---|
| `do_wait_for_cert` | csi-rel-orc / pas-psf-orc `033` |
| `do_export_all_dns_settings` / `do_flush_dns` | same |
| Cloud Run deploy (CI WIF + owner laptop escape) | `022` |
| `gcp-sm-secrets-to-env-file` | pas-psf-orc (placeholders in logs) |

DNS: the product domain is registered at **Gandi** and must stay on **Gandi
nameservers** (`*.gandi.net` / LiveDNS). Public records (apex, `dev`, wildcard
`*`) are published with the Gandi LiveDNS API (dob-luk-iac `do_gandi_*`
shape: token from `$GANDI_PAT` or `~/.gandi/.<org>/token`, domain from cnf
`env.dns.BASE_DOMAIN`, dry-run unless `CONFIRM=yes`). **Do not** re-delegate
registrar NS to GCP `ns-cloud-*`. Terraform `007-dns` if present is not the
public authority. No hostname literals in Go. Product shape stays
`https://<tenant>.<BASE_DOMAIN>`. **Wildcard DNS+TLS from M1**. Several
manual tenants must resolve without a new terraform host each time.

---

## 4. Explicitly not copied

- Catalogue, cart, orders, customers, invoices, stock, shipping, B2B
  pricelists, WordPress, Nuxt shop pages
- SQL under `csi-rel-rdb` / `pas-psf-rdb` **except** the migration *runner*
  and the idea of numbered `.sql` files — contents are spool tables only
  (`003/data-model.md`, `006`)
- Payment **drivers** wait for M2 (`contracts/payment.md`); M1 secrets
  have empty payment slots or omit them

---

## 5. Layout in this repo

```
csi-spl-api/src/go/spool-hub-api/   # Go hub + CLI
csi-spl-iac/src/terraform/<NNN>-*   # copied steps, spool names
csi-spl-orc/src/docker/             # lde compose
csi-spl-orc/src/bash/run/           # lde + deploy + DNS wait
csi-spl-cnf/csi-spl/{dev,prd,all}/  # yaml + tfvars
csi-spl-rdb/src/sql/                # spool schema only
```

Apply still needs an **owner go** (csi-spl CLAUDE.md). `tf-plan` never
apply-by-default.

<!-- version: 0.1.1 · updated: 2026-09-18 · last-edit: 2026-09-18T17:50:00Z -->
