variable "org" {
  type        = string
  description = "The 3-letter organisation code (csi)."
}

variable "app" {
  type        = string
  description = "The application code (spl)."
}

variable "env" {
  type        = string
  description = "The environment: dev or prd (lde is local docker only, never terraform)."

  validation {
    condition     = contains(["dev", "prd"], var.env)
    error_message = "env must be dev or prd."
  }
}

variable "gcp_project" {
  type        = string
  description = "The GCP project id, csi-spl-<env>."
}

variable "gcp_region" {
  type        = string
  description = "The GCP region every resource of the spool lives in."
  default     = "europe-north1"
}

variable "deploy_sa_account_id" {
  type        = string
  description = "account_id of the Firebase Hosting deploy SA (cnf steps.016-firebase-deploy-iam.deploy_sa_account_id)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.deploy_sa_account_id))
    error_message = "deploy_sa_account_id must be a valid GCP service-account id (6-30 chars)."
  }
}

# Least-privilege roles for `firebase deploy --only hosting`. No SA key is
# minted: CI impersonates this SA via WIF (017). A JSON key in tf state is
# forbidden in this repo (iac tests grep for google_service_account_key).
variable "deploy_roles" {
  type = list(string)
  default = [
    "roles/firebasehosting.admin",
    "roles/serviceusage.serviceUsageConsumer",
    "roles/run.viewer",
  ]
  description = "Project-level roles bound to the firebase-deploy SA."
}

# CI identity for the WUI deploy workflow (30_wui-build-deploy.yml): trunk
# runs of the pool that 017 creates may impersonate THIS SA. false (default)
# until 017 is applied in this env; then true and re-apply. Same principal
# set 017 binds to its own deploy SA: the pinned ref of the pool.
variable "bind_github_wif" {
  type        = bool
  default     = false
  description = "Grant roles/iam.workloadIdentityUser on the firebase-deploy SA to the 017 pool's trunk principal set (cnf steps.016-firebase-deploy-iam.bind_github_wif)."
}

variable "wif_pool_id" {
  type        = string
  default     = "github-actions"
  description = "The 017 workload identity pool id (cnf steps.017-github-wif-deploy.pool_id)."
}

variable "github_ref" {
  type        = string
  default     = "refs/heads/master"
  description = "The only ref whose runs may impersonate the SA (cnf steps.017-github-wif-deploy.github_ref)."
}
