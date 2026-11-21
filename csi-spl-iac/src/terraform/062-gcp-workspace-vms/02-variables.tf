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
  description = "dev or prd: the project the private workspace VMs run in."

  validation {
    condition     = contains(["dev", "prd"], var.env)
    error_message = "062-gcp-workspace-vms runs in dev or prd only."
  }
}

variable "gcp_project" {
  type        = string
  description = "The project the VMs are created in."
}

variable "gcp_region" {
  type        = string
  description = "The region of the subnet. The zone must be inside it."
}

variable "gcp_zone" {
  type        = string
  description = "The zone of every workspace VM and its boot disk."
}

# spec 181 B5: one private VM per private workspace, <tenant> -> machine type.
# Empty (the default): the step plans no resource at all. Set at run time by
# TF_VAR_workspace_vms, never in the rendered tfvars (tenant ids are not committed).
variable "workspace_vms" {
  type        = map(string)
  default     = {}
  description = "One entry per private workspace: the tenant id -> the VM's machine type."

  validation {
    condition = alltrue([
      for tenant, machine_type in var.workspace_vms :
      can(regex("^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$", tenant)) && can(regex("^[a-z][a-z0-9]*-[a-z0-9-]+$", machine_type))
    ])
    error_message = "workspace_vms keys must be tenant ids that end in a letter or digit (^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$: the hub's tenants check, narrowed by the instance name rule, which refuses a trailing -) and values machine types such as e2-standard-2."
  }
}

variable "vm_name_prefix" {
  type        = string
  description = "The instance name is <prefix>-<tenant>; the box label is the instance name."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,29}$", var.vm_name_prefix))
    error_message = "vm_name_prefix must start with a letter and be at most 30 characters, so <prefix>-<tenant> stays a 63-character name and label value."
  }
}

variable "subnet_cidr" {
  type        = string
  description = "The one subnet of the workspace VMs' own VPC."
}

variable "boot_disk_image" {
  type        = string
  description = "A dated Debian 13 image, never a floating family."

  validation {
    condition     = can(regex("/images/debian-13-trixie-v[0-9]{8}$", var.boot_disk_image))
    error_message = "boot_disk_image must be a dated debian-13-trixie-vYYYYMMDD image, not a family."
  }
}

variable "boot_disk_size_gb" {
  type        = number
  description = "The boot disk size in GB of each workspace VM."
}

variable "boot_disk_type" {
  type        = string
  description = "The boot disk type of each workspace VM."
}

variable "assign_external_ip" {
  type        = bool
  description = "Give each VM an ephemeral public address for its egress (the hub, the vendor APIs). No Cloud NAT. Inbound stays tcp/22 from ssh_source_ranges."
}

variable "ssh_source_ranges" {
  type        = list(string)
  description = "Who may open tcp/22 for upkeep (spec 181 Q-3 A). Never the whole internet."

  validation {
    condition = length(var.ssh_source_ranges) > 0 && alltrue([
      for r in var.ssh_source_ranges : r != "0.0.0.0/0" && r != "::/0"
    ])
    error_message = "ssh_source_ranges must be non-empty and must not be 0.0.0.0/0 or ::/0."
  }
}

variable "vm_sa_roles" {
  type        = list(string)
  description = "Roles of each VM's own service account. Logging and metrics only."
}
