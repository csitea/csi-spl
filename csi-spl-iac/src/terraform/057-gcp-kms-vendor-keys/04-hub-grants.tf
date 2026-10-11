# The hub's runtime SA (030) is the ONLY member granted, per env:
#   cryptoKeyEncrypterDecrypter on THIS key (wrap on set, unwrap on lease),
#   secretAccessor on THIS pepper secret (the fingerprint HMAC).
# Nothing on the ring or the project. do_spl_vendor_key_grant_check reads the
# live policies daily and fails on any other member (spec 127 section 5.1).
locals {
  hub_member = "serviceAccount:${var.hub_runtime_sa_account_id}@${var.gcp_project}.iam.gserviceaccount.com"
}

resource "google_kms_crypto_key_iam_member" "hub_dek_wrap" {
  crypto_key_id = google_kms_crypto_key.dek_wrap.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = local.hub_member
}

resource "google_secret_manager_secret_iam_member" "hub_pepper_accessor" {
  project   = var.gcp_project
  secret_id = google_secret_manager_secret.pepper.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.hub_member
}
