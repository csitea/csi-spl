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

  # Google APIs (gcloud, GCS) without a public IP
  private_ip_google_access = true

  # a low-sample record of what the box talks to (cents per month)
  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.1
    metadata             = "EXCLUDE_ALL_METADATA"
  }
}

# Outbound internet (apt, npm, git, the agent CLIs' APIs) for a VM with no
# public IP: a Cloud Router + Cloud NAT on the satellite subnet only.
resource "google_compute_router" "satellite" {
  name    = "${var.vm_name}-router"
  network = google_compute_network.satellite.id
  region  = var.gcp_region
}

resource "google_compute_router_nat" "satellite" {
  name                               = "${var.vm_name}-nat"
  router                             = google_compute_router.satellite.name
  region                             = var.gcp_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.satellite.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
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
