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

# The provider works in the BACKUP project, not in csi-spl-<env>: this step is
# rendered and run per env (ENV=dev|prd, the usual tf-runner path) but its
# identity is the backup project's own SA. do_tf_init reads the step's
# tf_key_project and points GOOGLE_APPLICATION_CREDENTIALS at
# ~/.gcp/.<org>/key-<tf_key_project>.json, so the env's key never reaches a
# resource here beyond the one grant below.
provider "google" {
  project = var.tf_key_project
  region  = var.gcp_region

  add_terraform_attribution_label = false
}
