terraform {
  required_version = ">= 1.5.0"

  # No provider: the one resource is terraform_data (built in), as in 120. The
  # state bucket is reached with GOOGLE_APPLICATION_CREDENTIALS = the env's
  # project key (do_tf_init). No credentials path here.
  backend "gcs" {}
}
