# tenant -> the VM's name, zone and labels (the provisioning action, row B8,
# and the per-VM cost read, row B4, read them).
output "workspace_vms" {
  value = {
    for tenant, vm in google_compute_instance.workspace : tenant => {
      name   = vm.name
      zone   = vm.zone
      labels = vm.labels
    }
  }
}
