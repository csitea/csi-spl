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
  description = "The GCP project id: cnf env.gcp.gcp_project."
}

variable "gcp_region" {
  type        = string
  description = "The GCP region every resource of the spool lives in."
  default     = "europe-north1"
}

variable "fqdn" {
  type        = string
  description = "The env product host (cnf env.dns.fqdn). Every site host is a name under it, in the zone 025 holds."
}

variable "zone_name" {
  type        = string
  description = "The env's public Cloud DNS zone that serves fqdn (cnf steps.025-gcp-dns-zone.zone_name). This step only ADDS the records of its own hosts there; 025 keeps the zone and every other record."
}

# One entry per static site (cnf steps.021-firebase-hosted-sites.sites). A
# customer site is named by its private-overlay placeholder (ws-hidden-NN,
# csi-spl-doc/doc/md/private-overlay.md): the committed tfvars carry it, and
# do_tf_init resolves the host to the real name in the run dir. The site_id
# keeps the placeholder (a dash before it is not a token boundary), so no
# customer name becomes a global Firebase site id.
variable "sites" {
  type = list(object({
    name    = string # the placeholder (or a visible slug)
    site_id = string # <org>-<app>-<env>-<name>, GLOBAL across Firebase
    host    = string # <name>.<fqdn>
  }))
  description = "The static sites: one Firebase Hosting site, its custom domain and its DNS records each."
  default     = []

  validation {
    condition     = alltrue([for s in var.sites : can(regex("^[a-z0-9][a-z0-9-]{4,28}[a-z0-9]$", s.site_id))])
    error_message = "site_id must be a Firebase Hosting site id: 6-30 lowercase letters, digits or -, a letter or digit at each end."
  }

  validation {
    condition     = length(var.sites) == length(distinct([for s in var.sites : s.name]))
    error_message = "sites must not repeat a name."
  }
}

variable "cert_preference" {
  type        = string
  default     = "GROUPED"
  description = "GROUPED / PROJECT_GROUPED / DEDICATED."

  validation {
    condition     = contains(["GROUPED", "PROJECT_GROUPED", "DEDICATED"], var.cert_preference)
    error_message = "cert_preference must be GROUPED, PROJECT_GROUPED, or DEDICATED."
  }
}

variable "wait_dns_verification" {
  type        = bool
  default     = false
  description = "false: the apply does not wait for Firebase to verify the host and mint its certificate (it does so asynchronously once the records exist)."
}
