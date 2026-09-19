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

variable "service_name" {
  type        = string
  description = "The Cloud Run service, csi-spl-hub-<env> (cnf hub.service_name)."
}

variable "runtime_sa_account_id" {
  type        = string
  description = "account_id of the hub's runtime service account (cnf hub.runtime_sa_account_id)."
}

variable "image" {
  type        = string
  description = "The image the service runs: cnf hub.image.ref, <region>-docker.pkg.dev/<project>/<028 repository>/<name>:<tag>. Terraform owns it; a deploy is a new tag + apply."
}

variable "container_port" {
  type        = number
  description = "The port the hub listens on inside the container (cnf hub.cloud_run.port); Cloud Run passes it as $PORT."
  default     = 8080
}

variable "cpu" {
  type        = string
  description = "CPU limit (cnf hub.cloud_run.cpu)."
  default     = "1"
}

variable "memory" {
  type        = string
  description = "Memory limit (cnf hub.cloud_run.memory)."
  default     = "512Mi"
}

variable "min_instances" {
  type        = number
  description = "Minimum instances; milestones M1: 1 (cnf hub.cloud_run.min_instances)."
  default     = 1
}

variable "max_instances" {
  type        = number
  description = "Maximum instances; OQ-05: 1 in M1, so every box WS lands on one instance (cnf hub.cloud_run.max_instances)."
  default     = 1

  validation {
    condition     = var.max_instances >= 1
    error_message = "max_instances must be at least 1."
  }
}

variable "concurrency" {
  type        = number
  description = "Requests (each WS is one) per instance (cnf hub.cloud_run.concurrency)."
  default     = 1000
}

variable "timeout_seconds" {
  type        = number
  description = "Request timeout = the longest a WS lives before the box reconnects (Cloud Run max 3600)."
  default     = 3600

  validation {
    condition     = var.timeout_seconds >= 1 && var.timeout_seconds <= 3600
    error_message = "timeout_seconds must be 1..3600."
  }
}

variable "health_path" {
  type        = string
  description = "Startup + liveness probe path."
  default     = "/healthz"
}

variable "ingress" {
  type        = string
  description = "Who may reach the service at all (cnf hub.cloud_run.ingress). all since owner 2026-09-19 (csi-rel: Cloud Run domain mappings, no load balancer); internal-and-cloud-load-balancing was the M1 LB-only shape."

  validation {
    condition     = contains(["all", "internal", "internal-and-cloud-load-balancing"], var.ingress)
    error_message = "ingress must be all, internal or internal-and-cloud-load-balancing."
  }
}

variable "allow_unauthenticated" {
  type        = bool
  description = "Grant allUsers run.invoker. Boxes authenticate with their Ed25519 key on WS hello, not GCP IAM (OQ-06)."
  default     = true
}

variable "environment_variables" {
  type        = map(string)
  description = "The hub's runtime env, rendered from cnf hub.env (the published SPOOL_HUB_* names). Never a secret."
  default     = {}
}

variable "secret_environment_variables" {
  type        = map(string)
  description = "env var -> Secret Manager secret id (cnf hub.secret_env); injected at version latest."
  default     = {}
}

variable "cloud_sql_instance_name" {
  type        = string
  description = "The 040 instance (cnf steps.040-cloud-sql-postgres.instance_name), mounted at /cloudsql."
}

variable "files_bucket_name" {
  type        = string
  description = "The 050 bucket (cnf steps.050-gcs-files.files_bucket_name); the runtime SA gets objectUser on it."
}

variable "auth_secret_ids" {
  type        = list(string)
  description = "Secret Manager ids of the sign-in + mail secrets (cnf env.auth.social.secret_env + env.mail.secret_env values). 030 creates each as an empty slot; versions are added out of band."
  default     = []
}

variable "deletion_protection" {
  type        = bool
  description = "google_cloud_run_v2_service.deletion_protection (cnf hub.cloud_run.deletion_protection). true in the committed config; flipped false through cnf ONLY for a destroy run, then back to true (owner, 2026-09-19)."
  default     = true
}
