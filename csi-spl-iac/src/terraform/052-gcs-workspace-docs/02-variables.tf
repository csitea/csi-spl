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

variable "bucket_prefix" {
  type        = string
  description = "Each workspace's docs bucket is <bucket_prefix><workspace slug> (spec 075 4.1: <project>-docs-). The hub derives the same name from this one cnf key."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,28}-$", var.bucket_prefix)) && !startswith(var.bucket_prefix, "goog")
    error_message = "bucket_prefix must be 3-30 lowercase letters, digits or -, a letter or digit first, ending in -, no goog prefix. Bucket names are GLOBAL: derive it from env.gcp.gcp_project in cnf."
  }
}

variable "workspaces" {
  type        = list(string)
  description = "The workspace (tenant) slugs of this env that get a docs bucket each. Dropping a slug plans a destroy, which force_destroy = false refuses on a non-empty bucket."

  validation {
    # the tenant slug rule (do_spl_tenant_host_provision TENANT_ID), and no
    # duplicate: a duplicate would collapse two for_each keys into one.
    condition     = alltrue([for w in var.workspaces : can(regex("^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$", w))]) && length(distinct(var.workspaces)) == length(var.workspaces)
    error_message = "workspaces must be distinct tenant slugs: 1-32 lowercase letters, digits or -, a letter or digit at each end."
  }
}

variable "hub_runtime_sa_account_id" {
  type        = string
  description = "account_id of the hub's runtime service account (cnf hub.runtime_sa_account_id, created by 030): it READS AND WRITES the workspace docs."
}

variable "soft_delete_retention_seconds" {
  type        = number
  description = "Soft-delete retention, as 020/050/051 (604800 = 7 days, the GCS default)."
  default     = 604800
}
