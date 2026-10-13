output "public_bucket" {
  value = "gs://${google_storage_bucket.public.name}"
}

output "public_bucket_name" {
  value = google_storage_bucket.public.name
}

output "staging_bucket_name" {
  value = google_storage_bucket.staging.name
}

output "export_sa_email" {
  value = google_service_account.export.email
}

output "publish_sa_email" {
  value = google_service_account.publish.email
}

output "verifier_sa_email" {
  value = google_service_account.verifier.email
}
