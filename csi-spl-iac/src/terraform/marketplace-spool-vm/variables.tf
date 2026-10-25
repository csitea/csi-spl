variable "project_id" {
  type        = string
  description = "GCP project that owns this VM. Must not be an estate project."

  validation {
    condition     = var.project_id != "csi-spl-dev" && var.project_id != "csi-spl-prd"
    error_message = "project_id must not be csi-spl-dev or csi-spl-prd."
  }
}

variable "region" {
  type        = string
  description = "Region for the subnet."
  default     = "europe-north1"
}

variable "zone" {
  type        = string
  description = "Zone for the VM."
  default     = "europe-north1-a"
}

variable "machine_type" {
  type        = string
  description = "Machine type. Primary size is e2-standard-2."
  default     = "e2-standard-2"
}

variable "boot_disk_image" {
  type        = string
  description = "Public Debian family used as the boot disk. A producer image is not published yet."
  default     = "projects/debian-cloud/global/images/family/debian-12"
}

variable "boot_disk_size_gb" {
  type        = number
  description = "Boot disk size in GB."
  default     = 50
}

variable "boot_disk_type" {
  type        = string
  description = "Boot disk type."
  default     = "pd-balanced"
}

variable "spool_hub_image" {
  type        = string
  description = "Pinned Spool Hub image. Do not replace the digest."
  default     = "ghcr.io/csitea/spool-hub:stable-2026-10-12@sha256:ccdee0eb22cdfa6d0f5380dfd4f5f9df4c90634bf0c6f01fc2bf200a0d5347e6"
}

variable "spool_web_image" {
  type        = string
  description = "Pinned Spool web image copied from the repo compose file."
  default     = "ghcr.io/csitea/spool-web:stable-2026-10-12@sha256:8e4f3016c34f2fd0883bb6b7cbac54fb99ae0b55666753a41d7a5f9442ab9259"
}

variable "spool_pg_image" {
  type        = string
  description = "Postgres image copied from the repo compose file."
  default     = "postgres:16-alpine"
}

variable "spool_s3_image" {
  type        = string
  description = "SeaweedFS image copied from the repo compose file."
  default     = "chrislusf/seaweedfs:4.48"
}

variable "partner_solution_urn" {
  type        = string
  description = "Partner solution id. SOLUTION_URN is the placeholder until Producer Portal assigns one."
  default     = "SOLUTION_URN"
}

variable "goog_cm_deployment_name" {
  type        = string
  description = "Deployment name. Used as the VM name."

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$", var.goog_cm_deployment_name))
    error_message = "goog_cm_deployment_name must be 1 to 63 characters, start with a letter, and then use only lowercase letters, digits, and hyphens."
  }
}
