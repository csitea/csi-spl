terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # This step creates the state bucket every step stores its state in,
  # including this one (prefix terraform/000-gcp-remote-bucket). Chicken and
  # egg: the FIRST apply runs with TF_BACKEND=local (do_tf_plan writes a local
  # backend override), then the local state is migrated into the bucket it
  # created -- csi-spl-doc section 6.2.4. Until then the run dir holds the ONLY
  # copy of this state, and do_tf_plan refuses to wipe a run dir holding one.
  backend "gcs" {}
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
