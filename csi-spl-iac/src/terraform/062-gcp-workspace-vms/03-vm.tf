# spec 181 B5: one private VM per private workspace, plan only (the apply is
# the owner's go per VM, spec 181 section 7). Every VM and its boot disk carry
# the labels workspace=<tenant> and box=<instance name>: the billing export
# prices a workspace's VM by them (spec 181 Q-8 A, row B4).
locals {
  base_labels = {
    org        = var.org
    app        = var.app
    env        = var.env
    managed_by = "terraform"
    step       = "062-gcp-workspace-vms"
  }
  vms = {
    for tenant, machine_type in var.workspace_vms : tenant => {
      name         = "${var.vm_name_prefix}-${tenant}"
      machine_type = machine_type
      labels = merge(local.base_labels, {
        workspace = tenant
        box       = "${var.vm_name_prefix}-${tenant}"
      })
    }
  }
  any_vm  = length(local.vms) > 0
  ssh_tag = "allow-ssh-${var.vm_name_prefix}"
}

resource "google_compute_instance" "workspace" {
  # checkov:skip=CKV_GCP_38: Google-managed encryption; a CSEK would put a raw key in tfvars or state
  # checkov:skip=CKV_GCP_40: an ephemeral public address is the VM's egress to the hub and the vendor APIs, released when it stops; no Cloud NAT hourly charge. Inbound is tcp/22 from ssh_source_ranges only.
  for_each     = local.vms
  name         = each.value.name
  machine_type = each.value.machine_type
  zone         = var.gcp_zone
  tags         = [local.ssh_tag]
  labels       = each.value.labels

  boot_disk {
    initialize_params {
      image  = var.boot_disk_image
      size   = var.boot_disk_size_gb
      type   = var.boot_disk_type
      labels = each.value.labels
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.workspace[0].id

    dynamic "access_config" {
      for_each = var.assign_external_ip ? [1] : []
      content {}
    }
  }

  # No ssh key in terraform: upkeep logs in through OS Login (IAM).
  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
  }

  service_account {
    email  = google_service_account.workspace[each.key].email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  allow_stopping_for_update = true

  # The step's check (spec 181 B5): a VM the billing export cannot attribute
  # to its workspace is refused at plan time.
  lifecycle {
    precondition {
      condition     = try(each.value.labels.workspace, "") == each.key
      error_message = "REFUSED (spec 181 B5): workspace VM ${each.value.name} has no workspace label equal to its tenant ${each.key}; the billing export could not price it."
    }
    precondition {
      condition     = try(each.value.labels.box, "") == each.value.name
      error_message = "REFUSED (spec 181 B5): workspace VM ${each.value.name} has no box label equal to its instance name."
    }
  }
}
