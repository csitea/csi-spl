# Global external Application Load Balancer -> serverless NEG -> the 030 Cloud
# Run hub. HTTPS only: boxes are configured with https://<tenant>.<fqdn>, so no
# port-80 redirect rule is created (one forwarding rule, not two).
#
# WebSocket (/v1/ws) passes through the ALB natively. The backend service
# carries no timeout_sec: a serverless NEG backend refuses one, and the socket
# lifetime is 030's Cloud Run request timeout (3600 s).
resource "google_compute_global_address" "hub" {
  name       = "${local.name_prefix}-ip"
  project    = var.gcp_project
  ip_version = "IPV4"
}

resource "google_compute_region_network_endpoint_group" "hub" {
  name                  = "${local.name_prefix}-neg"
  project               = var.gcp_project
  region                = var.gcp_region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = var.service_name
  }
}

resource "google_compute_backend_service" "hub" {
  name                  = "${local.name_prefix}-backend"
  project               = var.gcp_project
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTPS"
  security_policy       = google_compute_security_policy.hub.id

  backend {
    group = google_compute_region_network_endpoint_group.hub.id
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_url_map" "hub" {
  name            = "${local.name_prefix}-urlmap"
  project         = var.gcp_project
  default_service = google_compute_backend_service.hub.id

  # Spec 007 §3 (T072): with wui_origin_host set, the env's own names serve
  # the WUI at every path except hub_paths. Extra hosts (api., dev.api.) keep
  # the default: every path is the hub.
  dynamic "host_rule" {
    for_each = local.wui ? [1] : []
    content {
      hosts        = [var.fqdn, "*.${var.fqdn}"]
      path_matcher = "wui"
    }
  }

  dynamic "path_matcher" {
    for_each = local.wui ? [1] : []
    content {
      name            = "wui"
      default_service = google_compute_backend_service.wui[0].id

      # Firebase Hosting picks the site by Host: send it the site's own name.
      default_route_action {
        url_rewrite {
          host_rewrite = var.wui_origin_host
        }
      }

      path_rule {
        paths   = var.hub_paths
        service = google_compute_backend_service.hub.id
      }
    }
  }
}

resource "google_compute_ssl_policy" "hub" {
  name            = "${local.name_prefix}-tls"
  project         = var.gcp_project
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"
}

resource "google_compute_target_https_proxy" "hub" {
  name            = "${local.name_prefix}-https"
  project         = var.gcp_project
  url_map         = google_compute_url_map.hub.id
  certificate_map = "//certificatemanager.googleapis.com/${google_certificate_manager_certificate_map.hub.id}"
  ssl_policy      = google_compute_ssl_policy.hub.id

  depends_on = [google_certificate_manager_certificate_map_entry.hub]
}

resource "google_compute_global_forwarding_rule" "hub" {
  name                  = "${local.name_prefix}-https"
  project               = var.gcp_project
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_protocol           = "TCP"
  port_range            = "443"
  ip_address            = google_compute_global_address.hub.id
  target                = google_compute_target_https_proxy.hub.id

  labels = {
    org  = var.org
    app  = var.app
    env  = var.env
    role = "hub-ingress"
  }
}
