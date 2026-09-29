output "offsite_bucket" {
  value = "gs://${google_storage_bucket.offsite.name}"
}

output "offsite_bucket_name" {
  value = google_storage_bucket.offsite.name
}
