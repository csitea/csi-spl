terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    # 03-sa.tf: writes the billing SA's key on the applying box (owner 8d767855)
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  backend "gcs" {}
}

# No credentials path is baked in: do_tf_init sets GOOGLE_APPLICATION_CREDENTIALS
# to the key of steps.002-gcp-billing-sa.tf_key_project (the csi-spl-all SA).
provider "google" {
  project = var.gcp_project
  region  = var.gcp_region

  add_terraform_attribution_label = false
}
