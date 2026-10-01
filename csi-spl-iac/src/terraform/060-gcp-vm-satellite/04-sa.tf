# The VM's own identity: logs and metrics only. The agents on the satellite
# use the per-env SA keys like the home box (round 1 Q12 A), so this SA holds
# nothing a stolen metadata token could spend.
resource "google_service_account" "satellite" {
  account_id   = var.vm_name
  display_name = "the satellite agent box (spec 057): logging + monitoring only"
}

resource "google_project_iam_member" "satellite" {
  for_each = toset(["roles/logging.logWriter", "roles/monitoring.metricWriter"])
  project  = var.gcp_project
  role     = each.value
  member   = "serviceAccount:${google_service_account.satellite.email}"
}
