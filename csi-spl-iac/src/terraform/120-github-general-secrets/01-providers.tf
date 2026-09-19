terraform {
  required_version = ">= 1.5.0"

  # No provider: the one resource is terraform_data (built in). The state
  # bucket is reached with the caller's identity: GOOGLE_APPLICATION_CREDENTIALS
  # = the project key this step publishes, or ADC. No credentials path here.
  backend "gcs" {}
}
