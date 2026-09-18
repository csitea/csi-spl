output "wif_provider_name" {
  value       = google_iam_workload_identity_pool_provider.github.name
  description = "Full provider resource name — value of the GitHub repo variable GCP_WIF_PROVIDER_<ENV> (google-github-actions/auth@v2 workload_identity_provider)."
}

output "deploy_sa_email" {
  value       = google_service_account.deploy.email
  description = "Impersonated deploy SA — value of the GitHub repo variable GCP_DEPLOY_SA_EMAIL_<ENV> (auth@v2 service_account)."
}

output "github_ref" {
  value       = var.github_ref
  description = "The only ref whose runs may impersonate the deploy SA."
}

output "github_repository" {
  value       = var.github_repository
  description = "Repository the trust is pinned to (attribute_condition)."
}
