# Spec 123 section 15.2 (SPL-5220, SPL-5265, SPL-5457): the dedicated billing
# SA, the one project role it needs to query the billing export, and its key:
#   - ITS KEY is made here (owner HUM-10, #laskut f655b326, msg 8d767855:
#     "change the Terraform code to actually provision the key on the file
#     system while provisioning the account"). It is the one exception to the
#     repo rule "no key in terraform state": the private key is in this
#     step's state, gs://csi-spl-all-tfstate/terraform/002-gcp-billing-sa,
#     readable by whoever can read that bucket (see README.md section 2). It
#     is written, never printed: no output, a local_sensitive_file, mode
#     0600, under the applying user's ~/.gcp/.<org>/ (the tf-runner mounts
#     that user's ~/.gcp at its own $HOME/.gcp and runs as its uid).
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

# The one key; do_gcp_billing_invoices_fetch reads it (BILL_KEY of
# do_gcp_billing_cnf: key-<org>-<app>-billing.json beside the env keys).
resource "google_service_account_key" "billing" {
  service_account_id = google_service_account.billing.name
}

resource "local_sensitive_file" "billing_key" {
  filename             = pathexpand("~/.gcp/.${var.org}/key-${var.org}-${var.app}-billing.json")
  content_base64       = google_service_account_key.billing.private_key
  file_permission      = "0600"
  directory_permission = "0700"
}
