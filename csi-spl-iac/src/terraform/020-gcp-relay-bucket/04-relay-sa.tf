# The sender identity. git-rel signs URLs LOCALLY with this SA's private key
# (gcloud storage sign-url --private-key-file), so it needs no
# iam.serviceAccounts.signBlob and no project-level role at all.
resource "google_service_account" "relay" {
  project      = var.gcp_project
  account_id   = var.relay_sa_account_id
  display_name = "${var.org}-${var.app}-${var.env} git-rel relay sender"
  description  = "git-rel relay sender: objects in ${var.relay_bucket_name} only"
}

# roles/storage.objectUser: objects get/list/create/delete/update on THIS
# bucket. Smaller than objectAdmin (no object IAM/ACL admin) and grants no
# bucket-level permission, so the SA cannot delete the bucket or change its
# policy: git-rel-destroy's final `buckets delete` is left to terraform.
resource "google_storage_bucket_iam_member" "relay_object_user" {
  bucket = google_storage_bucket.relay.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.relay.email}"
}

# The SA KEY is deliberately NOT a terraform resource: a
# google_service_account_key writes the private key into the state bucket in
# clear. It is minted once, out of band, see csi-spl-doc section 6.3.
