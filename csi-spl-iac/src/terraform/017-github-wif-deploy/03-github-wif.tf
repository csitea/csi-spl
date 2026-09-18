# GitHub Actions -> GCP keyless auth (Workload Identity Federation) for the
# deploy workflows of this env. Spec 007 T007: CI deploy identity. Replaces a
# long-lived GCP SA JSON key (forbidden in this repo — iac tests grep for
# google_service_account_key) with short-lived OIDC tokens minted by GitHub
# and exchanged at sts.googleapis.com for an impersonation of the deploy SA.
#
# Nothing sensitive lands in tfstate: a pool + provider are public metadata and
# the SA binding is an IAM policy. The workflows consume two repo VARIABLES
# (not secrets) per env, exported below:
#   GCP_WIF_PROVIDER_<ENV>    = output.wif_provider_name
#   GCP_DEPLOY_SA_EMAIL_<ENV> = output.deploy_sa_email
#
# Trust is pinned to ONE repository (attribute_condition) — a token minted for
# any other repo, fork or org is refused at the provider, before IAM is even
# consulted.
#
# The deploy SA is CREATED here. (An earlier draft bound WIF to the
# "<project>@<project>.iam.gserviceaccount.com" owner SA; measured 2026-09-18,
# `gcloud iam service-accounts list` shows no such SA in csi-spl-dev or
# csi-spl-prd, so that apply would have failed.) Its grants are exactly what
# the deploy job does and each is scoped to one resource: push/read images in
# the 028 repository, roll the 030 service, act as the hub runtime SA.
#
# Needs iamcredentials.googleapis.com and sts.googleapis.com (cnf 001 list).
# Apply order: after 028 and 030. Apply still needs an owner go.

locals {
  hub_runtime_sa_email = "${var.hub_runtime_sa_account_id}@${var.gcp_project}.iam.gserviceaccount.com"
}

resource "google_service_account" "deploy" {
  project      = var.gcp_project
  account_id   = var.deploy_sa_account_id
  display_name = "CI deploy (${var.env})"
  description  = "Impersonated by the ${var.github_repository} GitHub Actions deploy workflows via WIF. No key. Managed by 017-github-wif-deploy."
}

resource "google_artifact_registry_repository_iam_member" "deploy_writer" {
  project    = var.gcp_project
  location   = var.gcp_region
  repository = var.artifact_repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_cloud_run_v2_service_iam_member" "deploy_developer" {
  project  = var.gcp_project
  location = var.gcp_region
  name     = var.hub_service_name
  role     = "roles/run.developer"
  member   = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_service_account_iam_member" "deploy_acts_as_hub" {
  service_account_id = "projects/${var.gcp_project}/serviceAccounts/${local.hub_runtime_sa_email}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.gcp_project
  workload_identity_pool_id = var.pool_id
  display_name              = "GitHub Actions (${var.env})"
  description               = "OIDC trust for the ${var.github_repository} deploy workflows. Managed by 017-github-wif-deploy."
  disabled                  = false
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.gcp_project
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = "GitHub OIDC"
  description                        = "token.actions.githubusercontent.com, restricted to ${var.github_repository}."

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.actor"            = "assertion.actor"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
    "attribute.ref"              = "assertion.ref"
    "attribute.workflow"         = "assertion.workflow"
  }

  # Only tokens issued for this exact repository may exchange at all.
  attribute_condition = "assertion.repository == \"${var.github_repository}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Any job of the pinned repository may impersonate the deploy SA. Narrow to a
# branch later by switching the member to
#   .../attribute.ref/refs/heads/master
# once every deploy workflow runs from master only (workflow_dispatch from a
# branch would then be refused).
resource "google_service_account_iam_member" "github_wif_user" {
  service_account_id = google_service_account.deploy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}
