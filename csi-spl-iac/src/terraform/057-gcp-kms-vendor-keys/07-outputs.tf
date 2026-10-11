# The key's full resource name, the one the hub passes to KMS
# (projects/<p>/locations/<r>/keyRings/<ring>/cryptoKeys/<key>).
output "crypto_key_id" {
  value = google_kms_crypto_key.dek_wrap.id
}

# The pepper slot's id (no value: the slot is empty until the put action).
output "pepper_secret_id" {
  value = google_secret_manager_secret.pepper.secret_id
}
