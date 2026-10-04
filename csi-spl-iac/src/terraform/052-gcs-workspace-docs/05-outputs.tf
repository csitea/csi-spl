# workspace slug -> bucket name, the map the hub's resolver derives from
# bucket_prefix + the session's workspace.
output "workspace_docs_buckets" {
  value = { for w, b in google_storage_bucket.workspace_docs : w => b.name }
}
