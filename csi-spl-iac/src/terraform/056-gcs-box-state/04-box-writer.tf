# The boxes' upload identity: WRITE-ONLY. objectCreator creates an object and
# nothing else: no get, no list, no delete, so no overwrite either. A box that
# is compromised can add junk and cannot read or remove another box's state.
# A restore reads as the project SA (roles/owner), never as this one.
resource "google_service_account" "writer" {
  project      = var.gcp_project
  account_id   = var.writer_sa_account_id
  display_name = "${var.org}-${var.app}-${var.env} box state writer"
  description  = "Nightly box state backup: objects.create in ${var.state_bucket_name} only"
}

resource "google_storage_bucket_iam_member" "writer_object_creator" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.writer.email}"
}

# No SA key: the backup runs as the project SA and IMPERSONATES the writer
# (`gcloud storage cp --impersonate-service-account`), a token of about an
# hour. roles/owner does not include getAccessToken, so this one grant, on
# this SA only, is what lets it. A key is never a terraform resource here
# (it would sit in the state bucket in clear).
resource "google_service_account_iam_member" "project_sa_token_creator" {
  service_account_id = google_service_account.writer.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${var.project_sa_email}"
}
