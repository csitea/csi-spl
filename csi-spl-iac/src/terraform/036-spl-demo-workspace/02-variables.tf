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
  description = "The environment: dev or prd. Each env's state owns exactly its own demo workspace."

  validation {
    condition     = contains(["dev", "prd"], var.env)
    error_message = "env must be dev or prd."
  }
}

variable "gcp_project" {
  type        = string
  description = "The GCP project id, csi-spl-<env>. A new project re-runs the action."
}

variable "gcp_region" {
  type        = string
  description = "Rendered for every step; unused here."
  default     = "europe-north1"
}

variable "proj_path" {
  type        = string
  description = "csi-spl-iac's path in the tf-runner (TF_VAR_proj_path, exported by do_tf_init). The action runs from its sibling csi-spl-orc."
  default     = ""
}

# Step vars for 036-spl-demo-workspace: env.demo.{enabled,workspace}, derived
# into steps["036-spl-demo-workspace"] by do_spl_merged_cnf (rendered by tpl-gen).

variable "demo_enabled" {
  type        = bool
  description = "cnf env.demo.enabled. false: no workspace is made (count 0)."
}

variable "demo_workspace" {
  type        = string
  description = "cnf env.demo.workspace: the demo tenant id."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,31}$", var.demo_workspace))
    error_message = "demo_workspace must be a workspace slug: ^[a-z0-9][a-z0-9-]{0,31}$."
  }
}
