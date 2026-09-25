# Feature Specification: spool hub cloud estate (iac)

**Feature ID**: `007-spool-hub-api-infra` (the "007-iac" area of the redo;
the dir keeps its name, `../README.md` §4)

**Created**: 2026-09-18 · **Redone**: 2026-09-18 (git-spec redo) ·
**Synced**: 2026-09-25 (repo audit, trunk `e795f61f`; no GCP query)

**Status**: **Partial**. The as-built shape (owner 2026-09-19, "exactly
csi-rel: no load balancer") is: the hub on Cloud Run `030` with
`ingress: all`, reached through `032` Cloud Run **domain mappings** (after
`005` domain verification); the WUI on Firebase Hosting `019` with the env
FQDN as its custom domain and a `/api/v1/auth/**` rewrite to the hub; edge
limits in the hub, not in Cloud Armor. The `031` load balancer was
deprovisioned in both envs and removed (`70b84824`). Still missing:
`003-gcp-iam-users` (the 031-era `do_wait_for_cert` was retired in `dd3c9f59`, T090).

**Superseded 2026-09-19: LB removed.** Everything this spec wrote about the
`031-gcp-hub-ingress` load balancer (serverless NEG, Cloud Armor stages,
Certificate Manager wildcard, WUI internet-NEG route, `l7_narrowing`,
`wui_origin_host`, `dns_managed_zone`, `allowed_ip_ranges`) is **Superseded**.
Evidence: `git log --oneline --diff-filter=D -- 'csi-spl-iac/src/terraform/031-gcp-hub-ingress/*'`
-> `70b84824` ("deprovisioned in dev + prd", 14 resources each);
`git log --oneline --diff-filter=A -- 'csi-spl-iac/src/terraform/032-gcp-cloud-run-domain-mapping/*'`
-> `510c0b2d`; `git grep -n 'l7_narrowing\|wui_origin_host\|dns_managed_zone\|allowed_ip_ranges' -- csi-spl-cnf csi-spl-iac/src`
-> no output. The measurements of 2026-09-18/19 below are kept as the audit
trail, not as current state.

**Changelog**: `1.7.0` (2026-09-25) — sync to the as-built no-LB estate;
031 content Superseded; coverage rows for 005/032/045/120 and workflows
00/22/40/45; done items restamped. `1.6.0` (2026-09-19) — owner infra
provisioning requirements R1–R9 (FR-025–FR-033).

**Narrative**: `../../doc/md/SPEC-spool-hub-api-infra.md` (copy csi-rel +
pas-psf infra, not the shop). **Index, seams, canon**: `../README.md`.

**Depends on**: `002` (local mode, frozen), `003` (hub binary: `spool serve`,
`spool migrate`), `026` (tenant from identity: one API host, no tenant DNS).
**Consumed by**: `008` (hub pipeline), `029` (DB backup).

This spec owns **every terraform step, the DNS zone and its records, secrets,
the CI identity, the lde stack (`csi-spl-orc` `make do-setup-app-inf`) and
the pointer to the `csi-spl-rdb` schema**. Wire formats, pin semantics and
tenancy rules are cited, never restated (README §5).

M1 is not done until this estate is **applied on both `dev` and `prd`**
(`SPEC-spool-milestones.md`, M1 item 5).

---

## 1. Canonical provisioning order

Per environment; **dev fully, then prd** (the DNS zone step is the one
exception: prd apex before the dev subzone, FR-031). The exact commands and
gates per step are in `contracts/provisioning-order.md`. Every step runs only
through `cd csi-spl-orc && ENV=<env> STEP=<step> make do-tf-plan` /
`make do-provision` (tf-runner, the per-env project key) with the owner's go.

| # | Step | Terraform dir / action | Code on trunk |
|---|---|---|---|
| 1 | remote state | `000-gcp-remote-bucket` | Implemented |
| 2 | enable services | `001-enable-gcp-services` | Implemented (cnf list incl. `siteverification`, `firebase*`, `iamcredentials`, `sts`) |
| 3 | DNS zone: prd apex **imported**, dev subzone **created** + NS delegation | `025-gcp-dns-zone` | Implemented (`9ed50ac`; dev subzone `spool-hub-dev`) |
| 4 | domain verification (env SA a verified owner of the domain) | `005-gcp-domain-verification` + `do_spl_domain_verify` | Implemented (`510c0b2d`) |
| 5 | Cloud SQL Postgres | `040-cloud-sql-postgres` | Implemented |
| 6 | GCS files bucket | `050-gcs-files` | Implemented |
| 7 | DB backup bucket | `045-gcs-db-backups` | Implemented (`802e26fe`, spec `029`) |
| 8 | Artifact Registry | `028-gcp-artifact-registry` | Implemented |
| 9 | build + push the hub image | `do_build_push_hub_image` | Implemented; cnf `hub.image.tag: "0.5.7"` dev + prd |
| 10 | DB user + DSN secret version + `spool migrate` | `do_spl_db_bootstrap` | Implemented |
| 11 | Cloud Run hub (`ingress: all`, min = max = 1) | `030-cloud-run-hub` | Implemented |
| 12 | domain mappings for `env.dns.api_fqdn` (+ `mapped_tenants`, `[]` since 026) | `032-gcp-cloud-run-domain-mapping` + `do_spl_wait_for_mapping_cert` | Implemented (`510c0b2d`) |

Outside the chain: `020-gcp-relay-bucket` (git-rel, spec `001`);
`016-firebase-deploy-iam` / `019-firebase-static-site` (WUI Hosting, §3);
`017-github-wif-deploy` (WIF alternative, §5); `120-github-general-secrets`
(the CI key secret, FR-026); `003-gcp-iam-users` (Planned, no dir).
Step dirs: `ls csi-spl-iac/src/terraform` -> `000 001 005 016 017 019 020 025
028 030 032 040 045 050 120 modules`.

Live application of each step per env is **not re-measured in this sync**
(no GCP query); the last live evidence is §1.1–1.3 and the commit messages
cited per FR.

### 1.1 Evidence (first pass, historical)

Measured 2026-09-18 ~19:00–19:15Z, n=1 each, on trunk `bbc41e7`, read-only.

| Claim | Command -> result |
|---|---|
| Steps that have tf state | `gcloud storage ls -r gs://csi-spl-<env>-tfstate/` -> `000 001 020 025 028 030 031 040 050` in both envs |
| Resources in state, dev | resource count of each `default.tfstate` -> 000:1 001:1 020:3 **025:0** 028:1 030:6 **031:0** 040:3 050:1 |
| Resources in state, prd | same -> 000:1 001:1 020:3; **every other step 0** |
| dev hub | `gcloud run services describe csi-spl-hub-dev --region=europe-north1` -> image `…/spool-hub:0.1.0`, minScale=1 maxScale=1 |
| dev SQL | `gcloud sql instances list --project=csi-spl-dev` -> `csi-spl-dev-pg` db-f1-micro RUNNABLE |
| DNS zones | prd: `spool-hub` `spool-hub.ai.` public, NS `ns-cloud-e1..e4.googledomains.com`, created out of band; dev: none |

### 1.2 Re-measure (2026-09-18 ~19:45Z, trunk `cd38303`, historical)

prd state after the apply lane: 001:12 025:1 040:3 028:1 050:1; the TLD
delegates `spool-hub.ai` to `ns-cloud-e1..e4` (`dig +norec NS spool-hub.ai
@v0n1.nic.ai`). The dev `031` rows of this pass are Superseded (LB removed).

### 1.3 Restamp (2026-09-19 ~06:06Z, trunk `f5cba39`, historical)

`curl -s https://spool-hub.ai/version` -> `{"commit":"c972f24…"}` then
through the `031` LB. Superseded 2026-09-19: the hub is now reached on the
`032` mapping of `env.dns.api_fqdn`; the apex is the Firebase WUI (§3).

---

## 2. DNS

- **prd**: `025` **imports** the existing apex zone `spool-hub` (an `import`
  block plus `prevent_destroy`) and never creates one: a recreate gets new
  name servers and breaks the registrar delegation (`dns-zone-025.tst.sh`).
- **dev**: `025` **creates** the subzone `spool-hub-dev` (`dev.<domain>`) in
  `csi-spl-dev` and writes its NS delegation into the prd apex zone
  (`grep -n 'zone_name\|parent_zone' csi-spl-cnf/csi-spl/dev.env.yaml` ->
  `zone_name: spool-hub-dev`, `parent_zone_name: spool-hub`,
  `parent_zone_project: csi-spl-prd`; `025/03-dns-zone.tf:44`
  `resource "google_dns_managed_zone" "sub"`). Apply prd -> dev, destroy
  dev -> prd.
- **Records**: `025/04-cloud-run-mapping-records.tf` writes the records the
  `032` mappings ask for (`api.` A/AAAA and `dev.api.` CNAME in the apex zone,
  csi-rel's shape); `005` writes the siteVerification record; Firebase custom
  domain records come from `do_provision_firebase_dns_env`.
- **NS handoff (option A, owner 2026-09-18)**: the registrar NS point at the
  zone; the refusal in `do_gandi_set_nameservers` is lifted (`1b78621`).
- There is **no wildcard** and no per-tenant record: tenants come from
  identity (spec `026`); `env.dns.mapped_tenants: []` in both envs.

## 3. Hosts and routing (as built)

| Host | Served by | Step |
|---|---|---|
| `<fqdn>` (prd apex, dev `dev.<domain>`) | Firebase Hosting site `csi-spl-<env>-site`, custom domain (`019 bind_custom_domain: true` dev + prd) | `019` |
| `<fqdn>/api/v1/auth/**` | Firebase rewrite to the Cloud Run hub (`render-wui-firebase-json.sh:177`) | `019` + `030` |
| `env.dns.api_fqdn` (prd `api.<domain>`, dev `dev.api.<domain>`) | Cloud Run domain mapping to the hub; the WUI reads it cross-origin | `032` + `030` |

`030` runs with `ingress: all` (`all.env.yaml:76`) because both the mappings
and the Hosting rewrite need it. Edge limits (WS handshakes, auth routes) are
in the hub (`SPOOL_HUB_EDGE_*`, `csi-spl-api/.../internal/edge/edge.go`,
017 T010), not Cloud Armor. The data plane gates itself: a WS needs a hello
signed by a root-pinned box key; files need an upload token or a member
session; `/v1/view/*` needs a member session.

Superseded 2026-09-19 (LB removed, `70b84824`): the former §3 "the `031`
LB is the one front door, Firebase its WUI origin" and **OQ-H1**; the former
§4 Cloud Armor stages 0–3 and **OQ-H2**. Closing both formally is an owner
question (§7).

---

## User Story 1 — lde matches pas-psf / csi-rel (P1) — Implemented

`cd csi-spl-orc && make do-setup-app-inf` brings up the lde and the tf infra
stack (`ls csi-spl-orc/src/docker` -> `conf-validator docker-compose-api.yaml
docker-compose-infra.yaml docker-compose-rdb.yaml docker-compose-tf-infra.yaml
docker-compose-wui.yaml spool-hub-api tf-infra.env tf-runner tpl-gen`):
Postgres, fake-gcs, `spool migrate`, `spool serve`, a box `hub-sync`, plus
tf-runner / tpl-gen / conf-validator. No GCP, no credential for the lde half.

**Evidence**: `lde-stack.tst.sh` in the orc suite (suite green;
`ls csi-spl-orc/src/bash/tests/*.tst.sh | wc -l` -> 56).

## User Story 2 — numbered steps in provisioning order (P1) — Partial

`csi-spl-iac` carries the numbered steps of §1. Apply exists
(`csi-spl-iac/src/bash/run/{provision,tf-apply}.func.sh`) but runs **only**
through `make do-provision` in tf-runner, with the owner's go.

Missing: `003-gcp-iam-users`; a fresh per-step `state list` for both envs
(SC-003).

## User Story 3 — DNS zone early, certificates last (P1) — Implemented (code)

The zone is adopted / created at step 3; `005` verifies the domain; `032`
maps the API host and Cloud Run provisions its managed certificate;
`do_spl_wait_for_mapping_cert` waits for `CertificateProvisioned == True`. A
new tenant needs no DNS record (026).

## User Story 4 — hub on Cloud Run with SQL, files, secrets (P1) — Implemented (code)

`030` runs the hub (WS + REST, min = max = 1 per OQ-05, `all.env.yaml:60-61`;
Cloud SQL socket; DSN and auth secrets from Secret Manager; files-bucket IAM)
with `ingress: all`, reached on the `032` mapping.

## User Story 5 — CI deploys (P1) — Implemented (code)

CI authenticates with `credentials_json` from the GitHub secret
`GCP_KEY_CSI_SPL_<ENV>`, published by terraform step `120` (owner 2026-09-19;
`grep -c credentials_json .github/workflows/{20_hub-build-deploy,30_wui-build-deploy}.yml`
-> 1, 1). `017` WIF (pool, provider, deploy SA `csi-spl-deploy-<env>`) stays
the alternative (`grep -c GCP_WIF_PROVIDER .github/workflows/20_hub-build-deploy.yml`
-> 5).

## User Story 6 — Postgres holds spool tables only (P1) — Implemented (pointer)

The schema is `csi-spl-rdb/src/sql/postgres/spool-hub/NNNN_*.sql`
(`ls … | wc -l` -> 43, last `0043_messages_box_reply_level_backfill.sql`),
applied by `spool migrate` (spec `003`) locally and by `do_spl_db_bootstrap`
in cloud. Table semantics belong to `003` / `006` / `025` / `026`.

---

## 5. Infra provisioning requirements (owner, 2026-09-19)

Every apply of this estate follows R1–R9
([`infra-provisioning-requirements.md`](./infra-provisioning-requirements.md)).
FR-025–FR-033 bind them.

## Requirements

Status: **Implemented** (cite) / **Partial** (name the missing part) /
**Planned** / **Superseded**. "Code" means on trunk; live state is not
re-measured in this sync.

| FR | Requirement | Status |
|---|---|---|
| FR-001 | Provisioning follows §1 per env, dev then prd (DNS: prd then dev) | Partial — code for every row but `003`; per-env state not re-measured since 2026-09-19 (SC-003) |
| FR-002 | `000` remote state per env, local-state copy kept | Implemented — state in both envs (§1.1) |
| FR-003 | `001` enables every cnf `gcp_services` entry (storage, iam, orgpolicy, run, sqladmin, secretmanager, artifactregistry, dns, compute, certificatemanager, iamcredentials, sts, firebase, firebasehosting, siteverification) | Implemented (code) — `grep -n siteverification csi-spl-cnf/csi-spl/prd.env.yaml` -> line 63; compute + certificatemanager are LB leftovers (§7) |
| FR-004 | `025`: prd **imports** the apex zone (`prevent_destroy`, never created); dev **creates** the subzone `spool-hub-dev` delegated by an NS record in the apex zone | Implemented — `9ed50ac`; `dns-zone-025.tst.sh`; `025/03-dns-zone.tf:23,29,44,55` |
| FR-005 | Option A: registrar NS -> the `025` zone | Implemented — NS delegated (§1.2), refusal lifted (`1b78621`) |
| FR-006 | `040` Cloud SQL (`tier: db-f1-micro` both envs), DB `spool`, empty DSN secret slot; no user, password or version in tf | Implemented dev + prd |
| FR-007 | `050` files bucket `csi-spl-<env>-files`; never the `020` relay bucket | Implemented dev + prd |
| FR-008 | `028` Artifact Registry `csi-spl-<env>-hub` | Implemented dev + prd |
| FR-009 | `do_build_push_hub_image` builds and pushes the hub image with bundled DDL | Implemented — `csi-spl-orc/src/bash/run/build-push-hub-image.func.sh`; cnf tag `"0.5.7"` dev + prd |
| FR-010 | `do_spl_db_bootstrap`: DB user, DSN secret version, `spool migrate`; no secret in argv, log or state; dry run by default | Implemented — `spl-db-bootstrap.func.sh` |
| FR-011 | `030` Cloud Run hub, runtime SA, min = max = 1, `ingress: all` | Implemented (code) — `all.env.yaml:60-61,76`; `030/02-variables.tf:105` |
| FR-012 | ~~`031` global LB + Cloud Armor + wildcard cert~~ | **Superseded** 2026-09-19 (`70b84824`); replaced by FR-034 |
| FR-013 | `017` WIF deploy identity per env, no SA key | Implemented — applied dev + prd 2026-09-19 (T050); the WIF alternative to FR-026 |
| FR-014 | Secret Manager slots (auth session key + IdP client secrets; no captcha / BIN; payment slots empty) | Implemented — in `030/06-auth-secret-slots.tf` (`19914c18`), empty slots, no version resource; no separate `029-create-gcp-secrets` step |
| FR-015 | `005-gcp-domain-verification`; `003-gcp-iam-users` | Partial — `005` Implemented (`510c0b2d`, needed by `032`); `003-gcp-iam-users` missing (no dir: `ls csi-spl-iac/src/terraform`) |
| FR-016 | lde: `make do-setup-app-inf` / teardown, compose api + rdb + infra + tf-infra, no GCP | Implemented |
| FR-017 | DNS ops: `do_export_all_dns_settings`, `do_flush_dns`, `do_gandi_*`, `do_spl_wait_for_mapping_cert` | Implemented — all on trunk; the 031-era `do_wait_for_cert` is retired (`dd3c9f59`, T090) |
| FR-018 | Nothing mutates GCP without the owner; `--account` on every gcloud call; no key in git, tf state or log | Implemented — gates `no-keys-in-tf`, `no-key-material-in-tree`, `gcloud-account-pinned`, `rdb-no-store-entities` |
| FR-019 | The domain lives only in `env.dns.BASE_DOMAIN` | Implemented (`domain-single-source.tst.sh`) |
| FR-020 | `016` Hosting deploy SA per env; WIF binding behind `bind_github_wif` | Implemented (code); dev applied (T074); prd = T075 |
| FR-021 | `019` site per env; `env.dns.fqdn` is its custom domain (`bind_custom_domain: true` dev + prd, owner 2026-09-19) | Implemented (code) — `grep -n bind_custom_domain csi-spl-cnf/csi-spl/{dev,prd}.env.yaml` -> `true` ×2 |
| FR-022 | ~~`031` WUI route (internet NEG, `wui_origin_host`)~~ | **Superseded** (`70b84824`); the WUI is the `019` custom domain + `/api/v1/auth/**` rewrite (§3) |
| FR-023 | ~~Cloud Armor stage 1 behind `l7_narrowing`~~ | **Superseded** (`70b84824`); edge limits in-app (017 T010) |
| FR-024 | `30_wui-build-deploy.yml`: test, generate, render firebase.json, deploy, probe; auth by `GCP_KEY_CSI_SPL_<ENV>` (`credentials_json`), WIF alternative | Implemented (workflow) |
| FR-025 | R1: deploy and terraform use the per-project IaC SA key `$HOME/.gcp/.csi/key-csi-spl-<env>.json` | Implemented — `do_tf_init` sets `GOOGLE_APPLICATION_CREDENTIALS` to it (`tf-init-project-key.tst.sh`) |
| FR-026 | R2: keys reach GitHub only through `120-github-general-secrets` as `GCP_KEY_CSI_SPL_<ENV>` | Implemented (code) — `fe19c96c`; `github-secrets-120.tst.sh`; workflows `20`/`30` read it |
| FR-027 | R3: terraform only via `make do-tf-plan \| do-provision \| do-deprovision` -> tf-runner -> iac `./run` | Implemented — `csi-spl-orc/src/make/tf-tasks.func.mk:10,45,87`; `docker-compose-tf-infra.yaml` |
| FR-028 | R4: csi-rel gcp-*, tf-*, provision, make actions copied unchanged | Partial — copies on trunk; per-file verdicts in `csi-rel-tf-callers.md` / `csi-rel-gcp-actions.md` |
| FR-029 | R5: every tf variable rendered from `*.tfvars.tpl` by tpl-gen; fresh render = committed files | Implemented — `tf-steps-render-and-validate.tst.sh`, `tfvars-cover-declared-vars.tst.sh`, `tpl-gen-step-render-parity.tst.sh` |
| FR-030 | R6: local deploy first, then the pipeline; a skipped deploy job is not green | Partial — `00_deploy-lag-watch.yml` (`9a34a0ae`) flags an env that runs other than the cnf image; per-run proof that the `20` deploy jobs ran is not re-measured here (SC-005) |
| FR-031 | R7: steps in numeric order, dev then prd (DNS exception); rebuild destroys last -> 000 with backups first | Implemented — `csi-spl-orc/src/bash/run/tf-deprovision-steps.func.sh` (`do_tf_deprovision_steps`) |
| FR-032 | R8: objects only in the designated realm; every wrapper runs as the per-env SA (`ACCOUNT` > `GCP_ACCOUNT` > key > refuse); owner account only in gcp-000..004 while no key exists | Implemented — `csi-spl-iac/lib/bash/funcs/gcp-account-pin.func.sh` (`do_gcp_pin_account`); `gcloud-account-pinned.tst.sh` |
| FR-033 | R9: nothing ad hoc; every step a named `<verb>-<noun>.func.sh` action or a terraform step, with its test | Implemented — `adhoc-harvest.md` + `adhoc-harvest-gcp-actions.tst.sh` |
| FR-034 | `032` maps `env.dns.api_fqdn` (+ `mapped_tenants`) to the hub; `005` makes the env SA a verified owner first; `do_spl_lb_absent_check` proves no LB object remains | Implemented (code) — `510c0b2d`, `70b84824` ("do_spl_lb_absent_check lists 0 of 13 LB kinds in dev and prd") |
| FR-035 | `045-gcs-db-backups`: off-instance DB backup bucket, 30-day lifecycle, the SQL service agent the only writer; daily `45_db-backup.yml` (spec `029`) | Implemented (code) — `802e26fe`, `4ba27507` |
| FR-036 | `22_deploy-verify.yml`: post-deploy HTTPS smoke of the site and `api` `/version` (spec `008` FR-P12) | Implemented (workflow) — `0d2155d0` |
| FR-037 | `40_tenant-host-reconcile.yml` (spec `024`: one `032` mapping + ghs CNAME per tenant) | **Superseded** by `026` — the workflow header reads "PAUSED … schedule is REMOVED and the workflow is disabled"; `mapped_tenants: []` both envs; deletion is §7 |

## Success Criteria

- **SC-001**: `make do-setup-app-inf` exits 0 (lde).
- **SC-002**: `run-all-tests.sh` green in `csi-spl-iac` (36 test files) and
  `csi-spl-orc` (56 test files).
- **SC-003**: `terraform state list` per step per env matches §1 on dev
  **and** prd.
- **SC-004**: `GET https://<api_fqdn>/version` returns 200 with the cnf
  commit, and `https://<fqdn>/` serves the WUI, on dev and prd
  (`22_deploy-verify.yml`).
- **SC-005**: the `20_hub-build-deploy.yml` deploy jobs run (not skip) for
  dev and prd.

## 7. Open owner questions (sync 2026-09-25)

1. **Delete `40_tenant-host-reconcile.yml`** and the tenant-host leftovers
   (rdb `0015` `tenant_hosts`, cnf `mapped_tenant_records` /
   `mapped_tenants`)? Paused since 2026-09-19, superseded by `026`.
2. **Disable `compute` + `certificatemanager` APIs** in both envs? They
   served only the removed `031` LB (cnf comment in `001`); disabling an API
   is owner-gated.
3. **Close OQ-H1 (WUI host) and OQ-H2 (prd Cloud Armor stage 1) as
   Superseded** by the no-LB decision of 2026-09-19?

## Out of Scope

Shop steps (a storefront `021`, `060`–`063`, `130` / `131`), store SQL, M2
payment drivers, the WUI app itself (spec `005`; its hosting is §3 here), hub
CI job design (spec `008`), wire and tenancy semantics (`003` / `006` /
`026`).

<!-- version: 1.7.1 · updated: 2026-09-25 · last-edit: 2026-09-25T19:33:34Z -->
