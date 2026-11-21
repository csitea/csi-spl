# Each VM's own identity: the roles named in cnf, and nothing that could
# spend. One account per workspace, so no VM acts as another's. An account id
# is 6..30 characters, so it is a hash of the tenant id.
resource "google_service_account" "workspace" {
  for_each     = local.vms
  account_id   = "ws-${substr(sha256(each.key), 0, 24)}"
  display_name = "private workspace VM ${each.value.name}"
}

resource "google_project_iam_member" "workspace" {
  for_each = {
    for pair in setproduct(keys(local.vms), var.vm_sa_roles) : "${pair[0]}/${pair[1]}" => {
      tenant = pair[0]
      role   = pair[1]
    }
  }
  project = var.gcp_project
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.workspace[each.value.tenant].email}"
}
