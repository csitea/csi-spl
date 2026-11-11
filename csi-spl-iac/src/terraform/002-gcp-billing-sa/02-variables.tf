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
  description = "Rendered from prd only: the billing SA lives in csi-spl-all (spec 123 section 15, the 059 pattern)."

  validation {
    condition     = var.env == "prd"
    error_message = "002-gcp-billing-sa renders from prd only (spec 123 section 15: one billing SA, in csi-spl-all)."
  }
}

variable "gcp_project" {
  type        = string
  description = "The billing SA's home and the project its query jobs run in: cnf env.cost.gcp.export_project (csi-spl-all)."
}

variable "gcp_region" {
  type        = string
  description = "The GCP region."
  default     = "europe-north1"
}

variable "billing_sa" {
  type        = string
  description = "The billing SA's account id: cnf env.cost.gcp.billing_sa (spl-billing)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.billing_sa))
    error_message = "billing_sa must be a service account id (6..30 chars, a-z 0-9 -)."
  }
}
