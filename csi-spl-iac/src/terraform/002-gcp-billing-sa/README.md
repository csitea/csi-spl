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

- **Every billing-account role**: `roles/billing.viewer` and
  `roles/billing.user` on each billing account, and
  `roles/billing.projectManager` on a project it is to move. No project SA
  holds a role on a billing account, so only the owner can grant one.
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

    cd csi-spl-orc && ENV=prd STEP=002-gcp-billing-sa make do-tf-plan

From nothing: 4 to add (the SA, its jobUser, the key, the key file). Over
the SA applied before SPL-5457: 2 to add (the key and the file).
`make do-provision` only on the owner's go.

Destroy and recreate (owner msg 8d767855), the spec 057 path:

    cd csi-spl-orc && ENV=prd STEP=002-gcp-billing-sa ./run -a do_tf_plan_destroy

then `make do-deprovision`, `make do-tf-plan` and `make do-provision`, each
on the owner's go. A recreated SA has a new unique id: every grant outside
this step (the owner's steps above) must be made again.
