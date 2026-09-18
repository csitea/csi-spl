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

variable "fqdn" {
  type        = string
  description = "The name the zone serves (cnf env.dns.fqdn, derived from env.dns.BASE_DOMAIN)."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?([.][a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.fqdn))
    error_message = "fqdn must be a lower-case DNS name with at least one dot."
  }
}

variable "zone_name" {
  type        = string
  description = "The EXISTING public Cloud DNS zone in this project that serves fqdn (cnf steps.025-gcp-dns-zone.zone_name). Empty = this env has no zone of its own (dev: its records live in the prd zone, see 031 dns_zone_project)."
  default     = ""
}

variable "zone_description" {
  type        = string
  description = "The zone's description, as it stands on the zone (an update is in place)."
  default     = ""
}
