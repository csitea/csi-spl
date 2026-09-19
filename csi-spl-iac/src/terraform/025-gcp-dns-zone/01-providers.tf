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

# No credentials path is baked in. The provider takes its identity from the
# caller: GOOGLE_APPLICATION_CREDENTIALS, GOOGLE_OAUTH_ACCESS_TOKEN or ADC.
provider "google" {
  project = var.gcp_project
  region  = var.gcp_region

  # Same as 020: no implicit goog-terraform-provisioned label.
  add_terraform_attribution_label = false
}

# The parent (apex) zone's project, on THAT project's key: the delegation NS
# record for a subzone is written there (csi-rel 007-dns: provider google.prd).
# Unused when parent_zone_project is empty (prd).
provider "google" {
  alias   = "parent"
  project = var.parent_zone_project != "" ? var.parent_zone_project : var.gcp_project
  region  = var.gcp_region

  credentials = var.parent_zone_project != "" && var.parent_zone_project != var.gcp_project ? file(pathexpand("~/.gcp/.${var.org}/key-${var.parent_zone_project}.json")) : null

  add_terraform_attribution_label = false
}
