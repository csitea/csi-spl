# SPL-5262: a GCE persistent disk cannot shrink, and its name and type are
# fixed, so with data_disk_enabled a smaller data_disk_size_gb (a typo),
# another type or another name plans as destroy + create of
# google_compute_disk.data[0]: the data disk wiped. The disk's precondition
# (03-vm.tf) refuses that at PLAN time. The same guard as step 060; why not
# prevent_destroy or a validation: 060-gcp-vm-satellite/08-data-disk-guard.tf.
#
# The plan reads the LIVE disk named by this step's last applied state (its
# data_disk_name output, 09-outputs.tf). No such output (data disk off, a
# fresh or destroyed step, or an apply before SPL-5262): nothing to read, and
# the plan runs as before. data_disk_enabled = false is the deliberate off
# switch: it removes the disk, so the guard does not read it then.
data "terraform_remote_state" "self" {
  backend = "gcs"
  config = {
    bucket = "${var.gcp_project}-tfstate"
    prefix = "terraform/${local.labels.step}"
  }
}

locals {
  data_disk_applied_name = try(data.terraform_remote_state.self.outputs.data_disk_name, "")
}

data "google_compute_disk" "data_live" {
  count = var.data_disk_enabled && local.data_disk_applied_name != "" ? 1 : 0
  name  = local.data_disk_applied_name
  zone  = var.gcp_zone
}

locals {
  # alltrue over the 0 or 1 live disks: HCL does not short-circuit ||
  data_disk_keeps = alltrue([
    for d in data.google_compute_disk.data_live :
    var.data_disk_name == d.name && var.data_disk_size_gb >= d.size && var.data_disk_type == d.type
  ])
  data_disk_live_text = join("", [for d in data.google_compute_disk.data_live : "${d.name} ${d.size} GB ${d.type}"])
}
