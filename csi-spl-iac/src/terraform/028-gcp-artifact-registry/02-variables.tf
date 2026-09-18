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

variable "repository_id" {
  type        = string
  description = "The Docker repository, csi-spl-<env>-hub (cnf steps.028-gcp-artifact-registry.repository_id)."

  validation {
    condition     = can(regex("^csi-spl-(dev|prd)-hub$", var.repository_id))
    error_message = "repository_id must be csi-spl-dev-hub or csi-spl-prd-hub."
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
