# Extra IAP tunnel users (the csi-spl-all SA holds roles/owner and may tunnel already).
resource "google_iap_tunnel_instance_iam_member" "satellite" {
  for_each = toset(var.iap_members)
  project  = var.gcp_project
  zone     = var.gcp_zone
  instance = google_compute_instance.satellite.name
  role     = "roles/iap.tunnelResourceAccessor"
  member   = each.value
}
