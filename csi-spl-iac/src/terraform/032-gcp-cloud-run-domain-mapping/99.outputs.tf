output "primary_domain" {
  description = "Primary custom domain mapped to the API Cloud Run service for this env."
  value       = var.cloud_run_custom_domain
}

output "additional_domains" {
  description = "Additional domain aliases mapped to the API Cloud Run service."
  value       = var.cloud_run_additional_domains
}

output "all_domains" {
  description = "All custom domains owned by this step for this env."
  value = compact(concat(
    [var.cloud_run_custom_domain],
    var.cloud_run_additional_domains,
  ))
}
