# The blog's picture store (spec 111 Q4 (a), owner t1 d49b6b76): the
# generated pictures (do_spl_blog_image, T006) live here, never in git (G7),
# and the WUI deploy (wf 30) copies the ones a post names into the build.
#
# Hygiene = the 051 docs bucket's, deliberately:
#   uniform_bucket_level_access  true      -> IAM only, no object ACLs
#   public_access_prevention     enforced  -> no object can be made public;
#                                             the site serves its own copy
#   versioning                   off       -> a picture is regenerated, not
#                                             restored
#   soft delete                  7 days    -> a bad delete is recoverable
# No CORS and no public IAM: the browser never reads this bucket.
resource "google_storage_bucket" "media" {
  # checkov:skip=CKV_GCP_78: versioning off by design, as 051: a picture is regenerated, and the 7-day soft delete covers a bad delete
  # checkov:skip=CKV_GCP_62: no access-log bucket in this estate (as 050/051); private, PAP enforced, one reader, admin activity is in Cloud Audit Logs
  name     = var.media_bucket_name
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

  labels = {
    org  = var.org
    app  = var.app
    env  = var.env
    role = "blog-media"
  }
}
