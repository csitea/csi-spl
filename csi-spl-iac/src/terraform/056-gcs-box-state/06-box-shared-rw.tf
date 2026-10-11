# The RW mount (owner t1 151d85fc msg ec950b4b; do_spl_box_state_mount, the
# mount lane c-857): the writer may read, write and delete ONLY under
# <shared_prefix>/. Its unconditioned objectCreator stays as it is; an
# overwrite needs delete, which it has nowhere else, so every backup object
# (<box>/<date>/...) stays immutable to the boxes. The folders clause covers
# gcsfuse's folder calls; the list clause lets it list <shared_prefix>/ only.
resource "google_storage_bucket_iam_member" "writer_shared_rw" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.writer.email}"
  condition {
    title       = "box-state-${var.shared_prefix}-only"
    description = "RW mount: ${var.shared_prefix}/ only; the nightly backups stay immutable"
    expression = join(" || ", [
      "resource.name.startsWith(\"projects/_/buckets/${var.state_bucket_name}/objects/${var.shared_prefix}/\")",
      "resource.name.startsWith(\"projects/_/buckets/${var.state_bucket_name}/folders/${var.shared_prefix}/\")",
      "api.getAttribute(\"storage.googleapis.com/objectListPrefix\", \"\").startsWith(\"${var.shared_prefix}/\")",
    ])
  }
}
