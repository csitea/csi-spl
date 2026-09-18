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

# Step vars for 017-github-wif-deploy. Sourced from
# steps["017-github-wif-deploy"] in the per-env yaml (rendered by tpl-gen).

variable "github_repository" {
  type        = string
  description = "GitHub <owner>/<repo> whose Actions OIDC tokens may impersonate the deploy SA. No default — the trust boundary must be explicit per env."

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be <owner>/<repo>."
  }
}

variable "pool_id" {
  type        = string
  default     = "github-actions"
  description = "Workload Identity Pool id (4-32 chars, lowercase letters, digits, dashes)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}[a-z0-9]$", var.pool_id))
    error_message = "pool_id must be 4-32 chars, start with a letter, lowercase letters/digits/dashes."
  }
}

variable "provider_id" {
  type        = string
  default     = "github"
  description = "Workload Identity Pool provider id."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}[a-z0-9]$", var.provider_id))
    error_message = "provider_id must be 4-32 chars, start with a letter, lowercase letters/digits/dashes."
  }
}

variable "deploy_sa_account_id" {
  type        = string
  description = "account_id of the deploy service account this step CREATES (cnf steps.017-github-wif-deploy.deploy_sa_account_id, csi-spl-deploy-<env>). The workflows impersonate it through WIF; no JSON key is minted."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.deploy_sa_account_id))
    error_message = "deploy_sa_account_id must be 6-30 chars, start with a letter, lowercase letters/digits/dashes."
  }
}

# What the deploy job touches (20_hub-build-deploy.yml). Each grant below is
# scoped to one resource, so those resources must exist first: 017 applies
# after 028 and 030 (spec 007, contracts/provisioning-order.md).

variable "artifact_repository_id" {
  type        = string
  description = "The hub's Artifact Registry repository (028, cnf steps.028-gcp-artifact-registry.repository_id). The deploy SA reads and pushes images there."
}

variable "hub_service_name" {
  type        = string
  description = "The hub's Cloud Run service (030, cnf hub.service_name). The deploy SA rolls its image."
}

variable "hub_runtime_sa_account_id" {
  type        = string
  description = "account_id of the hub's runtime SA (030, cnf hub.runtime_sa_account_id). Updating the service deploys a revision that runs as it, which needs iam.serviceAccounts.actAs on it."
}
