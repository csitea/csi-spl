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

  # Same as 020: no implicit goog-terraform-provisioned label.
  add_terraform_attribution_label = false
}

# The parent zone's project, on THAT project's key, for extra-host records
# outside <fqdn> (see extra_dns_managed_zone). Unused when that is empty (prd).
provider "google" {
  alias   = "extra"
  project = var.extra_dns_zone_project != "" ? var.extra_dns_zone_project : var.gcp_project
  region  = var.gcp_region

  credentials = var.extra_dns_zone_project != "" && var.extra_dns_zone_project != var.gcp_project ? file(pathexpand("~/.gcp/.${var.org}/key-${var.extra_dns_zone_project}.json")) : null

  add_terraform_attribution_label = false
}
