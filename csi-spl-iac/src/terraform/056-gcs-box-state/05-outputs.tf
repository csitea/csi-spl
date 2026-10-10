output "state_bucket" {
  value = "gs://${google_storage_bucket.state.name}"
}

output "state_bucket_name" {
  value = google_storage_bucket.state.name
}

output "writer_sa_email" {
  value = google_service_account.writer.email
}
