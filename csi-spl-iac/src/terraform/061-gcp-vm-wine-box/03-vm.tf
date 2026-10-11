# One test VM. Its own VPC (05), one ingress rule, Wine and a localhost-only
# VNC desktop installed by box-playbook.yaml during the apply.
locals {
  labels = {
    org        = var.org
    app        = var.app
    env        = var.env
    managed_by = "terraform"
    step       = "061-gcp-vm-wine-box"
    box        = var.box_label
  }
  ssh_tag      = "allow-ssh-${var.vm_name}"
  admin_pubkey = "${var.os_user}:${trimspace(file(pathexpand(var.ssh_public_key_file)))}"
  desktop_pubkeys = [
    for key in var.desktop_user_ssh_public_keys : "${var.desktop_user}:${trimspace(key)}"
  ]
}

resource "google_compute_disk" "data" {
  # checkov:skip=CKV_GCP_37: Google-managed encryption; a CSEK would put a raw key in tfvars or state
  count  = var.data_disk_enabled ? 1 : 0
  name   = var.data_disk_name
  type   = var.data_disk_type
  size   = var.data_disk_size_gb
  zone   = var.gcp_zone
  labels = merge(local.labels, { role = "wine-box-data" })
}

resource "google_compute_instance" "wine" {
  # checkov:skip=CKV_GCP_38: Google-managed encryption; a CSEK would put a raw key in tfvars or state
  # checkov:skip=CKV_GCP_40: the desktop port stays on localhost. SSH is limited to ssh_source_ranges. An ephemeral public address lets a plain SSH tunnel reach the box and is released when the VM stops, so there is no Cloud NAT hourly charge while it is idle.
  name         = var.vm_name
  machine_type = var.machine_type
  zone         = var.gcp_zone
  hostname     = var.vm_hostname
  tags         = [local.ssh_tag]
  labels       = merge(local.labels, { role = "wine-box" })

  boot_disk {
    initialize_params {
      image  = var.boot_disk_image
      size   = var.boot_disk_size_gb
      type   = var.boot_disk_type
      labels = merge(local.labels, { role = "wine-box-boot" })
    }
  }

  dynamic "attached_disk" {
    for_each = { for disk in google_compute_disk.data : disk.name => disk.id }
    content {
      source      = attached_disk.value
      device_name = var.data_disk_device_name
      mode        = "READ_WRITE"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.wine.id

    dynamic "access_config" {
      for_each = var.assign_external_ip ? [1] : []
      content {}
    }
  }

  metadata = {
    ssh-keys                = join("\n", concat([local.admin_pubkey], local.desktop_pubkeys))
    enable-oslogin          = "FALSE"
    block-project-ssh-keys  = "TRUE"
    enable-guest-attributes = "TRUE"
  }

  service_account {
    email  = google_service_account.wine.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  allow_stopping_for_update = true

  depends_on = [google_project_service.extra]
}
