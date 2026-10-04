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
  description = "The environment whose backups this bucket holds: a cnf env name, e.g. dev or prd."

  validation {
    # spec 072 A8: the env names are the cnf's <env>.env.yaml files, not a
    # fixed pair; lde is local docker only and never reaches terraform.
    condition     = can(regex("^[a-z][a-z0-9]{1,9}$", var.env)) && var.env != "lde"
    error_message = "env must be a cnf env name (<env>.env.yaml: 2-10 lowercase letters or digits, a letter first), never lde."
  }
}

variable "gcp_region" {
  type        = string
  description = "The GCP region; the same as the env's, so a copy is a same-region rewrite."
}

variable "tf_key_project" {
  type        = string
  description = "The backup project (cnf; <org>-<app>-bkp by default): where the bucket lives AND whose SA key terraform runs as (do_tf_init). Never the env project: a copy inside the env's own project dies with it."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.tf_key_project)) && !endswith(var.tf_key_project, "-${var.env}")
    error_message = "tf_key_project must be a GCP project id (6-30 lowercase letters, digits or -) of the backup project, never an env project (<...>-<env>): the whole point is a project a destroy of the env does not touch."
  }
}

variable "offsite_bucket_name" {
  type        = string
  description = "The off-project bucket, <backup project>-<env> by default: one per env, so each env SA is granted on its own bucket only."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9_-]{1,61}[a-z0-9]$", var.offsite_bucket_name)) && !startswith(var.offsite_bucket_name, "goog")
    error_message = "offsite_bucket_name must be a GCS bucket name: 3-63 lowercase letters, digits, - or _, a letter or digit at each end, no goog prefix. Bucket names are GLOBAL: derive it from tf_key_project in cnf."
  }
}

variable "writer_service_account" {
  type        = string
  description = "The env's project SA (<project>@<project>.iam.gserviceaccount.com): it copies each new dump and file here, and may add, never read, overwrite or delete."
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
