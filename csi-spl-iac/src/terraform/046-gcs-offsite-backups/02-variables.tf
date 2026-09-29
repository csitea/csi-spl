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
  description = "The environment whose backups this bucket holds: dev or prd."

  validation {
    condition     = contains(["dev", "prd"], var.env)
    error_message = "env must be dev or prd."
  }
}

variable "gcp_region" {
  type        = string
  description = "The GCP region; the same as the env's, so a copy is a same-region rewrite."
}

variable "tf_key_project" {
  type        = string
  description = "The backup project, csi-spl-bkp: where the bucket lives AND whose SA key terraform runs as (do_tf_init). Never csi-spl-<env>: a copy inside the env's own project dies with it."

  validation {
    condition     = can(regex("^csi-spl-bkp$", var.tf_key_project))
    error_message = "tf_key_project must be csi-spl-bkp: the whole point is a project a destroy of csi-spl-dev/prd does not touch."
  }
}

variable "offsite_bucket_name" {
  type        = string
  description = "The off-project bucket, csi-spl-bkp-<env>: one per env, so each env SA is granted on its own bucket only."

  validation {
    condition     = can(regex("^csi-spl-bkp-(dev|prd)$", var.offsite_bucket_name))
    error_message = "offsite_bucket_name must be csi-spl-bkp-dev or csi-spl-bkp-prd."
  }
}

variable "writer_service_account" {
  type        = string
  description = "The env's project SA (csi-spl-<env>@csi-spl-<env>.iam.gserviceaccount.com): it copies each new dump and file here, and may add, never read, overwrite or delete."
}

variable "retention_days" {
  type        = number
  description = "Retention policy: no object can be deleted or overwritten by anyone before it is this old. Unlocked: locking is irreversible and is the owner's own call."

  validation {
    condition     = var.retention_days >= 7 && var.retention_days <= 365
    error_message = "retention_days must be between 7 and 365."
  }
}

variable "max_age_days" {
  type        = number
  description = "Lifecycle: delete an object older than this. At least retention_days (a lifecycle delete cannot beat the retention policy anyway)."
}

variable "noncurrent_max_age_days" {
  type        = number
  description = "Lifecycle: delete a noncurrent (replaced) version older than this."
}

variable "soft_delete_retention_seconds" {
  type        = number
  description = "Soft delete: a deleted object stays recoverable this long (max 90 days)."

  validation {
    condition     = var.soft_delete_retention_seconds >= 604800 && var.soft_delete_retention_seconds <= 7776000
    error_message = "soft_delete_retention_seconds must be between 7 and 90 days."
  }
}
