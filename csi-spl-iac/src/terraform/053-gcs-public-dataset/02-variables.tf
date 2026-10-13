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

variable "public_bucket_name" {
  type        = string
  description = "The PUBLIC dataset bucket (spec 091 section 6): allUsers read, the SQL downloads only."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9_-]{1,61}[a-z0-9]$", var.public_bucket_name)) && !startswith(var.public_bucket_name, "goog")
    error_message = "public_bucket_name must be a GCS bucket name: 3-63 lowercase letters, digits, - or _, a letter or digit at each end, no goog prefix. Bucket names are GLOBAL: derive it from env.gcp.gcp_project in cnf."
  }
}

variable "staging_bucket_name" {
  type        = string
  description = "The PRIVATE staging bucket (spec 091 section 6): the day's candidate, its name lists and its verdicts."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9_-]{1,61}[a-z0-9]$", var.staging_bucket_name)) && !startswith(var.staging_bucket_name, "goog")
    error_message = "staging_bucket_name must be a GCS bucket name: 3-63 lowercase letters, digits, - or _, a letter or digit at each end, no goog prefix."
  }
}

variable "daily_retention_days" {
  type        = number
  description = "Lifecycle: a published daily object (under local.daily_prefix) older than this is deleted (spec 091 Q2: 30)."

  validation {
    condition     = var.daily_retention_days >= 1 && var.daily_retention_days <= 3650
    error_message = "daily_retention_days must be 1..3650."
  }
}

variable "stable_retention_days" {
  type        = number
  description = "Lifecycle: an object under stable/ (the file a stable release links) older than this is deleted (spec 091 Q2: 365)."

  validation {
    condition     = var.stable_retention_days >= 1 && var.stable_retention_days <= 3650
    error_message = "stable_retention_days must be 1..3650."
  }
}


variable "candidate_ttl_hours" {
  type        = number
  description = "cnf env.public_dataset.candidate_ttl_hours: a staging candidate older than this is dropped; the staging lifecycle deletes at the next whole day past it."

  validation {
    condition     = var.candidate_ttl_hours >= 1 && var.candidate_ttl_hours <= 720
    error_message = "candidate_ttl_hours must be 1..720."
  }
}

variable "export_sa_account_id" {
  type        = string
  description = "account_id of the export SA: Cloud SQL client and object create on staging; nothing on the public bucket."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.export_sa_account_id))
    error_message = "export_sa_account_id must be a valid GCP service-account id (6-30 chars)."
  }
}

variable "publish_sa_account_id" {
  type        = string
  description = "account_id of the publish SA: reads staging, creates objects in the public bucket, overwrites latest.json only; no database access."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.publish_sa_account_id))
    error_message = "publish_sa_account_id must be a valid GCP service-account id (6-30 chars)."
  }
}

variable "verifier_sa_account_id" {
  type        = string
  description = "account_id of the verifier SA: reads staging, creates under verdicts/ only."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.verifier_sa_account_id))
    error_message = "verifier_sa_account_id must be a valid GCP service-account id (6-30 chars)."
  }
}

# Constants of this step, not per-env facts (cnf-one-key-per-fact keeps a
# value both envs share out of the env files):
#   daily_prefix: the dated daily files live under it. GCS lifecycle has no
#     "not under stable/", so the daily rule needs its own prefix; latest.json
#     at the root is never aged out. The publish action (T008) writes there.
#   soft_delete_retention_seconds: as 050/051/054/056 (7 days, GCS default).
locals {
  daily_prefix                  = "daily/"
  soft_delete_retention_seconds = 604800
}
