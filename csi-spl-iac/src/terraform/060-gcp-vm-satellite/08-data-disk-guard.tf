# SPL-5262: a GCE persistent disk cannot shrink, and its type is fixed, so a
# smaller data_disk_size_gb (a typo) or another data_disk_type plans as
# destroy + create of google_compute_disk.data: /mnt/data wiped, and the
# apply runs -auto-approve. The disk's precondition (03-vm.tf) refuses that
# at PLAN time.
#
# Why not the others:
#   prevent_destroy  also refuses the owner's destroy + recreate drills
#                    (03-vm.tf; satellite-actions.tst.sh keeps it off)
#   a validation     sees only the new value, never what is live
# So the plan reads the LIVE disk and compares. It reads it only when this
# step's last applied state holds the VM (its instance_name output; the VM
# attaches the disk): after a destroy drill the state is empty, there is no
# disk to read, and the recreate plans as before. A destroy plan checks no
# precondition, and -replace keeps the size, so both drills still run.
data "terraform_remote_state" "self" {
  backend = "gcs"
  config = {
    bucket = "${var.gcp_project}-tfstate"
    prefix = "terraform/${local.labels.step}"
  }
}

data "google_compute_disk" "data_live" {
  count = try(data.terraform_remote_state.self.outputs.instance_name, "") == "" ? 0 : 1
  name  = var.data_disk_name
  zone  = var.gcp_zone
}

locals {
  # alltrue over the 0 or 1 live disks: HCL does not short-circuit ||
  data_disk_keeps = alltrue([
    for d in data.google_compute_disk.data_live :
    var.data_disk_size_gb >= d.size && var.data_disk_type == d.type
  ])
  data_disk_live_text = join("", [for d in data.google_compute_disk.data_live : "${d.size} GB ${d.type}"])
}
