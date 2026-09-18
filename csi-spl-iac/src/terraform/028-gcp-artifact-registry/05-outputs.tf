# <region>-docker.pkg.dev/<project>/<repository_id>: the prefix of hub.image.ref
output "repository_url" {
  value = "${google_artifact_registry_repository.hub.location}-docker.pkg.dev/${var.gcp_project}/${google_artifact_registry_repository.hub.repository_id}"
}
