# spec 190 row T2 (gap G9, owner poll fd47ab36 Q2 B): the hub hands a reader
# a 5-minute GCS V4 signed URL for a Qto media file. Cloud Run holds no key,
# so the hub signs through the IAM Credentials signBlob call AS its own
# runtime SA, which needs iam.serviceAccounts.signBlob on that SA.
# serviceAccountTokenCreator on the runtime SA ONLY, never on the project: it
# lets the SA sign and mint tokens as itself, which adds no reach it lacks.
# The predefined role keeps this step one resource; a custom role holding only
# signBlob would be a second, project-level resource.
resource "google_service_account_iam_member" "hub_self_sign" {
  service_account_id = google_service_account.hub.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.hub.email}"
}
