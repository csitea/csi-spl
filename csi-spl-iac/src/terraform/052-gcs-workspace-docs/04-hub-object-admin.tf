# The hub's runtime SA (030) READS AND WRITES each workspace's docs:
# objectAdmin on these buckets only (spec 075 T006). No other member is
# granted; the env's project SA administers the buckets as roles/owner.
resource "google_storage_bucket_iam_member" "hub_workspace_docs_object_admin" {
  for_each = google_storage_bucket.workspace_docs

  bucket = each.value.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${var.hub_runtime_sa_account_id}@${var.gcp_project}.iam.gserviceaccount.com"
}
