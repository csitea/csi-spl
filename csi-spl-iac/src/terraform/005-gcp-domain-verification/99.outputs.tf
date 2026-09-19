output "verification_records_count" {
  description = "Number of site-verification CNAMEs managed by this step for this env."
  value       = length(var.verification_records)
}

output "verification_records" {
  description = "Source -> target pairs of the site-verification CNAMEs created by this step."
  value = {
    for r in var.verification_records :
    r.source => r.target
  }
}
