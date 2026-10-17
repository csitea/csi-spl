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

# No credentials path is baked in. The provider takes its identity from the
# caller: GOOGLE_APPLICATION_CREDENTIALS, GOOGLE_OAUTH_ACCESS_TOKEN or ADC.
provider "google" {
  project = var.gcp_project
  region  = var.gcp_region

  # No implicit goog-terraform-provisioned label: keep the buckets label-free
  # so a copied bucket matches its source exactly.
  add_terraform_attribution_label = false
}
