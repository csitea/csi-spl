terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

# Customer package: no remote backend. The placeholder SOLUTION_URN is
# replaced from Producer Portal after the product exists. It is not a live URN.
provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    goog-partner-solution = var.partner_solution_urn
  }

  add_terraform_attribution_label = false
}
