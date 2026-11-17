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

# 03-sa.tf: the billing export dataset lives in its own project
# (env.cost.gcp.export_source_project, csi-spl-prd), where the csi-spl-all SA
# has no role. This alias runs as THAT project's SA, from its per-env key
# (owner HUM-10, #laskut f655b326, msg 303bd484: "Second provider in terraform
# step 002, running as the csi-spl-prd service account"); the same pattern as
# 025's "parent" provider. When the export sits in this step's own project the
# key file is not read.
provider "google" {
  alias   = "export_source"
  project = var.export_source_project
  region  = var.gcp_region

  credentials = var.export_source_project != var.gcp_project ? file(pathexpand("~/.gcp/.${var.org}/key-${var.export_source_project}.json")) : null

  add_terraform_attribution_label = false
}
