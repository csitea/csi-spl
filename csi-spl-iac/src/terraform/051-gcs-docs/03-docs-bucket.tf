# The Docs section's bucket (owner, prd t1 9f0d751c): "the md docs rendered
# from the s3 where it will be hosted - not from the github". Every repo .md
# at its repo path plus tree.json, mirrored at each WUI deploy by
# do_publish_docs (csi-spl-orc) as the env's project SA; the hub reads them
# for signed-in members (GET /v1/docs/<repo path>).
#
# Hygiene = the 050 files bucket's, deliberately:
#   uniform_bucket_level_access  true      -> IAM only, no object ACLs
#   public_access_prevention     enforced  -> no object can be made public;
#                                             the hub's session door is the
#                                             only way in
#   versioning                   off       -> the repo's history is git's
#   soft delete                  7 days    -> a bad mirror is recoverable
# No CORS: the browser reads the docs through the hub, never the bucket.
resource "google_storage_bucket" "docs" {
  name     = var.docs_bucket_name
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
    role = "docs"
  }
}
