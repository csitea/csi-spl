resource "google_project_service" "this" {
  for_each = toset(var.gcp_services)

  project = var.gcp_project
  service = each.value

  # Disabling an API on destroy takes down whatever else uses it.
  disable_on_destroy         = false
  disable_dependent_services = false
}

output "enabled_services" {
  value = sort([for s in google_project_service.this : s.service])
}
