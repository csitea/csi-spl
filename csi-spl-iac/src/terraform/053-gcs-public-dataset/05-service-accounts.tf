# Three identities, no account does two jobs (spec 091 section 6, T007).
# Terraform creates NO key for any of them: keys are minted out of band (the
# doc section 6.3 pattern); a key resource would sit in the state bucket in
# clear.

locals {
  public_objects  = "projects/_/buckets/${google_storage_bucket.public.name}/objects"
  staging_objects = "projects/_/buckets/${google_storage_bucket.staging.name}/objects"
}

# --- export: reads the database through the proxy, writes staging ------------
resource "google_service_account" "export" {
  project      = var.gcp_project
  account_id   = var.export_sa_account_id
  display_name = "${var.org}-${var.app}-${var.env} public dataset export"
  description  = "Cloud SQL client; objects.create in ${var.staging_bucket_name}; nothing on ${var.public_bucket_name}"
}

# cloudsql.instances.connect has no instance-level IAM: the project role is
# the narrowest there is (as the 030 hub runtime SA).
resource "google_project_iam_member" "export_cloudsql_client" {
  project = var.gcp_project
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.export.email}"
}

resource "google_storage_bucket_iam_member" "export_staging_object_creator" {
  bucket = google_storage_bucket.staging.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.export.email}"
}

# --- publish: reads staging, creates in public, overwrites latest.json only --
resource "google_service_account" "publish" {
  project      = var.gcp_project
  account_id   = var.publish_sa_account_id
  display_name = "${var.org}-${var.app}-${var.env} public dataset publish"
  description  = "Reads ${var.staging_bucket_name}; objects.create in ${var.public_bucket_name}, overwrite of latest.json only; no database access"
}

resource "google_storage_bucket_iam_member" "publish_staging_object_viewer" {
  bucket = google_storage_bucket.staging.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.publish.email}"
}

# objectCreator: create only. An existing name cannot be overwritten (that
# needs objects.delete), so a published file never changes.
resource "google_storage_bucket_iam_member" "publish_public_object_creator" {
  bucket = google_storage_bucket.public.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.publish.email}"
}

# latest.json is the one overwritten object: objectUser on that name alone.
resource "google_storage_bucket_iam_member" "publish_public_latest_json" {
  bucket = google_storage_bucket.public.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.publish.email}"

  condition {
    title       = "latest-json-only"
    description = "Overwrite of latest.json only"
    expression  = "resource.name == \"${local.public_objects}/latest.json\""
  }
}

# --- verifier: reads staging, creates under verdicts/ only --------------------
resource "google_service_account" "verifier" {
  project      = var.gcp_project
  account_id   = var.verifier_sa_account_id
  display_name = "${var.org}-${var.app}-${var.env} public dataset verifier"
  description  = "Reads ${var.staging_bucket_name}; objects.create under verdicts/ only; nothing on ${var.public_bucket_name}"
}

resource "google_storage_bucket_iam_member" "verifier_staging_object_viewer" {
  bucket = google_storage_bucket.staging.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.verifier.email}"
}

resource "google_storage_bucket_iam_member" "verifier_staging_verdicts_creator" {
  bucket = google_storage_bucket.staging.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.verifier.email}"

  condition {
    title       = "verdicts-prefix-only"
    description = "Create under verdicts/ only"
    expression  = "resource.name.startsWith(\"${local.staging_objects}/verdicts/\")"
  }
}
