variable "org" {
  type        = string
  description = "The 3-letter organisation code (csi)."
}

variable "app" {
  type        = string
  description = "The application code (spl)."
}

variable "env" {
  type        = string
  description = "The environment: dev or prd. Each env's state owns exactly its own GitHub secret."

  validation {
    condition     = contains(["dev", "prd"], var.env)
    error_message = "env must be dev or prd."
  }
}

variable "gcp_project" {
  type        = string
  description = "The GCP project id, csi-spl-<env>. Names the key file: ~/.gcp/.<org>/key-<gcp_project>.json (gcp-002)."
}

variable "gcp_region" {
  type        = string
  description = "Rendered for every step; unused here."
  default     = "europe-north1"
}

# Step vars for 120-github-general-secrets. Sourced from
# steps["120-github-general-secrets"] in the per-env yaml (rendered by tpl-gen).

variable "gh_repo" {
  type        = string
  description = "GitHub <owner>/<repo> that receives the Actions secret. No default: the target must be explicit per env."

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.gh_repo))
    error_message = "gh_repo must be <owner>/<repo>."
  }
}
