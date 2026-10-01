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
| the data disk is lost on a rebuild | separate disk, `prevent_destroy` via cnf; no snapshots (owner: git is the backup), so un-pushed work on the VM is at risk |
| cost drift past $170 | the machine type is cnf; the budget alert (round 2 Q4); the price is confirmed from the billing catalogue before the go |
| 4 vCPU is slow for builds and e2e | the owner chose RAM first; the machine type is one cnf value to raise later |
| image drift from the home box | the image is pinned by date in cnf; raising it is a reviewed cnf change |

## 3. Cost (europe-north1, list, per month, approximate; round 2 Q1 A)

| item | per month |
|---|---|
| e2-highmem-4 (4 vCPU / 32 GB), always on | ~$145 |
| 30 GB boot + 100 GB data, pd-balanced | ~$14 |
| outbound IPv4 | ~$4 |
| IAP tunnel, budget alert | $0 |
| **total** | **~$163** (limit $170) |

The owner asked for the price before the go: T013 confirms each line from the
Cloud Billing catalogue (its API is off in both projects; turning it on is a
GCP change, so it waits for the owner's go too).
