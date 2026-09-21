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

variable "instance_name" {
  type        = string
  description = "The Cloud SQL instance whose dumps land here, csi-spl-<env>-pg (040). Read, never created, by this step: the grant below needs the instance's Google-managed service agent."

  validation {
    condition     = can(regex("^csi-spl-(dev|prd)-pg$", var.instance_name))
    error_message = "instance_name must be csi-spl-dev-pg or csi-spl-prd-pg."
  }
}

variable "backups_bucket_name" {
  type        = string
  description = "The off-instance dump bucket, csi-spl-<env>-db-backups. Its OWN bucket, never the files (050) or relay (020) bucket: the grant below is wider than 'create an object', and a separate bucket is what stops it reaching anything else."

  validation {
    condition     = can(regex("^csi-spl-(dev|prd)-db-backups$", var.backups_bucket_name))
    error_message = "backups_bucket_name must be csi-spl-dev-db-backups or csi-spl-prd-db-backups."
  }
}

variable "backup_max_age_days" {
  type        = number
  description = "Lifecycle: delete a dump older than N days. This is the retention of the OFF-INSTANCE copies, and it is deliberately longer than the instance's own retainedBackups (7), which is the whole reason this bucket exists."

  validation {
    condition     = var.backup_max_age_days >= 7 && var.backup_max_age_days <= 3650
    error_message = "backup_max_age_days must be between 7 and 3650: below 7 the bucket keeps less than the instance's own automated backups, which makes it pointless."
  }
}

variable "soft_delete_retention_seconds" {
  type        = number
  description = "Soft-delete retention, as 020 and 050 (604800 = 7 days, the GCS default). A dump deleted by accident is recoverable for this long."
  default     = 604800
}
