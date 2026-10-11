# Own VPC. A project's default network carries default-allow-ssh from
# 0.0.0.0/0, so this VM never joins it.
resource "google_compute_network" "wine" {
  name                    = "${var.vm_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "wine" {
  name                     = "${var.vm_name}-${var.gcp_region}"
  network                  = google_compute_network.wine.id
  region                   = var.gcp_region
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.1
    metadata             = "EXCLUDE_ALL_METADATA"
  }
}

# The ONE ingress rule: tcp/22 from ssh_source_ranges. The VNC port is not
# in this rule. It is bound to localhost by the playbook.
resource "google_compute_firewall" "ssh" {
  name        = local.ssh_tag
  network     = google_compute_network.wine.id
  direction   = "INGRESS"
  target_tags = [local.ssh_tag]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.ssh_source_ranges
}
