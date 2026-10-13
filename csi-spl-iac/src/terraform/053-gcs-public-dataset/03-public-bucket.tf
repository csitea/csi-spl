# The PUBLIC dataset bucket (spec 091 section 6, owner msg 356619c8: "a
# separate, entirely public bucket"). It holds the published SQL downloads of
# the clean workspace export, their manifests and verdicts, and latest.json;
# nothing else. Never a full backup: do_spl_db_backup refuses a public target.
#
#   uniform_bucket_level_access  true      -> IAM only, no object ACLs
#   public_access_prevention     inherited -> allUsers objectViewer below is
#                                             the ONE public grant
#   versioning                   off       -> names are dated, a published
#                                             file never changes
#   lifecycle                    daily/ at daily_retention_days,
#                                stable/ at stable_retention_days (cnf)
#   soft delete                  7 days    -> a bad delete is recoverable
resource "google_storage_bucket" "public" {
  # checkov:skip=CKV_GCP_28: public read is the purpose of this bucket (spec 091 section 6); it carries only the gated, three-times verified export
  # checkov:skip=CKV_GCP_114: public access prevention must be "inherited" for the allUsers objectViewer grant
  # checkov:skip=CKV_GCP_78: versioning off by design: names are dated, the publish SA cannot overwrite but latest.json
  # checkov:skip=CKV_GCP_62: no access-log bucket in this estate (as 050/051/054/056); admin activity is in Cloud Audit Logs
  name     = var.public_bucket_name
  project  = var.gcp_project
  location = upper(var.gcp_region)

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "inherited"
  force_destroy               = false

  versioning {
    enabled = false
  }

  soft_delete_policy {
    retention_duration_seconds = local.soft_delete_retention_seconds
  }

  lifecycle_rule {
    condition {
      age            = var.daily_retention_days
      matches_prefix = [local.daily_prefix]
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age            = var.stable_retention_days
      matches_prefix = ["stable/"]
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    org  = var.org
    app  = var.app
    env  = var.env
    role = "public-dataset"
  }
}

resource "google_storage_bucket_iam_member" "public_all_users_object_viewer" {
  # checkov:skip=CKV_GCP_28: the one public grant: anonymous read of the published dataset (spec 091 section 6)
  bucket = google_storage_bucket.public.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}
