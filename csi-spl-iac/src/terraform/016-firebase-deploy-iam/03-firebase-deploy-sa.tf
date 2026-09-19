# Dedicated SA the WUI pipeline uses to run `firebase deploy --only hosting`.
# Spec 005 / SPEC-spool-wui.md: Firebase Hosting for the WUI, Cloud Run for the
# hub. No shop pages. No service-account key resource — WIF impersonates this
# SA (017). Apply still needs an owner go.
resource "google_service_account" "firebase_deploy" {
  account_id   = var.deploy_sa_account_id
  display_name = "csi-spl ${var.env} Firebase Hosting deploy"
  description  = "CI deploy SA for Firebase Hosting (csi-spl-${var.env}-site). Managed by 016-firebase-deploy-iam."
}

resource "google_project_iam_member" "firebase_deploy" {
  for_each = toset(var.deploy_roles)
  project  = var.gcp_project
  role     = each.value
  member   = "serviceAccount:${google_service_account.firebase_deploy.email}"
}

data "google_project" "this" {
  count      = var.bind_github_wif ? 1 : 0
  project_id = var.gcp_project
}

resource "google_service_account_iam_member" "github_wif_user" {
  count = var.bind_github_wif ? 1 : 0

  service_account_id = google_service_account.firebase_deploy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${data.google_project.this[0].number}/locations/global/workloadIdentityPools/${var.wif_pool_id}/attribute.ref/${var.github_ref}"
}
