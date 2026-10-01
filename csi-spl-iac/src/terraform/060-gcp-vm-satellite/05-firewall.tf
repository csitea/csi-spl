# The satellite's own VPC: a new project's default network carries
# default-allow-ssh (0.0.0.0/0) and default-allow-internal, so the VM never
# joins it. One subnet, nothing else.
resource "google_compute_network" "satellite" {
  name                    = "${var.vm_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "satellite" {
  name          = "${var.vm_name}-${var.gcp_region}"
  network       = google_compute_network.satellite.id
  region        = var.gcp_region
  ip_cidr_range = var.subnet_cidr
}

# The ONE ingress rule for the satellite: tcp/22 from Google IAP. No http,
# https or any other port (spec 057 R7); a test fails on any other rule.
resource "google_compute_firewall" "ssh_iap" {
  name        = local.ssh_tag
  network     = google_compute_network.satellite.id
  direction   = "INGRESS"
  target_tags = [local.ssh_tag]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.ssh_source_ranges
}
