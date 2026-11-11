# 002-gcp-billing-sa

The dedicated billing service account of
[spec 123 section 15](../../../../csi-spl-doc/specs/123-cost-tracking/spec.md)
(SPL-5220, SPL-5265). Owner HUM-10, csitea #laskut f655b326: "the sa account
must be created as terraform step".

## 1. What it creates

Only these two, in cnf `env.cost.gcp.export_project` (`csi-spl-all`):

- the service account `env.cost.gcp.billing_sa` (`spl-billing`);
- `roles/bigquery.jobUser` for it on that project, so
  `do_gcp_billing_invoices_fetch` can query the billing export.

Both values are read from `all.env.yaml` (`env.cost.gcp`), the one place they
live. The step is rendered from prd only (the 059 pattern): it runs as the
`csi-spl-all` SA (`steps.002-gcp-billing-sa.tf_key_project`), its state is in
`csi-spl-all-tfstate` under `terraform/002-gcp-billing-sa`, and a dev plan is
refused by the `env` validation.

## 2. What it never creates: the owner's steps

- **The key.** No key in terraform state (repo rule): the owner mints it out
  of band, as ONE key beside the env keys,
  `$HOME/.gcp/.<org>/key-<org>-<app>-billing.json`, never in git.
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

Expected: 2 to add, 0 to change, 0 to destroy. `make do-provision` only on the
owner's go.
