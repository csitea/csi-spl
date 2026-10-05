# spec 090 T002: the key that seals each marketing channel's OAuth token
# (KMS envelope encryption, FR-002). The hub keeps only the ciphertext in
# Postgres (marketing_channel_tokens, under FORCE RLS), so a database dump
# without this key reveals no credential.
#
#   one key ring, one key   symmetric ENCRYPT_DECRYPT, software protection
#   rotation                every rotation_period (90 days); old versions
#                           stay enabled, so older ciphertext still decrypts
#   prevent_destroy         a destroyed key makes every sealed token
#                           unreadable; GCP never deletes a key ring anyway
resource "google_kms_key_ring" "marketing" {
  name     = var.key_ring
  project  = var.gcp_project
  location = var.gcp_region

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key" "channel_tokens" {
  name            = var.crypto_key
  key_ring        = google_kms_key_ring.marketing.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = var.rotation_period

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = "SOFTWARE"
  }

  labels = {
    org  = var.org
    app  = var.app
    env  = var.env
    role = "marketing-channel-tokens"
  }

  lifecycle {
    prevent_destroy = true
  }
}
