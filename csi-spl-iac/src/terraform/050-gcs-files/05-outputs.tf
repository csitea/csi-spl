output "files_bucket" {
  value = "gs://${google_storage_bucket.files.name}"
}

output "files_bucket_name" {
  value = google_storage_bucket.files.name
}
