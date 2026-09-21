output "db_backups_bucket" {
  value = "gs://${google_storage_bucket.db_backups.name}"
}

output "db_backups_bucket_name" {
  value = google_storage_bucket.db_backups.name
}

output "sql_export_service_account" {
  description = "The instance service agent that writes the dumps; the one identity granted on this bucket."
  value       = data.google_sql_database_instance.hub.service_account_email_address
}
