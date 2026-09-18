# M1 hub ingress (owner 2026-09-18): NOT the open internet. Cloud Run cannot
# filter source IPs, so 030 takes load-balancer traffic only
# (internal-and-cloud-load-balancing) and THIS policy, on the load balancer's
# backend, is the allowlist: the listed CIDRs are allowed, everything else is
# 403. M1 is an IP allowlist, not per-agent IAM; the box still proves itself
# with its Ed25519 key on the WS hello (OQ-06). M2 may drop the allowlist.
locals {
  name_prefix = "${var.org}-${var.app}-${var.env}-hub"

  # Cloud Armor takes at most 10 source ranges per basic rule.
  allow_chunks = chunklist(var.allowed_ip_ranges, 10)
}

resource "google_compute_security_policy" "hub" {
  name        = "${local.name_prefix}-allowlist"
  project     = var.gcp_project
  description = "M1: only the allowlisted CIDRs reach ${var.service_name}; everything else 403"
  type        = "CLOUD_ARMOR"

  dynamic "rule" {
    for_each = local.allow_chunks
    content {
      action      = "allow"
      priority    = 1000 + rule.key
      description = "M1 allowlist, part ${rule.key + 1} of ${length(local.allow_chunks)}"
      match {
        versioned_expr = "SRC_IPS_V1"
        config {
          src_ip_ranges = rule.value
        }
      }
    }
  }

  # The default rule, which every policy must have: deny.
  rule {
    action      = "deny(403)"
    priority    = 2147483647
    description = "default: deny everyone not on the allowlist"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}
