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
