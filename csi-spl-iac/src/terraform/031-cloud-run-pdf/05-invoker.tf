# Only the hub may call the renderer (spec 183 7.1.6, owner Q5 SVC): one
# run.invoker member, the hub's runtime service account (030
# 03-runtime-sa.tf). No allUsers, no allAuthenticatedUsers: a call without the
# hub's ID token is answered 403 by Cloud Run before it reaches the container.
# The account is named, not read from 030's state, so this step plans and
# applies on its own.
resource "google_cloud_run_v2_service_iam_member" "hub_invoker" {
  project  = var.gcp_project
  location = google_cloud_run_v2_service.pdf.location
  name     = google_cloud_run_v2_service.pdf.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${var.hub_runtime_sa_account_id}@${var.gcp_project}.iam.gserviceaccount.com"
}
