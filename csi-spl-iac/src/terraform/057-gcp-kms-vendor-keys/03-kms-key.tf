# spec 127 I1 (section 4.2): the key that wraps the per-row DEK of every
# workspace vendor key. The hub keeps only ciphertext + the wrapped DEK in
# Postgres (workspace_vendor_keys, FORCE RLS, no operator_scope), so a DB
# backup without this key opens no row (L11).
#
#   one key ring, one key   symmetric ENCRYPT_DECRYPT, software protection
#   rotation                every rotation_period (90 days); old versions
#                           stay enabled, so older wrapped DEKs still open
#   prevent_destroy         a destroyed key makes every stored vendor key
#                           unreadable; GCP never deletes a key ring anyway
#
# Its own ring, apart from 055's marketing ring: the daily grant check
# (do_spl_vendor_key_grant_check) refuses ANY binding on this ring.
resource "google_kms_key_ring" "vendor_keys" {
  name     = var.key_ring
  project  = var.gcp_project
  location = var.gcp_region

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key" "dek_wrap" {
  name            = var.crypto_key
  key_ring        = google_kms_key_ring.vendor_keys.id
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
    role = "workspace-vendor-keys"
  }

  lifecycle {
    prevent_destroy = true
  }
}
