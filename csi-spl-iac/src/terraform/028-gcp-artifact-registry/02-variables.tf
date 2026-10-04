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
  description = "The environment: a cnf env name, e.g. dev or prd (lde is local docker only, never terraform)."

  validation {
    # spec 072 A8: the env names are the cnf's <env>.env.yaml files, not a
    # fixed pair; lde is local docker only and never reaches terraform.
    condition     = can(regex("^[a-z][a-z0-9]{1,9}$", var.env)) && var.env != "lde"
    error_message = "env must be a cnf env name (<env>.env.yaml: 2-10 lowercase letters or digits, a letter first), never lde."
  }
}

variable "gcp_project" {
  type        = string
  description = "The GCP project id: cnf env.gcp.gcp_project (by default <org>-<app>-<env>)."
}

variable "gcp_region" {
  type        = string
  description = "The GCP region every resource of the spool lives in."
  default     = "europe-north1"
}

variable "repository_id" {
  type        = string
  description = "The Docker repository, <project>-hub by default (cnf steps.028-gcp-artifact-registry.repository_id)."

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", var.repository_id))
    error_message = "repository_id must be an Artifact Registry repository id: 1-63 lowercase letters, digits or -, a letter first, no - last."
  }
}

variable "immutable_tags" {
  type        = bool
  description = "A pushed tag can never point at another image: the tag 030 runs (cnf hub.image.tag) IS one image."
  default     = true
}

variable "untagged_max_age_days" {
  type        = number
  description = "Untagged images (superseded layers of a failed push, etc.) older than this are deleted. Tagged images are never deleted by policy."
  default     = 7

  validation {
    condition     = var.untagged_max_age_days >= 1
    error_message = "untagged_max_age_days must be at least 1."
  }
}
