terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # No remote backend: this step creates the state bucket every other step
  # stores its state in (chicken-and-egg). Its own state stays LOCAL, in the
  # run dir; keep the terraform.tfstate it writes out of git.
}

# No credentials path is baked in. The provider takes its identity from the
# caller: GOOGLE_APPLICATION_CREDENTIALS, GOOGLE_OAUTH_ACCESS_TOKEN or ADC.
provider "google" {
  project = var.gcp_project
  region  = var.gcp_region

  # No implicit goog-terraform-provisioned label: bnc-cpt-all-relay has no
  # labels, and the relay bucket copies it exactly.
  add_terraform_attribution_label = false
}
