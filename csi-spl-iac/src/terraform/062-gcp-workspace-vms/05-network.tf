# Own VPC, made only while a workspace VM exists: an empty workspace_vms plans
# no change. A project's default network carries default-allow-ssh from
# 0.0.0.0/0, so no workspace VM joins it.
resource "google_compute_network" "workspace" {
  count                   = local.any_vm ? 1 : 0
  name                    = "${var.vm_name_prefix}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "workspace" {
  count                    = local.any_vm ? 1 : 0
  name                     = "${var.vm_name_prefix}-${var.gcp_region}"
  network                  = google_compute_network.workspace[0].id
  region                   = var.gcp_region
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.1
    metadata             = "EXCLUDE_ALL_METADATA"
  }
}

# The ONE ingress rule: tcp/22 from ssh_source_ranges, for upkeep.
resource "google_compute_firewall" "ssh" {
  count       = local.any_vm ? 1 : 0
  name        = local.ssh_tag
  network     = google_compute_network.workspace[0].id
  direction   = "INGRESS"
  target_tags = [local.ssh_tag]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.ssh_source_ranges
}
