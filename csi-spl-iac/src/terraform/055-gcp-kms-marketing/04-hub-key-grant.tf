# The hub's runtime SA (030) seals and opens the channel tokens:
# cryptoKeyEncrypterDecrypter on THIS key only, never on the ring or the
# project. No other member is granted; the env's project SA administers the
# key as roles/owner.
resource "google_kms_crypto_key_iam_member" "hub_key_user" {
  crypto_key_id = google_kms_crypto_key.channel_tokens.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${var.hub_runtime_sa_account_id}@${var.gcp_project}.iam.gserviceaccount.com"
}

# do_spl_kms_check (csi-spl-iac) proves the grant above end to end: it
# encrypts and decrypts AS the runtime SA. The only key on a box is the env's
# project SA's, and roles/owner does not include iam.serviceAccounts.
# getAccessToken (measured on dev 2026-10-05: IAM_PERMISSION_DENIED), so the
# project SA gets serviceAccountTokenCreator on the runtime SA ONLY. It adds
# no power the project SA lacks: as owner it could grant itself the same.
resource "google_service_account_iam_member" "kms_check_token_creator" {
  service_account_id = "projects/${var.gcp_project}/serviceAccounts/${var.hub_runtime_sa_account_id}@${var.gcp_project}.iam.gserviceaccount.com"
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${var.kms_check_sa_account_id}@${var.gcp_project}.iam.gserviceaccount.com"
}
