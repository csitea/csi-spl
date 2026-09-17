output "relay_bucket" {
  value = "gs://${google_storage_bucket.relay.name}"
}

output "relay_sa_email" {
  value = google_service_account.relay.email
}
