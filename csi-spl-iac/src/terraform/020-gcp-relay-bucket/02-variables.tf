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
  description = "The environment: dev or prd."

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

variable "relay_bucket_name" {
  type        = string
  description = "The relay bucket name, csi-spl-<env>-rel (owner decision 2026-09-17)."

  validation {
    condition     = can(regex("^csi-spl-(dev|prd)-rel$", var.relay_bucket_name))
    error_message = "relay_bucket_name must be csi-spl-dev-rel or csi-spl-prd-rel."
  }
}

variable "object_max_age_days" {
  type        = number
  description = "Lifecycle: delete objects older than N days. 0 = no lifecycle rule, which is what bnc-cpt-all-relay MEASURED on 2026-09-17 (git-rel's doc says 1)."
  default     = 0
}

variable "soft_delete_retention_seconds" {
  type        = number
  description = "Soft-delete retention. bnc-cpt-all-relay measured 604800 (7 days, the GCS default)."
  default     = 604800
}

variable "relay_sa_account_id" {
  type        = string
  description = "account_id of the service account git-rel uploads, signs URLs and deletes with."
}
