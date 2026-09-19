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
  description = "The EXISTING public Cloud DNS zone in this project that serves fqdn (cnf steps.025-gcp-dns-zone.zone_name). Empty = this env has no zone of its own (no env uses that today: dev has its own subzone)."
  default     = ""
}

variable "zone_description" {
  type        = string
  description = "The zone's description, as it stands on the zone (an update is in place)."
  default     = ""
}

variable "parent_zone_name" {
  type        = string
  description = "The parent (apex) zone this env's subzone is delegated from (cnf steps.025-gcp-dns-zone.parent_zone_name). Empty (prd) = zone_name IS the apex zone and is adopted; set (dev) = zone_name is created here and an NS record for it is written into the parent zone."
  default     = ""
}

variable "parent_zone_project" {
  type        = string
  description = "The project holding parent_zone_name (cnf steps.025-gcp-dns-zone.parent_zone_project). Its own key, ~/.gcp/.<org>/key-<project>.json, writes the delegation record."
  default     = ""
}

variable "cloud_run_mapping_records" {
  type = list(object({
    name    = string       # relative to fqdn: "api", "dev.api", "t1"
    type    = string       # A, AAAA or CNAME
    rrdatas = list(string) # what the 032 domain mapping asks for
  }))
  description = "Records for the 032 Cloud Run domain mappings, written into zone_name (csi-rel 007-dns 05.03.api-dns-records.tf). Rendered from cnf: steps.025-gcp-dns-zone.cloud_run_mapping_records plus one ghs CNAME per env.dns.mapped_tenants entry. Empty = none."
  default     = []

  validation {
    condition     = alltrue([for r in var.cloud_run_mapping_records : contains(["A", "AAAA", "CNAME"], r.type)])
    error_message = "cloud_run_mapping_records type must be A, AAAA or CNAME."
  }
}
