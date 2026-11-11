# Spec 123 section 15.2 (SPL-5220, SPL-5265): the dedicated billing SA and the
# one project role it needs to query the billing export. Nothing else:
#   - NO key: it is minted out of band by the owner (no key in state, repo
#     rule); see README.md.
#   - NO billing-account role (billing.viewer, billing.user), no
#     billing.projectManager and no dataset dataViewer: no project SA holds a
#     role on a billing account, so those stay the owner's own steps, printed
#     by do_gcp_billing_sa_create.
resource "google_service_account" "billing" {
  account_id   = var.billing_sa
  display_name = var.billing_sa
  description  = "Reads the billing accounts and their projects, moves project billing on the owner's go (spec 123 section 15)."
}

resource "google_project_iam_member" "billing_job_user" {
  project = var.gcp_project
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.billing.email}"
}
