# Contract: provisioning order for one environment

**Spec**: `../spec.md` §1 · **Authority**: `../../README.md` §6

Run for `ENV=dev` end to end, verify, then for `ENV=prd`. Every apply is an
**explicit owner go**; the actions below are dry-run or plan-only by
default. Every gcloud call carries `--account=$GCP_ACCOUNT`.

A step is **done** only when its gate reads green. "The command exited 0"
is not a gate.

| # | Step | Run | Gate (read the result) |
|---|---|---|---|
| 1 | `000-gcp-remote-bucket` | `ENV=<env> STEP=000-gcp-remote-bucket ./run -a do_tf_plan`, owner applies | `gcloud storage ls gs://csi-spl-<env>-tfstate/` lists the bucket |
| 2 | `001-enable-gcp-services` | plan + owner apply with the current cnf `gcp_services` list | `gcloud services list --enabled --project=csi-spl-<env>` contains every cnf entry |
| 3 | `025-gcp-dns-zone` (prd only) | plan must show **1 to import, 0 to add, 0 to destroy**; owner applies | `terraform state list` -> `google_dns_managed_zone.<name>`; zone NS still `ns-cloud-e1..e4` (unchanged) |
| 3a | NS handoff — **option A only, owner go** | set Gandi NS to the zone's four name servers | `dig +norec NS <BASE_DOMAIN> @v0n1.nic.ai` -> `ns-cloud-e*` |
| 4 | `040-cloud-sql-postgres` | plan + owner apply | `gcloud sql instances list` -> `csi-spl-<env>-pg` RUNNABLE |
| 5 | `050-gcs-files` | plan + owner apply | bucket `csi-spl-<env>-files` exists; it is not the `020` relay bucket |
| 6 | `028-gcp-artifact-registry` | plan + owner apply | `gcloud artifacts repositories list --location=europe-north1` -> `csi-spl-<env>-hub` |
| 7 | hub image | `ENV=<env> ./run -a do_build_push_hub_image` | the tag is listed in the repository |
| 8 | DB bootstrap | `ENV=<env> ./run -a do_spl_db_bootstrap` (dry run), then `DRY_RUN=0 GCP_ACCOUNT=…` | `gcloud secrets versions list csi-spl-hub-db-dsn` -> a version `enabled`; a re-run is a no-op migrate |
| 9 | `030-cloud-run-hub` | plan + owner apply | `ENV=<env> GCP_ACCOUNT=… ./run -a do_check_hub_deploy` -> rc 0 `current` (service runs the cnf image, Ready, latest revision ready; measured dev 19:36Z rc 0); ingress `internal-and-cloud-load-balancing`; min = max = 1 |
| 9b | `017-github-wif-deploy` | plan + owner apply (needs 028 + 030 and the iamcredentials/sts APIs); then set repo variables `GCP_WIF_PROVIDER_<ENV>` = `terraform output -raw wif_provider_name`, `GCP_DEPLOY_SA_EMAIL_<ENV>` = `terraform output -raw deploy_sa_email` | `20_hub-build-deploy.yml` deploy job for `<env>` runs (not skipped) and rolls or no-ops |
| 10 | `031-gcp-hub-ingress` | plan + owner apply; records go into the `025` zone (A) or via `do_gandi_*` (B) | `ENV=<env> ./run -a do_wait_for_cert` -> ACTIVE; `curl https://<tenant>.<fqdn>/v1/health` -> 200 from an allowlisted IP, 403 otherwise |

## Invariants

- **Never recreate the DNS zone.** A plan that adds or replaces
  `google_dns_managed_zone` is rejected, not applied.
- **The apex stays Gandi parking** until the owner attaches the hub or WUI;
  no step writes an apex A record before that go.
- **No secret material in terraform.** `040` makes an empty secret slot; the
  version is written by step 8 over stdin. The relay SA key is out of band
  (feature doc §6.3).
- **dev before prd.** prd starts only after dev's step 10 gate is green.

<!-- version: 1.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:50:00Z -->
