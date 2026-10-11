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
  description = "Dev only: the wine-box test VM lives in the dev project."

  validation {
    condition     = var.env == "dev"
    error_message = "058-gcp-wine-box-budget is dev only. The prd render carries the dev-only marker and is not applied."
  }
}

variable "gcp_project" {
  type        = string
  description = "The project the labelled resources are billed in."
}

variable "gcp_region" {
  type        = string
  description = "The GCP region. Unused by the budget resource; set so the provider matches the VM."
}

variable "billing_account_id" {
  type        = string
  sensitive   = true
  description = "The billing account the project is linked to. GCP_BILLING_ACCOUNT_ID at run time (make passes it as TF_VAR_billing_account_id), never cnf."

  validation {
    condition     = can(regex("^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$", var.billing_account_id))
    error_message = "billing_account_id must be set from GCP_BILLING_ACCOUNT_ID (XXXXXX-XXXXXX-XXXXXX)."
  }
}

variable "budget_api" {
  type        = string
  description = "The API this step enables before it creates the budget."
}

variable "budget_display_name" {
  type        = string
  description = "The budget's name in the billing console."
}

variable "budget_amount_month" {
  type        = number
  description = "The monthly limit, in the billing account's own currency."
}

variable "threshold_percents" {
  type        = list(number)
  description = "Alert thresholds as fractions of the amount (0.5 = 50%)."
}

variable "budget_label_key" {
  type        = string
  description = "Only resources carrying this label count (061 sets it on the VM and its disks)."
}

variable "budget_label_value" {
  type        = string
  description = "The value of budget_label_key. Must match the VM's box label."
}
