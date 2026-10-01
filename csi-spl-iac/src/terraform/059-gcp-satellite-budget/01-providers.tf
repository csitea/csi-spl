terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  backend "gcs" {}
}

# No credentials path is baked in (as 050). The budget API is called with the
# csi-spl-all SA key, so the quota project must be named explicitly: without
# user_project_override + billing_project billingbudgets answers 403.
provider "google" {
  project               = var.gcp_project
  region                = var.gcp_region
  user_project_override = true
  billing_project       = var.gcp_project

  add_terraform_attribution_label = false
}
