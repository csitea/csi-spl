output "instance_name" {
  value = google_sql_database_instance.hub.name
}

# <project>:<region>:<instance>, what 030 mounts at /cloudsql
output "connection_name" {
  value = google_sql_database_instance.hub.connection_name
}

output "database_name" {
  value = google_sql_database.spool.name
}

output "dsn_secret_id" {
  value = google_secret_manager_secret.hub_db_dsn.secret_id
}
