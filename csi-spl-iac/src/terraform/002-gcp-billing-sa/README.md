# 002-gcp-billing-sa

The dedicated billing service account of
[spec 123 section 15](../../../../csi-spl-doc/specs/123-cost-tracking/spec.md)
(SPL-5220, SPL-5265). Owner HUM-10, csitea #laskut f655b326: "the sa account
must be created as terraform step".

## 1. What it creates

Only these, in cnf `env.cost.gcp.export_project` (`csi-spl-all`):

- the service account `env.cost.gcp.billing_sa` (`spl-billing`);
- `roles/bigquery.jobUser` for it on that project, so
  `do_gcp_billing_invoices_fetch` can query the billing export;
- `roles/billing.viewer` and `roles/billing.user` for it on EACH billing
  account (SPL-5506). Owner HUM-10, #laskut f655b326, msg a508c121: "I grant
  csi-spl-all Billing Admin once; Terraform does the rest". Precondition,
  the owner's one manual grant: the `csi-spl-all` SA this step runs as holds
  Billing Account Administrator on that account; without it the plan fails
  with a permission error. The ids are never committed:
  `var.billing_account_ids` (comma separated, no default, an empty or
  malformed value is refused) comes from `GCP_BILLING_ACCOUNT_IDS`, which
  make passes as `TF_VAR_billing_account_ids` (section 4);
- its one key (`google_service_account_key`), written by a
  `local_sensitive_file` to `~/.gcp/.<org>/key-<org>-<app>-billing.json`
  of the user who applies, mode 0600 (SPL-5457). Owner HUM-10, #laskut
  f655b326, msg 8d767855: "You should change the Terraform code to actually
  provision the key on the file system while provisioning the account".
  The tf-runner mounts that user's `~/.gcp` at its own `$HOME/.gcp` and runs
  as that user's uid, so the file is the applying user's. Other users read
  it as that user (`sudo -u <that user>`), like the env keys beside it.

Both values are read from `all.env.yaml` (`env.cost.gcp`), the one place they
live. The step is rendered from prd only (the 059 pattern): it runs as the
`csi-spl-all` SA (`steps.002-gcp-billing-sa.tf_key_project`), its state is in
`csi-spl-all-tfstate` under `terraform/002-gcp-billing-sa`, and a dev plan is
refused by the `env` validation.

## 2. Where the key lives, and what it never creates

**The key is in this step's state.** This is the one exception to the repo
rule "no key in terraform state" (repo `CLAUDE.md`, owner msg 8d767855). The
private key is in `gs://csi-spl-all-tfstate/terraform/002-gcp-billing-sa`.
That bucket has uniform access and public access prevention; its readers
are csi-spl-all's owners (the csi-spl-all SA and the owner account) and its
editors (`gcloud storage buckets get-iam-policy gs://csi-spl-all-tfstate`,
read 2026-11-13). No output carries it and nothing logs it. The file on
disk is written only by an apply, on the box that applies; a plan on a box
without the file shows it as a create.

What it never creates, the owner's steps:

- **Billing Account Administrator for the `csi-spl-all` SA** on each
  billing account: the one grant that lets this step make the two roles
  above (owner msg a508c121).
- **`roles/billing.projectManager`** on a project it is to move.
- **BigQuery Data Viewer** on the billing export dataset.

`cd csi-spl-iac && ./run -a do_gcp_billing_sa_create` prints each of them as
an exact command. That action creates nothing: it reports whether the SA and
its jobUser exist and points here when they do not.

## 3. Why 002

Every step has its own state (`prefix = "terraform/<step>"`), so adding one
recreates nothing. 002 is free, early, and depends on nothing but the
`csi-spl-all` bootstrap (`ENV=all` gcp-000..004, which enables `iam` and
`cloudresourcemanager` there; step 001 runs in the env projects, not in
`csi-spl-all`).

## 4. Plan and apply

    cd csi-spl-iac && ./run -a do_gcp_billing_sa_tf

It lists the billing accounts as the `csi-spl-all` SA (its key, never the
owner; `GCP_BILLING_ACCOUNT_IDS` when set is used instead), refuses an empty
list, and runs `make do-tf-plan ENV=prd STEP=002-gcp-billing-sa` in
csi-spl-orc with the ids in that run's environment only, every id masked in
its output. By hand, the same:

    cd csi-spl-orc && GCP_BILLING_ACCOUNT_IDS=<id>,<id> ENV=prd STEP=002-gcp-billing-sa make do-tf-plan

From nothing: 4 + 2 per account to add (the SA, its jobUser, the key, the
key file, and viewer + user on each account). Over the SA and key applied
before SPL-5506: 2 per account to add, nothing changed or destroyed.
`TF_VERB=provision ./run -a do_gcp_billing_sa_tf` (`make do-provision`) only
on the owner's go.

Destroy and recreate (owner msg 8d767855), the spec 057 path:

    cd csi-spl-orc && ENV=prd STEP=002-gcp-billing-sa make do-tf-plan-destroy

then `make do-deprovision`, `make do-tf-plan` and `make do-provision`, each
on the owner's go, each with `GCP_BILLING_ACCOUNT_IDS` set (the variable has
no default). A recreated SA has a new unique id: every grant outside this
step (the owner's steps above) must be made again.
