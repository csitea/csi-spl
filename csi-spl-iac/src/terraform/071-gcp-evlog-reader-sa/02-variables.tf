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
  description = "The GCP project id: cnf env.gcp.gcp_project (by default <org>-<app>-<env>). The reader SA lives here and reads only this project's logs."
}

variable "gcp_region" {
  type        = string
  description = "The GCP region every resource of the spool lives in."
  default     = "europe-north1"
}

variable "evlog_reader_sa_id" {
  type        = string
  description = "The event-log reader SA's account id: cnf env.gcp.evlog_reader_sa_id (spl-evlog-reader), spec 162 section 10.4.3."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.evlog_reader_sa_id))
    error_message = "evlog_reader_sa_id must be a service account id (6..30 chars, a-z 0-9 -)."
  }
}
