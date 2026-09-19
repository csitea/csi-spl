output "secret_name" {
  value       = local.secret_name
  description = "The GitHub Actions secret this env owns."
}

output "published" {
  value       = local.key_present
  description = "false = no key file at key_path, so nothing was published (run gcp-002 for this env first)."
}

output "key_path" {
  value       = local.key_path
  description = "Where the key is read from. The path only, never the content."
}
