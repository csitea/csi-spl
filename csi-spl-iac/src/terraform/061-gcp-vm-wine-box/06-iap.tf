# Tester access for this instance. An empty iap_members list adds no binding
# and no custom role. The list is TF_VAR_iap_members at plan time, never a
# committed address. OS Login stays off (03-vm.tf); the desktop user logs in
# with a key from TF_VAR_desktop_user_ssh_public_keys.
resource "google_iap_tunnel_instance_iam_member" "wine" {
  for_each = toset(var.iap_members)
  project  = var.gcp_project
  zone     = var.gcp_zone
  instance = google_compute_instance.wine.name
  role     = "roles/iap.tunnelResourceAccessor"
  member   = each.value

  # VNC listens on 127.0.0.1 only. A tunnel to 5901 would hit the NIC and
  # miss it. The desktop is an SSH local forward over this port.
  condition {
    title       = "tcp-22-only"
    description = "IAP may open tcp/22 on this instance. The desktop port stays on localhost."
    expression  = "destination.port == 22"
  }
}

# start-iap-tunnel needs compute.instances.get and compute.instances.list.
# list is a permission on the parent, so it cannot be bound to one instance.
# This role is those two permissions and nothing else: it cannot change
# instance metadata, and it is not admin and not OS Login. It exists only while iap_members is non-empty.
resource "google_project_iam_custom_role" "tunnel_reader" {
  for_each    = length(var.iap_members) == 0 ? toset([]) : toset([var.gcp_project])
  project     = each.value
  role_id     = "wineBoxTunnelReader"
  title       = "Wine box tunnel reader"
  description = "Resolve the wine box for start-iap-tunnel. get and list only."
  permissions = [
    "compute.instances.get",
    "compute.instances.list",
  ]
}

resource "google_project_iam_member" "tunnel_reader" {
  for_each = toset(var.iap_members)
  project  = var.gcp_project
  role     = google_project_iam_custom_role.tunnel_reader[var.gcp_project].name
  member   = each.value
}
