# Contract: provisioning order for one environment

**Spec**: `../spec.md` §1 · **Authority**: `../../README.md` §6

Run for `ENV=dev` end to end, verify, then for `ENV=prd`. Every apply is an
**explicit owner go**; the actions below are dry-run or plan-only by
default. Every gcloud call carries `--account=$GCP_ACCOUNT` and runs as the
per-env project SA. Terraform runs only as `cd csi-spl-orc && ENV=<env>
STEP=<step> make do-tf-plan`, then `make do-provision` on the owner's go
(tf-runner); the `./run -a do_tf_plan` forms below are what tf-runner execs.

**Superseded 2026-09-19: LB removed** (`70b84824`). The old row 10
(`031-gcp-hub-ingress`) is replaced by rows 3b and 10 below (`510c0b2d`).

A step is **done** only when its gate reads green. "The command exited 0"
is not a gate.

| # | Step | Run | Gate (read the result) |
|---|---|---|---|
| 1 | `000-gcp-remote-bucket` | `ENV=<env> STEP=000-gcp-remote-bucket ./run -a do_tf_plan`, owner applies | `gcloud storage ls gs://csi-spl-<env>-tfstate/` lists the bucket |
| 2 | `001-enable-gcp-services` | plan + owner apply with the current cnf `gcp_services` list | `gcloud services list --enabled --project=csi-spl-<env>` contains every cnf entry |
| 3 | `025-gcp-dns-zone` (prd apex first, then dev subzone) | prd: plan must show **1 to import, 0 to destroy** for the apex zone; dev: creates `spool-hub-dev` + its NS delegation in the apex zone; owner applies | `terraform state list` -> `google_dns_managed_zone.env` (prd) / `.sub` (dev); apex NS still `ns-cloud-e1..e4` |
| 3a | NS handoff — **option A only, owner go** | set Gandi NS to the zone's four name servers | `dig +norec NS <BASE_DOMAIN> @v0n1.nic.ai` -> `ns-cloud-e*` |
| 3b | `005-gcp-domain-verification` | plan + owner apply; then `ENV=<env> ./run -a do_spl_domain_verify` | the env SA is a verified owner of `<BASE_DOMAIN>` (needed before any `032` mapping) |
| 4 | `040-cloud-sql-postgres` | plan + owner apply | `gcloud sql instances list` -> `csi-spl-<env>-pg` RUNNABLE |
| 5 | `050-gcs-files` | plan + owner apply | bucket `csi-spl-<env>-files` exists; it is not the `020` relay bucket |
| 5b | `045-gcs-db-backups` | plan + owner apply | bucket exists with the 30-day lifecycle; `45_db-backup.yml` run green (spec `029`) |
| 6 | `028-gcp-artifact-registry` | plan + owner apply | `gcloud artifacts repositories list --location=europe-north1` -> `csi-spl-<env>-hub` |
| 7 | hub image | `ENV=<env> ./run -a do_build_push_hub_image` | the tag is listed in the repository |
| 8 | DB bootstrap | `ENV=<env> ./run -a do_spl_db_bootstrap` (dry run), then `DRY_RUN=0 GCP_ACCOUNT=…` | `gcloud secrets versions list csi-spl-hub-db-dsn` -> a version `enabled`; a re-run is a no-op migrate |
| 9 | `030-cloud-run-hub` | plan + owner apply | `ENV=<env> GCP_ACCOUNT=… ./run -a do_check_hub_deploy` -> rc 0 `current` (service runs the cnf image, Ready, latest revision ready; measured dev 19:36Z rc 0); ingress `all`; min = max = 1 |
| 9b | `120-github-general-secrets` (primary CI auth) | plan + owner apply; publishes `GCP_KEY_CSI_SPL_<ENV>` | `20_hub-build-deploy.yml` deploy job for `<env>` runs (not skipped) with `credentials_json` and rolls or no-ops |
| 9c | `017-github-wif-deploy` (WIF alternative) | plan + owner apply (needs 028 + 030 and the iamcredentials/sts APIs); repo variables `GCP_WIF_PROVIDER_<ENV>` / `GCP_DEPLOY_SA_EMAIL_<ENV>` only if WIF is used | as 9b |
| 10 | `032-gcp-cloud-run-domain-mapping` | plan + owner apply (needs 005 + 030 `ingress: all`); the mapping records are written by `025` | `ENV=<env> DOMAIN=<api_fqdn> ./run -a do_spl_wait_for_mapping_cert` -> `CertificateProvisioned == True`; `curl https://<api_fqdn>/version` -> 200; `do_spl_lb_absent_check` -> 0 LB objects |

## Invariants

- **Never recreate the DNS zone.** A plan that adds or replaces
  `google_dns_managed_zone` is rejected, not applied.
- **The apex is the WUI**: `019` binds `env.dns.fqdn` as its Firebase custom
  domain (`bind_custom_domain: true`); no hub record is written on the apex.
- **No secret material in terraform.** `040` makes an empty secret slot; the
  version is written by step 8 over stdin. The relay SA key is out of band
  (feature doc §6.3).
- **dev before prd** (except step 3: prd apex before the dev subzone). prd
  starts only after dev's step 10 gate is green.

<!-- version: 1.4.0 · updated: 2026-09-25 · last-edit: 2026-09-25T18:24:52Z -->
