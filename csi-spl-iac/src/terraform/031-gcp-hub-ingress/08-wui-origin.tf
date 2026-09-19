# Spec 007 §3 (T072, decided): the WUI's static files live on Firebase
# Hosting (019), and this load balancer is the ONE front door for the env's
# names. A global internet NEG points at <site_id>.web.app:443; the URL map's
# "wui" path matcher sends every non-hub path there with the Host rewritten
# to that site. Why not Firebase Hosting rewrites to Cloud Run instead: they
# carry no WebSocket (/v1/ws, /v1/wui/ws), cannot pass the tenant Host the hub
# routes on, cannot serve the wildcard *.<fqdn> (not a Hosting custom domain),
# and need 030's ingress opened past this LB and its Cloud Armor policy.
#
# No Cloud Armor policy on this backend: the WUI is public static files, the
# same bytes <site_id>.web.app serves to anyone.
locals {
  wui = var.wui_origin_host != ""
}

resource "google_compute_global_network_endpoint_group" "wui" {
  count = local.wui ? 1 : 0

  name                  = "${local.name_prefix}-wui-neg"
  project               = var.gcp_project
  network_endpoint_type = "INTERNET_FQDN_PORT"
  default_port          = 443
}

resource "google_compute_global_network_endpoint" "wui" {
  count = local.wui ? 1 : 0

  project                       = var.gcp_project
  global_network_endpoint_group = google_compute_global_network_endpoint_group.wui[0].name
  fqdn                          = var.wui_origin_host
  port                          = 443
}

resource "google_compute_backend_service" "wui" {
  count = local.wui ? 1 : 0

  name                  = "${local.name_prefix}-wui-backend"
  project               = var.gcp_project
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTPS"

  backend {
    group = google_compute_global_network_endpoint_group.wui[0].id
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}
