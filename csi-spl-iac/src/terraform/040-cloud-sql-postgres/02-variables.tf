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
  description = "The Cloud SQL instance, <project>-pg by default (cnf)."

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,82}[a-z0-9])?$", var.instance_name))
    error_message = "instance_name must be a Cloud SQL instance id: 1-84 lowercase letters, digits or -, a letter first, no - last."
  }
}

variable "database_version" {
  type        = string
  description = "Postgres major version, e.g. POSTGRES_16 (the lde container runs the same major)."
  default     = "POSTGRES_16"

  validation {
    condition     = can(regex("^POSTGRES_[0-9]+$", var.database_version))
    error_message = "database_version must be POSTGRES_<major>."
  }
}

variable "tier" {
  type        = string
  description = "Machine tier, e.g. db-f1-micro (dev) or db-g1-small (prd)."
}

variable "availability_type" {
  type        = string
  description = "ZONAL or REGIONAL (HA)."
  default     = "ZONAL"

  validation {
    condition     = contains(["ZONAL", "REGIONAL"], var.availability_type)
    error_message = "availability_type must be ZONAL or REGIONAL."
  }
}

variable "disk_size_gb" {
  type        = number
  description = "Initial SSD size in GB; autoresize grows it."
  default     = 10
}

variable "database_name" {
  type        = string
  description = "The hub's database inside the instance (spool schema only: spec 007 US4)."
  default     = "spool"
}

variable "deletion_protection" {
  type        = bool
  description = "Terraform- and API-level deletion protection on the instance."
  default     = true
}

variable "backup_enabled" {
  type        = bool
  description = "Daily automated backups (+ point-in-time recovery when true)."
  default     = true
}

variable "dsn_secret_id" {
  type        = string
  description = "Secret Manager secret id holding the hub's DSN (= hub.secret_env.SPOOL_HUB_DB_DSN in cnf). Terraform makes the empty SLOT only; the version is added out of band."
}

variable "owner_dsn_secret_id" {
  type        = string
  description = "Secret Manager secret id holding the schema OWNER's DSN (cnf hub.db_owner_dsn_secret; 017 T029). Only do_spl_db_bootstrap / `spool migrate` read it; 030 never injects or grants it. Empty slot only, like dsn_secret_id."

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]+$", var.owner_dsn_secret_id))
    error_message = "owner_dsn_secret_id must be a Secret Manager id."
  }
}

variable "query_insights_enabled" {
  type        = bool
  description = "Cloud SQL Query Insights: per-query latency and plans. Measured 2026-09-21 (spec 029 §3.5): there are NO per-statement timings on either env - pg_stat_statements is not installed, and turning THAT on restarts the instance. Insights is the additive, no-restart half of the same answer."
  default     = false
}

variable "query_insights_string_length" {
  type        = number
  description = "Bytes of each normalised query Insights stores (Cloud SQL replaces literals before storing, so this is shape, not data)."
  default     = 1024

  validation {
    condition     = var.query_insights_string_length >= 256 && var.query_insights_string_length <= 4500
    error_message = "query_insights_string_length must be between 256 and 4500."
  }
}

variable "query_insights_plans_per_minute" {
  type        = number
  description = "Execution plans sampled per minute (Cloud SQL allows 0-20; 5 is its default)."
  default     = 5

  validation {
    condition     = var.query_insights_plans_per_minute >= 0 && var.query_insights_plans_per_minute <= 20
    error_message = "query_insights_plans_per_minute must be between 0 and 20."
  }
}
