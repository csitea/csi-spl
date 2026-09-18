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
