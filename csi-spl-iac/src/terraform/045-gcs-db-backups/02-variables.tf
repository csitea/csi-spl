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

variable "instance_name" {
  type        = string
  description = "The Cloud SQL instance whose dumps land here, <project>-pg by default (040). Read, never created, by this step: the grant below needs the instance's Google-managed service agent."

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,82}[a-z0-9])?$", var.instance_name))
    error_message = "instance_name must be a Cloud SQL instance id: 1-84 lowercase letters, digits or -, a letter first, no - last."
  }
}

variable "backups_bucket_name" {
  type        = string
  description = "The off-instance dump bucket, <project>-db-backups by default. Its OWN bucket, never the files (050) or relay (020) bucket: the grant below is wider than 'create an object', and a separate bucket is what stops it reaching anything else."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9_-]{1,61}[a-z0-9]$", var.backups_bucket_name)) && !startswith(var.backups_bucket_name, "goog")
    error_message = "backups_bucket_name must be a GCS bucket name: 3-63 lowercase letters, digits, - or _, a letter or digit at each end, no goog prefix. Bucket names are GLOBAL: derive it from env.gcp.gcp_project in cnf."
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
