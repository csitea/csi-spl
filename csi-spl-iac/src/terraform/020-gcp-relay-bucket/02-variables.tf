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
  description = "The environment: a cnf env name, e.g. dev or prd."

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

variable "relay_bucket_name" {
  type        = string
  description = "The relay bucket name, <project>-rel by default (cnf; owner decision 2026-09-17)."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9_-]{1,61}[a-z0-9]$", var.relay_bucket_name)) && !startswith(var.relay_bucket_name, "goog")
    error_message = "relay_bucket_name must be a GCS bucket name: 3-63 lowercase letters, digits, - or _, a letter or digit at each end, no goog prefix. Bucket names are GLOBAL: derive it from env.gcp.gcp_project in cnf."
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
