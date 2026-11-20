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
  description = "The renderer's Cloud Run service, <org>-<app>-<env>-pdf (spec 183 7.1.6)."
}

variable "runtime_sa_account_id" {
  type        = string
  description = "account_id of the renderer's runtime service account. It holds no role at all: the renderer reads nothing and calls nothing."
}

variable "hub_runtime_sa_account_id" {
  type        = string
  description = "account_id of the hub's runtime service account (cnf hub.runtime_sa_account_id, 030 03-runtime-sa.tf): the ONLY run.invoker of the renderer."
}

# The renderer image, <region>-docker.pkg.dev/<project>/<028 repository>/<pdf.image.name>:<pdf.image.tag>.
# Its tag is the src-<12 hex> do_build_push_pdf_image (csi-spl-orc) pushed:
# a hash of the renderer's inputs, so an unchanged renderer keeps its image.
variable "image" {
  type        = string
  description = "The image the renderer runs (cnf pdf.image.*); terraform owns it: a new renderer is a new cnf pdf.image.tag + apply."

  validation {
    condition     = can(regex("^[a-z0-9.-]+-docker\\.pkg\\.dev/[^/]+/[^/]+/[^/:]+:src-[0-9a-f]{12}$", var.image))
    error_message = "image must be <region>-docker.pkg.dev/<project>/<repo>/<name>:src-<12 hex>: set cnf pdf.image.tag to the tag do_build_push_pdf_image pushed, then re-render (do_tpl_gen)."
  }
}

variable "cpu" {
  type        = string
  description = "CPU limit (cnf pdf.cloud_run.cpu)."
}

variable "memory" {
  type        = string
  description = "Memory limit (cnf pdf.cloud_run.memory): Chrome peaks near 190 MiB per render (spec 183 1.1)."
}

variable "max_instances" {
  type        = number
  description = "Maximum instances (cnf pdf.cloud_run.max_instances). The minimum is 0 and is not a variable (spec 183 1.2 R1)."

  validation {
    condition     = var.max_instances >= 1
    error_message = "max_instances must be at least 1."
  }
}

variable "concurrency" {
  type        = number
  description = "Requests per instance (cnf pdf.cloud_run.concurrency): 1, one Chrome render at a time (spec 183 7.1.6)."

  validation {
    condition     = var.concurrency == 1
    error_message = "concurrency must be 1: the renderer runs one Chrome at a time and answers 429 to a second request."
  }
}

variable "timeout_seconds" {
  type        = number
  description = "Request timeout (cnf pdf.cloud_run.timeout_seconds): a cold start plus a render (spec 183 1.2 R2)."

  validation {
    condition     = var.timeout_seconds >= 1 && var.timeout_seconds <= 3600
    error_message = "timeout_seconds must be 1..3600."
  }
}

variable "deletion_protection" {
  type        = bool
  description = "google_cloud_run_v2_service.deletion_protection (cnf pdf.cloud_run.deletion_protection): true, flipped false through cnf only for a destroy run (owner, 2026-09-19)."
}
