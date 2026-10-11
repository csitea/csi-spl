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
  description = "The GCP project id: cnf env.gcp.gcp_project (by default <org>-<app>-<env>)."
}

variable "gcp_region" {
  type        = string
  description = "The GCP region every resource of the spool lives in; the key ring's location and the pepper's one replica."
  default     = "europe-north1"
}

variable "hub_runtime_sa_account_id" {
  type        = string
  description = "account_id of the hub's runtime service account (cnf hub.runtime_sa_account_id, created by 030): the ONLY member that wraps and unwraps with the key and reads the pepper."
}

variable "key_ring" {
  type        = string
  description = "The key ring name (cnf vendor_keys.kms_key.key_ring). A key ring can never be deleted in GCP: renaming it leaves the old one behind."

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,63}$", var.key_ring))
    error_message = "key_ring must be 1-63 letters, digits, _ or -."
  }
}

variable "crypto_key" {
  type        = string
  description = "The symmetric key name (cnf vendor_keys.kms_key.crypto_key) that wraps each workspace vendor key's DEK (spec 127 section 4.2)."

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,63}$", var.crypto_key))
    error_message = "crypto_key must be 1-63 letters, digits, _ or -."
  }
}

variable "rotation_period" {
  type        = string
  description = "The key's automatic rotation period in seconds with an s suffix (cnf vendor_keys.kms_key.rotation_period; 7776000s = 90 days)."
  # the default lets checkov (wf 65, CKV_GCP_43) see a <= 90-day rotation;
  # the tfvars from cnf still set it
  default = "7776000s"

  validation {
    condition     = can(regex("^[0-9]+s$", var.rotation_period)) && tonumber(trimsuffix(var.rotation_period, "s")) >= 86400 && tonumber(trimsuffix(var.rotation_period, "s")) <= 7776000
    error_message = "rotation_period must be <seconds>s, between 86400s (1 day) and 7776000s (90 days)."
  }
}

variable "pepper_secret_id" {
  type        = string
  description = "The Secret Manager secret id of the HMAC pepper (cnf vendor_keys.pepper_secret). Terraform creates the EMPTY slot; do_spl_vendor_key_pepper_put adds the value out of band."

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,255}$", var.pepper_secret_id))
    error_message = "pepper_secret_id must be 1-255 letters, digits, _ or -."
  }
}
