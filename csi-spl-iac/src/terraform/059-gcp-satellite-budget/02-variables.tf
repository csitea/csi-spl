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
  description = "Rendered from prd only: the satellite lives in csi-spl-all (spec 057, owner 2026-10-01)."

  validation {
    condition     = var.env == "prd"
    error_message = "059-gcp-satellite-budget renders from prd only (spec 057: one satellite, in csi-spl-all)."
  }
}

variable "gcp_project" {
  type        = string
  description = "The satellite's project, csi-spl-all (steps.059.gcp_project)."
}

variable "gcp_region" {
  type        = string
  description = "The GCP region."
  default     = "europe-north1"
}

variable "billing_account_id" {
  type        = string
  description = "The billing account csi-spl-all is linked to. GCP_BILLING_ACCOUNT_ID at run time (make passes it as TF_VAR_billing_account_id), never cnf."

  validation {
    condition     = can(regex("^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$", var.billing_account_id))
    error_message = "billing_account_id must be set from GCP_BILLING_ACCOUNT_ID (XXXXXX-XXXXXX-XXXXXX)."
  }
}

variable "budget_display_name" {
  type        = string
  description = "The budget's name in the billing console."
}

variable "budget_amount_month" {
  type        = number
  description = "The monthly limit, in the billing account's own currency (owner: 170)."
}

variable "threshold_percents" {
  type        = list(number)
  description = "Alert thresholds as fractions of the amount (0.5 = 50%)."
}

variable "budget_label_key" {
  type        = string
  description = "Only resources carrying this label count (060 sets it on the VM and its data disk)."
}

variable "budget_label_value" {
  type        = string
  description = "The value of budget_label_key."
}
