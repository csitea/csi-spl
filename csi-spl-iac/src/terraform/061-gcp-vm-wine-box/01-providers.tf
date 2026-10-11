terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    # 07-ansible.tf: the inventory and the run-ansible script
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  backend "gcs" {}
}

# No credentials path is baked in. do_tf_init points the dev project SA key
# at this step (tf_key_project).
provider "google" {
  project = var.gcp_project
  region  = var.gcp_region

  add_terraform_attribution_label = false
}
