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

variable "files_bucket_name" {
  type        = string
  description = "The hub's file_id content bucket, csi-spl-<env>-files. NOT the git-rel relay bucket (020)."

  validation {
    condition     = can(regex("^csi-spl-(dev|prd)-files$", var.files_bucket_name))
    error_message = "files_bucket_name must be csi-spl-dev-files or csi-spl-prd-files."
  }
}

variable "soft_delete_retention_seconds" {
  type        = number
  description = "Soft-delete retention, as 020 (604800 = 7 days, the GCS default)."
  default     = 604800
}

variable "object_max_age_days" {
  type        = number
  description = "Lifecycle: delete objects older than N days. 0 = no rule: the hub's retention deletes files, a bucket rule could delete a file a retained message still names."
  default     = 0
}
