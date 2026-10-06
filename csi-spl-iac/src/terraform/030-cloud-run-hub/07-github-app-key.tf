# spec 075 repo-edit T01: the GitHub App private key's Secret Manager slot
# (cnf env.docs.repo_edit.secret_env) and the hub runtime SA's read on it.
#
# The slot already exists in dev and prd: do_spl_gh_app_manifest created it
# (do_spl_gh_app_key_put: user-managed in the region, labels role=hub-github-app)
# and added the key version out of band. So it is IMPORTED here, never created,
# and its arguments match that create exactly, or the plan would replace it.
# No google_secret_manager_secret_version: a version resource puts the value
# into state.
#
# The accessor exists whether or not the key is injected; SPOOL_GITHUB_APP_KEY
# joins secret_environment_variables only while cnf docs.repo_edit.inject is
# "true" (030's tfvars template), and 03's generic binding skips this slot so
# the same member is never managed twice.
import {
  to = google_secret_manager_secret.github_app_key
  id = "projects/${var.gcp_project}/secrets/${var.github_app_key_secret_id}"
}

resource "google_secret_manager_secret" "github_app_key" {
  project   = var.gcp_project
  secret_id = var.github_app_key_secret_id

  replication {
    user_managed {
      replicas {
        location = var.gcp_region
      }
    }
  }

  labels = {
    org  = var.org
    app  = var.app
    env  = var.env
    role = "hub-github-app"
  }
}

resource "google_secret_manager_secret_iam_member" "hub_github_app_key_accessor" {
  project   = var.gcp_project
  secret_id = google_secret_manager_secret.github_app_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.hub.email}"
}
