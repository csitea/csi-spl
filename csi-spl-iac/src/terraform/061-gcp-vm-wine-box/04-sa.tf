# The VM's own identity: the roles named in cnf, and nothing that could spend.
resource "google_service_account" "wine" {
  account_id   = var.vm_name
  display_name = "wine-box test VM"
}

resource "google_project_iam_member" "wine" {
  for_each = toset(var.vm_sa_roles)
  project  = var.gcp_project
  role     = each.value
  member   = "serviceAccount:${google_service_account.wine.email}"
}

resource "google_project_service" "extra" {
  for_each                   = toset(var.extra_apis)
  project                    = var.gcp_project
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false
}
