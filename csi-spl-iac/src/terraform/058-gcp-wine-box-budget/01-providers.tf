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

# The dev project SA (tf_key_project). The budget API needs the quota project
# named, or billingbudgets answers 403 (the 059 provider shape).
provider "google" {
  project               = var.gcp_project
  region                = var.gcp_region
  user_project_override = true
  billing_project       = var.gcp_project

  add_terraform_attribution_label = false
}
