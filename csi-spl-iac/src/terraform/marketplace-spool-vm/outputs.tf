output "instance_name" {
  description = "Name of the Spool Hub VM."
  value       = google_compute_instance.spool.name
}

output "external_ip" {
  description = "Ephemeral public address of the Spool Hub VM."
  value       = google_compute_instance.spool.network_interface[0].access_config[0].nat_ip
}

output "spool_doc_path" {
  description = "Path of the AGPL source tree on the VM."
  value       = "/usr/local/share/doc/spool-hub/"
}
