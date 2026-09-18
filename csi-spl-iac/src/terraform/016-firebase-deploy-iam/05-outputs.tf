output "firebase_deploy_sa_email" {
  value       = google_service_account.firebase_deploy.email
  description = "Email of the Firebase Hosting deploy SA for this env."
}

output "firebase_deploy_roles" {
  value       = [for r in google_project_iam_member.firebase_deploy : r.role]
  description = "Roles bound to the firebase-deploy SA."
}
