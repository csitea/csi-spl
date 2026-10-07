# The hub's runtime SA (030) READS the docs: objects get/list on this bucket
# only. The writer is the env's project SA (roles/owner), so no grant here.
resource "google_storage_bucket_iam_member" "hub_docs_object_viewer" {
  bucket = google_storage_bucket.docs.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${var.hub_runtime_sa_account_id}@${var.gcp_project}.iam.gserviceaccount.com"
}

# spec 075 repo-edit: the hub also WRITES a saved edit's overlay
# (.edits/<path>/<edit_id>.md) and its worker's sweep deletes published ones.
# objectUser (get/create/update/delete), on the .edits/ prefix ONLY, so the
# hub still cannot touch the published tree. Missing until T13's first live
# save (403 storage.objects.create, 2026-10-07).
resource "google_storage_bucket_iam_member" "hub_docs_edits_object_user" {
  bucket = google_storage_bucket.docs.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${var.hub_runtime_sa_account_id}@${var.gcp_project}.iam.gserviceaccount.com"

  condition {
    title       = "repo-edit-overlays-only"
    description = "spec 075: the hub writes and sweeps .edits/ overlays only"
    expression  = "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.docs.name}/objects/.edits/\")"
  }
}
