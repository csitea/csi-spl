output "instance_name" {
  value = google_compute_instance.wine.name
}

output "zone" {
  value = google_compute_instance.wine.zone
}

output "internal_ip" {
  value = google_compute_instance.wine.network_interface[0].network_ip
}

output "external_ip" {
  value = try(google_compute_instance.wine.network_interface[0].access_config[0].nat_ip, "")
}

# SPL-5262: the applied data disk's name, read back by 08-data-disk-guard.tf
# from this step's own state ("" while data_disk_enabled is false).
output "data_disk_name" {
  value = try(google_compute_disk.data[0].name, "")
}
