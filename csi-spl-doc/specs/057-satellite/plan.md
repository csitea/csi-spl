# 057 — the satellite: plan

Spec: [spec.md](spec.md). Tasks: [tasks.md](tasks.md).

## 1. Order of work

1. Spec + owner answers (this commit series). Stop.
2. On the owner's go for implementation:
   1. cnf block `steps.060-gcp-vm-satellite` in `csi-spl-cnf/csi-spl/prd.env.yaml` + tfvars templates; `do_tpl_gen` renders, `git diff --exit-code` clean.
   2. Step `csi-spl-iac/src/terraform/060-gcp-vm-satellite`, copied from csi-rel `050-gcp-vm-rdb` and trimmed per spec 5.1 (no new module).
   3. Tests (iac `src/bash/tests/`): the step has no ingress rule other than tcp/22; no `tls_private_key`; no web tag; the image is a dated image name; `terraform validate` (slow tier).
   4. `make do-tf-plan ENV=prd STEP=060-gcp-vm-satellite` from the main checkout; the plan goes to the owner.
   5. Owner go -> `make do-provision` for that step.
   6. Actions `do_satellite_ssh_config`, `do_satellite_bootstrap`, `do_satellite_creds_push`, each with its test, then run them (owner go for each first run).
   7. Owner logs in to the AI CLIs on the satellite; first agent spawned there; the satellite appears on the spool under its BOX_TAG.

## 2. Risks

| risk | control |
|---|---|
| a web port opens by mistake | the step test fails on any ingress rule other than tcp/22, and the step has exactly one firewall rule |
| a key lands in tf state | no `tls_private_key`/`google_service_account_key` resource; a test greps the step for them |
| dev and prd share one box (owner's explicit choice) | the dev and prd SA keys stay separate files; every action keeps choosing its key by `ENV` |
| the data disk is lost on a rebuild | separate disk, `prevent_destroy` via cnf, daily snapshot |
| cost drift | the machine type and schedule are cnf; a budget alert is a follow-up if the owner wants one |
| image drift from the home box | the image is pinned by date in cnf; raising it is a reviewed cnf change |

## 3. Cost (europe-north1, list, per month, approximate)

| item | on-demand | 1-year commit |
|---|---|---|
| e2-standard-16 | ~$430 | ~$270 |
| 700 GB pd-balanced data + 50 GB boot | ~$83 | ~$83 |
| daily snapshots, 7 kept | ~$15-25 | ~$15-25 |
| ephemeral IPv4 | ~$4 | ~$4 |
| **total** | **~$530** | **~$370** |
