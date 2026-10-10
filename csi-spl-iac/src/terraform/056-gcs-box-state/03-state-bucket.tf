# The boxes' nightly state copy (owner t1 d80ed72c, "A" to B1 m/bb71c466):
# one tar.zst per box per night (do_spl_box_state_backup): agent transcripts
# and memory, the spool root, the csi-spl state dirs. Keys, tokens and the
# tenants store never go in (the action excludes them and scans the archive).
# A new box restores from here (do_spl_box_state_restore).
#
#   uniform_bucket_level_access  true      -> IAM only, no object ACLs
#   public_access_prevention     enforced  -> no object can be made public
#   encryption                   Google-managed. The one KMS ring (055) is
#                                the marketing lane's; a CMEK here would add a
#                                key a restore on a new box depends on
#   versioning                   off       -> a night is a new object name
#   lifecycle                    delete at retention_days (30)
#   soft delete                  7 days    -> a bad delete is recoverable
resource "google_storage_bucket" "state" {
  # checkov:skip=CKV_GCP_78: versioning off by design: each night is a new object name, and nothing may overwrite (writer is objectCreator only)
  # checkov:skip=CKV_GCP_62: no access-log bucket in this estate (as 050/051/054); private, PAP enforced, admin activity is in Cloud Audit Logs
  name     = var.state_bucket_name
  project  = var.gcp_project
  location = upper(var.gcp_region)

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = false
  }

  soft_delete_policy {
    retention_duration_seconds = var.soft_delete_retention_seconds
  }

  lifecycle_rule {
    condition {
      age = var.retention_days
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    org  = var.org
    app  = var.app
    env  = var.env
    role = "box-state"
  }
}
