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

variable "state_bucket_name" {
  type        = string
  description = "The boxes' nightly state bucket (owner t1 d80ed72c): <project>-box-state by default."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9_-]{1,61}[a-z0-9]$", var.state_bucket_name)) && !startswith(var.state_bucket_name, "goog")
    error_message = "state_bucket_name must be a GCS bucket name: 3-63 lowercase letters, digits, - or _, a letter or digit at each end, no goog prefix. Bucket names are GLOBAL: derive it from env.gcp.gcp_project in cnf."
  }
}

variable "writer_sa_account_id" {
  type        = string
  description = "account_id of the boxes' WRITE-ONLY backup SA: objectCreator on this bucket and nothing else."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.writer_sa_account_id))
    error_message = "writer_sa_account_id must be a valid GCP service-account id (6-30 chars)."
  }
}

variable "project_sa_email" {
  type        = string
  description = "The env's project SA (gcp-002): it may mint short-lived tokens for the writer SA (no key), and reads the bucket for a restore as roles/owner."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]+\\.iam\\.gserviceaccount\\.com$", var.project_sa_email))
    error_message = "project_sa_email must be a service-account email <id>@<project>.iam.gserviceaccount.com."
  }
}

variable "retention_days" {
  type        = number
  description = "Lifecycle: an object older than this is deleted (owner: 30 days)."
  default     = 30

  validation {
    condition     = var.retention_days >= 1 && var.retention_days <= 365
    error_message = "retention_days must be 1..365."
  }
}

variable "soft_delete_retention_seconds" {
  type        = number
  description = "Soft-delete retention, as 050/051/054 (604800 = 7 days, the GCS default)."
  default     = 604800
}
