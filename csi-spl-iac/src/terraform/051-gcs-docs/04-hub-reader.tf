# The hub's runtime SA (030) READS the docs: objects get/list on this bucket
# only. The writer is the env's project SA (roles/owner), so no grant here.
resource "google_storage_bucket_iam_member" "hub_docs_object_viewer" {
  bucket = google_storage_bucket.docs.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${var.hub_runtime_sa_account_id}@${var.gcp_project}.iam.gserviceaccount.com"
}
