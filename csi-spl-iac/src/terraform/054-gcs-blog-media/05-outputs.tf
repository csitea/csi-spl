output "media_bucket" {
  value = "gs://${google_storage_bucket.media.name}"
}

output "media_bucket_name" {
  value = google_storage_bucket.media.name
}
