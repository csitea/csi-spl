# The hub's runtime identity, and exactly what it may reach:
#   the 040 Cloud SQL instance (connector), the DSN secret(s), the 050 files
#   bucket (objects only). No project-wide storage or secret role.
resource "google_service_account" "hub" {
  project      = var.gcp_project
  account_id   = var.runtime_sa_account_id
  display_name = "${var.org}-${var.app}-${var.env} spool hub runtime"
  description  = "Cloud Run ${var.service_name}: Cloud SQL client, its DSN secret, objects in ${var.files_bucket_name}"
}

# The Cloud SQL connector needs cloudsql.instances.connect, which has no
# instance-level IAM: the project role is the narrowest there is.
resource "google_project_iam_member" "hub_cloudsql_client" {
  project = var.gcp_project
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.hub.email}"
}

# the GitHub App key's slot is bound in 07, injected or not
resource "google_secret_manager_secret_iam_member" "hub_secret_accessor" {
  for_each = setsubtract(toset(values(var.secret_environment_variables)), [var.github_app_key_secret_id])

  project   = var.gcp_project
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.hub.email}"

  # an injected auth secret's slot is created in this step (06)
  depends_on = [google_secret_manager_secret.auth]
}

# objects get/list/create/delete on the files bucket only (as the 020 relay SA)
resource "google_storage_bucket_iam_member" "hub_files_object_user" {
  bucket = var.files_bucket_name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.hub.email}"
}
