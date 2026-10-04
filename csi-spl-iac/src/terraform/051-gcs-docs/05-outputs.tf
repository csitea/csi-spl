output "docs_bucket" {
  value = "gs://${google_storage_bucket.docs.name}"
}

output "docs_bucket_name" {
  value = google_storage_bucket.docs.name
}
