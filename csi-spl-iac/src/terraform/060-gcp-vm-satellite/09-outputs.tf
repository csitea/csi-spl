# No key, no secret: the name, zone and internal IP do_satellite_ssh_config uses.
output "instance_name" {
  value = google_compute_instance.satellite.name
}

output "zone" {
  value = google_compute_instance.satellite.zone
}

output "internal_ip" {
  value = google_compute_instance.satellite.network_interface[0].network_ip
}
