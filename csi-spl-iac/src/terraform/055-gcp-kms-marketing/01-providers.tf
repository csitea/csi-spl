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

  # Same as 020/051/052: no implicit goog-terraform-provisioned label.
  add_terraform_attribution_label = false
}
