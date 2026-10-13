# The PRIVATE staging bucket (spec 091 section 6): the day's candidate, its
# name lists and the three verifier lanes' verdicts. Private like 054/056.
#
#   uniform_bucket_level_access  true      -> IAM only, no object ACLs
#   public_access_prevention     enforced  -> no object can be made public
#   versioning                   off       -> a candidate is re-exported
#   lifecycle                    delete at the first whole day past
#                                candidate_ttl_hours (cnf): a stale
#                                candidate and its name lists go
#   soft delete                  7 days    -> a bad delete is recoverable
resource "google_storage_bucket" "staging" {
  # checkov:skip=CKV_GCP_78: versioning off by design: a candidate is re-exported, never restored
  # checkov:skip=CKV_GCP_62: no access-log bucket in this estate (as 050/051/054/056); private, PAP enforced, admin activity is in Cloud Audit Logs
  name     = var.staging_bucket_name
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
    retention_duration_seconds = local.soft_delete_retention_seconds
  }

  lifecycle_rule {
    condition {
      age = ceil(var.candidate_ttl_hours / 24) + 1
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    org  = var.org
    app  = var.app
    env  = var.env
    role = "public-dataset-staging"
  }
}
