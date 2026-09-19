variable "gcp_region" {
  type        = string
  description = "The GCP region."
}

variable "gcp_project" {
  type        = string
  description = "The GCP project."
}

variable "gcp_zone" {
  type        = string
  description = "The GCP zone."
}

variable "gcp_sa_email" {
  type        = string
  description = "The GCP service account email used for this env."
}
