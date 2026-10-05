# The key's full resource name, the one the hub passes to KMS
# (projects/<p>/locations/<r>/keyRings/<ring>/cryptoKeys/<key>).
output "crypto_key_id" {
  value = google_kms_crypto_key.channel_tokens.id
}
