terraform {
  required_version = ">= 1.7.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
  backend "gcs" {}
}

# csi-rel's provider, with csi-spl's identity rule: no credentials path is
# baked in (no-keys-in-tf gate). The tf-runner's do_tf_init points
# GOOGLE_APPLICATION_CREDENTIALS at this env's project key, the same key
# csi-rel's provider reads from ~/.gcp.
provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
  zone    = var.gcp_zone

  add_terraform_attribution_label = false
}
