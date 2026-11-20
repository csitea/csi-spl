# The renderer's runtime identity (spec 183 7.1.6). It holds NO role: the
# renderer reads only the HTML in its request body, writes only its own temp
# dir and calls nothing. Its image is pulled by the Cloud Run service agent,
# never by this account.
resource "google_service_account" "pdf" {
  project      = var.gcp_project
  account_id   = var.runtime_sa_account_id
  display_name = "${var.org}-${var.app}-${var.env} topic PDF renderer runtime"
  description  = "Cloud Run ${var.service_name}: no role; only the hub may call the service"
}
