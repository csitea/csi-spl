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

# No credentials path is baked in (as 050): the csi-spl-all SA key (tf_key_project).
provider "google" {
  project = var.gcp_project
  region  = var.gcp_region

  add_terraform_attribution_label = false
}
