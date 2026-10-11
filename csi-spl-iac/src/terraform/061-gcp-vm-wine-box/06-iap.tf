# Extra IAP tunnel users. An empty iap_members list adds no binding.
# Granting a person outside the project is an IAM change and is not done here.
resource "google_iap_tunnel_instance_iam_member" "wine" {
  for_each = toset(var.iap_members)
  project  = var.gcp_project
  zone     = var.gcp_zone
  instance = google_compute_instance.wine.name
  role     = "roles/iap.tunnelResourceAccessor"
  member   = each.value
}
