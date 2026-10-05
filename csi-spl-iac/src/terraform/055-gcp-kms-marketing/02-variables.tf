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
  description = "The GCP region every resource of the spool lives in; the key ring's location."
  default     = "europe-north1"
}

variable "hub_runtime_sa_account_id" {
  type        = string
  description = "account_id of the hub's runtime service account (cnf hub.runtime_sa_account_id, created by 030): the ONLY member that encrypts and decrypts with the key."
}

variable "key_ring" {
  type        = string
  description = "The key ring name (cnf marketing.kms_key.key_ring). A key ring can never be deleted in GCP: renaming it leaves the old one behind."

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,63}$", var.key_ring))
    error_message = "key_ring must be 1-63 letters, digits, _ or -."
  }
}

variable "crypto_key" {
  type        = string
  description = "The symmetric key name (cnf marketing.kms_key.crypto_key) that seals the marketing channel tokens (spec 090 FR-002)."

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,63}$", var.crypto_key))
    error_message = "crypto_key must be 1-63 letters, digits, _ or -."
  }
}

variable "rotation_period" {
  type        = string
  description = "The key's automatic rotation period in seconds with an s suffix (cnf marketing.kms_key.rotation_period; 7776000s = 90 days)."
  # the default lets checkov (wf 65, CKV_GCP_43) see a <= 90-day rotation;
  # the tfvars from cnf still set it
  default = "7776000s"

  validation {
    # GCP: at least one day; spec 090 T002: at most 90 days
    condition     = can(regex("^[0-9]+s$", var.rotation_period)) && tonumber(trimsuffix(var.rotation_period, "s")) >= 86400 && tonumber(trimsuffix(var.rotation_period, "s")) <= 7776000
    error_message = "rotation_period must be <seconds>s, between 86400s (1 day) and 7776000s (90 days)."
  }
}

variable "kms_check_sa_account_id" {
  type        = string
  description = "account_id of the env's project SA (<org>-<app>-<env>, the key ~/.gcp/.<org>/key-<org>-<app>-<env>.json). It may mint a token for the hub runtime SA, so do_spl_kms_check can prove the key AS that SA."
}
