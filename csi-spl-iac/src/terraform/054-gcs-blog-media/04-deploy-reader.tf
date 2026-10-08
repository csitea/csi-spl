# wf 30's WIF identity (the 016 Firebase Hosting deploy SA) READS the
# pictures to copy them into the build: objects get/list on this bucket only
# (s111-4). The SA-key path of wf 30 and the picture writer both run as the
# env's project SA (roles/owner), so no grant here for either.
resource "google_storage_bucket_iam_member" "deploy_media_object_viewer" {
  bucket = google_storage_bucket.media.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${var.deploy_sa_account_id}@${var.gcp_project}.iam.gserviceaccount.com"
}
