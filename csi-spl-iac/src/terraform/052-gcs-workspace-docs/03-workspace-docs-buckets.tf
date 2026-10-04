# spec 075 phase 2: ONE docs bucket per workspace (owner, prd t1 9f0d751c,
# msg 2dbabe95: "yes , new terraform step , for each workspace separate
# bucket"). Workspace-authored markdown, its tree.json and its edit history,
# read and written by the hub only (session-checked, per workspace). Repo docs
# stay in 051's single bucket; file uploads stay in 050's.
#
# Hygiene = 051's, except versioning:
#   uniform_bucket_level_access  true      -> IAM only, no object ACLs
#   public_access_prevention     enforced  -> no object can be made public;
#                                             the hub's session door is the
#                                             only way in
#   versioning                   on        -> unlike the repo docs these have
#                                             no git: an overwrite or delete
#                                             keeps the old generation
#   soft delete                  7 days    -> a deleted bucket object is
#                                             recoverable
# No CORS: the browser reads the docs through the hub, never the bucket.
resource "google_storage_bucket" "workspace_docs" {
  for_each = toset(var.workspaces)

  name     = "${var.bucket_prefix}${each.key}"
  project  = var.gcp_project
  location = upper(var.gcp_region)

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = var.soft_delete_retention_seconds
  }

  labels = {
    org       = var.org
    app       = var.app
    env       = var.env
    role      = "workspace-docs"
    workspace = each.key
  }
}
