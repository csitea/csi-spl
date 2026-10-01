# spec 057 the satellite: ONE always-on agent box for dev and prd, ssh only.
# Shape from csi-rel 050-gcp-vm-rdb 05.vm.tf (instance + a separate data disk
# attached by device_name, the label set, allow_stopping_for_update), with its
# tls_private_key dropped (round 2 Q3 b: only the public key is read here).
locals {
  labels = {
    org        = var.org
    app        = var.app
    env        = var.env
    managed_by = "terraform"
    step       = "060-gcp-vm-satellite"
    box        = var.box_label
  }
  ssh_tag = "allow-ssh-iap-${var.vm_name}"
}

resource "google_compute_disk" "data" {
  # checkov:skip=CKV_GCP_37: Google-managed encryption; a CSEK would put a raw key in tfvars or state (R14)
  name   = var.data_disk_name
  type   = var.data_disk_type
  size   = var.data_disk_size_gb
  zone   = var.gcp_zone
  labels = merge(local.labels, { role = "satellite-data" })

  # no snapshots (round 1 Q13: git is the backup), so the disk itself is
  # never destroyed by terraform
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_instance" "satellite" {
  # checkov:skip=CKV_GCP_38: Google-managed encryption; a CSEK would put a raw key in tfvars or state (R14)
  name         = var.vm_name
  machine_type = var.machine_type
  zone         = var.gcp_zone
  tags         = [local.ssh_tag]
  labels       = merge(local.labels, { role = "satellite" })

  boot_disk {
    initialize_params {
      image  = var.boot_disk_image
      size   = var.boot_disk_size_gb
      type   = "pd-balanced"
      labels = merge(local.labels, { role = "satellite-boot" })
    }
  }

  attached_disk {
    source      = google_compute_disk.data.id
    device_name = "satellite-data"
    mode        = "READ_WRITE"
  }

  network_interface {
    # no public IP at all: outbound goes through Cloud NAT (05), inbound is
    # tcp/22 from IAP only (round 1 Q7 A; NAT replaces the ephemeral IP at the
    # same ~$4/month and leaves the VM with no internet-facing address)
    subnetwork = google_compute_subnetwork.satellite.id
  }

  metadata = {
    ssh-keys               = "${var.os_user}:${trimspace(file(pathexpand(var.ssh_public_key_file)))}"
    enable-oslogin         = "FALSE"
    block-project-ssh-keys = "TRUE"
  }

  service_account {
    email  = google_service_account.satellite.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  allow_stopping_for_update = true
}
