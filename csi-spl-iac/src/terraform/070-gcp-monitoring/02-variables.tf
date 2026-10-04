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
  description = "The GCP region every resource of the spool lives in."
  default     = "europe-north1"
}

# The page goes to the owner directly, never through the fleet (availability
# plan 2.5.4: the fleet lease demotes when the hub is down). The address is
# NOT rendered into the tfvars (the hygiene sweep allows it only on its own
# cnf line): do_tf_init exports every string of the cnf env.gcp section as
# TF_VAR_<KEY UPPERCASED>, so this is cnf env.gcp.gcp_account_owner_email,
# set at run time.
variable "GCP_ACCOUNT_OWNER_EMAIL" {
  type        = string
  description = "The owner's address: cnf env.gcp.gcp_account_owner_email, exported by do_tf_init as TF_VAR_GCP_ACCOUNT_OWNER_EMAIL."

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[a-z]+$", var.GCP_ACCOUNT_OWNER_EMAIL))
    error_message = "GCP_ACCOUNT_OWNER_EMAIL must be set (run through do_tf_init, which exports it from cnf env.gcp.gcp_account_owner_email)."
  }
}

variable "hub_service_name" {
  type        = string
  description = "The hub's Cloud Run service (cnf hub.service_name, 030)."
}

variable "cloud_sql_instance_name" {
  type        = string
  description = "The hub's Cloud SQL instance (cnf steps.040-cloud-sql-postgres.instance_name)."
}

variable "uptime_host" {
  type        = string
  description = "The hub's public host the uptime check calls (cnf env.dns.api_fqdn, derived by do_spl_merged_cnf)."
}

variable "health_path" {
  type        = string
  description = "The public health path. /v1/health, not /healthz: Cloud Run's frontend answers some paths ending in z itself (404)."
}

variable "health_content" {
  type        = string
  description = "A substring the health body must contain for the check to pass."
}

variable "uptime_regions" {
  type        = list(string)
  description = "The uptime check's source regions (at least 3)."

  validation {
    condition     = length(var.uptime_regions) >= 3
    error_message = "uptime_regions needs at least 3 regions (Cloud Monitoring's minimum)."
  }
}

variable "uptime_period_seconds" {
  type        = number
  description = "How often each region calls the health URL: 60, 300, 600 or 900."
}

variable "uptime_timeout_seconds" {
  type        = number
  description = "The per-call timeout."
}

variable "uptime_failing_regions" {
  type        = number
  description = "Page when MORE than this many regions fail (1 = two regions agree, so one flaky probe never pages)."
}

variable "uptime_fail_seconds" {
  type        = number
  description = "How long the failure must last before it pages."
}

variable "rate_429_per_min" {
  type        = number
  description = "Page when the hub answers at least this many 429 in one minute."
}

variable "rate_5xx_per_5min" {
  type        = number
  description = "Page when the hub answers at least this many 5xx in five minutes."
}

variable "error_logs_per_5min" {
  type        = number
  description = "Page when the hub writes at least this many error log entries in five minutes."
}

variable "sql_down_seconds" {
  type        = number
  description = "Page when Cloud SQL database/up reads 0 for this long."
}

variable "auto_close_seconds" {
  type        = number
  description = "An open incident whose condition stays clear this long is closed."
}
