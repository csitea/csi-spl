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

# csi-rel's providers, with csi-spl's identity rule: no credentials path is
# baked in for this env (no-keys-in-tf gate; do_tf_init sets
# GOOGLE_APPLICATION_CREDENTIALS to the project key).
provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
  zone    = var.gcp_zone

  add_terraform_attribution_label = false
}

# The verification CNAMEs live in the prd project's apex zone (025). The
# prd-alias provider runs on the csi-spl-prd key so a dev run can still write
# there (same pattern as 025's "parent" provider); a prd run uses its own
# identity, the key file is not read.
provider "google" {
  alias   = "prd"
  project = var.parent_zone_project
  region  = var.gcp_region
  zone    = var.gcp_zone

  credentials = var.parent_zone_project != var.gcp_project ? file(pathexpand("~/.gcp/.${var.org}/key-${var.parent_zone_project}.json")) : null

  add_terraform_attribution_label = false
}
