# Cloud Run domain mappings.
#
# Cert state (spec[0].certificate_mode, force_override) is left to Google's
# managed-cert flow and ignored by terraform so `apply` returns immediately;
# csi-spl-orc's `./run -a do_wait_for_cert` polls until the cert is ACTIVE.

locals {
  default_labels = {
    org        = var.org
    app        = var.app
    env        = var.env
    managed_by = "terraform"
    step       = var.STEP
  }
}

resource "google_cloud_run_domain_mapping" "primary" {
  count    = var.cloud_run_custom_domain != "" ? 1 : 0
  location = var.gcp_region
  name     = var.cloud_run_custom_domain

  metadata {
    namespace = var.gcp_project
    labels    = local.default_labels
  }

  spec {
    route_name = var.cloud_run_service_name
  }

  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
      metadata[0].labels,
      metadata[0].effective_labels,
      metadata[0].terraform_labels,
      spec[0].certificate_mode,
      spec[0].force_override,
    ]
  }
}

resource "google_cloud_run_domain_mapping" "additional" {
  for_each = toset(var.cloud_run_additional_domains)
  location = var.gcp_region
  name     = each.value

  metadata {
    namespace = var.gcp_project
    labels    = local.default_labels
  }

  spec {
    route_name = var.cloud_run_service_name
  }

  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
      metadata[0].labels,
      metadata[0].effective_labels,
      metadata[0].terraform_labels,
      spec[0].certificate_mode,
      spec[0].force_override,
    ]
  }
}
