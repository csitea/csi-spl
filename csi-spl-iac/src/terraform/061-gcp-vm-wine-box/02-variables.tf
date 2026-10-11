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
  description = "Dev only: one wine test box, in the dev project."

  validation {
    condition     = var.env == "dev"
    error_message = "061-gcp-vm-wine-box is dev only. The prd render carries the dev-only marker and is not applied."
  }
}

variable "gcp_project" {
  type        = string
  description = "The project the VM is created in."
}

variable "gcp_region" {
  type        = string
  description = "The region of the subnet. The zone must be inside it."
}

variable "vm_name" {
  type        = string
  description = "The instance name, also the VM service account id."
}

variable "gcp_zone" {
  type        = string
  description = "The zone of the VM and its disks."
}

variable "subnet_cidr" {
  type        = string
  description = "The one subnet of this box's own VPC."
}

variable "machine_type" {
  type        = string
  description = "The machine type. The test minimum is 4 vCPU and 16 GB."
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
  description = "The boot disk size in GB. The test minimum is 100."
}

variable "boot_disk_type" {
  type        = string
  description = "The boot disk type. The test minimum is an SSD (pd-ssd)."
}

variable "data_disk_enabled" {
  type        = bool
  description = "Attach a second disk. Off: the boot disk is the only disk."
}

variable "data_disk_name" {
  type        = string
  description = "The data disk name, used only when data_disk_enabled is true."
}

variable "data_disk_type" {
  type        = string
  description = "The data disk type, used only when data_disk_enabled is true."
}

variable "data_disk_size_gb" {
  type        = number
  description = "The data disk size in GB, used only when data_disk_enabled is true."

  validation {
    condition     = !var.data_disk_enabled || var.data_disk_size_gb >= 10
    error_message = "data_disk_size_gb must be at least 10 when data_disk_enabled is true."
  }
}

variable "data_disk_device_name" {
  type        = string
  description = "The guest device name of the data disk (by-id google-<name>)."
}

variable "vm_hostname" {
  type        = string
  description = "The OS hostname, a FQDN. The instance name stays vm_name."

  validation {
    condition     = can(regex("^[a-z][-a-z0-9]{0,61}[a-z0-9]?(\\.[a-z][-a-z0-9]{0,61}[a-z0-9])+$", var.vm_hostname))
    error_message = "vm_hostname must be a FQDN (GCE custom hostname)."
  }
}

variable "os_user" {
  type        = string
  description = "The image's admin user. Ansible connects as this user."
}

variable "desktop_user" {
  type        = string
  description = "The non-root user that owns the Wine desktop. No sudo."
}

variable "ssh_public_key_file" {
  type        = string
  description = "The admin PUBLIC key. do_spl_wine_box_ssh_keygen mints the pair. The private key never enters terraform."

  validation {
    condition     = endswith(var.ssh_public_key_file, ".pub")
    error_message = "ssh_public_key_file must name the .pub half."
  }
}

variable "desktop_user_ssh_public_keys" {
  type        = list(string)
  description = "Extra public keys for the desktop user. Empty until one is added. A public key is not a secret."
}

variable "ssh_source_ranges" {
  type        = list(string)
  description = "Who may open tcp/22. Never the whole internet."

  validation {
    condition = length(var.ssh_source_ranges) > 0 && alltrue([
      for r in var.ssh_source_ranges : r != "0.0.0.0/0" && r != "::/0"
    ])
    error_message = "ssh_source_ranges must be non-empty and must not be 0.0.0.0/0 or ::/0."
  }
}

variable "assign_external_ip" {
  type        = bool
  description = "Give the VM an ephemeral public address so a plain SSH tunnel can reach it. The address is released when the VM stops. Inbound tcp/22 is still limited to ssh_source_ranges."
}

variable "iap_members" {
  type        = list(string)
  description = "Extra members allowed to open an IAP tunnel. Empty adds no binding."
}

variable "extra_apis" {
  type        = list(string)
  description = "APIs this step enables. Disabling them on destroy is off."
}

variable "box_label" {
  type        = string
  description = "The value of the box label the 058 budget filters on."
}

variable "vm_sa_roles" {
  type        = list(string)
  description = "Roles of the VM's own service account. Logging and metrics only."
}

variable "proj_path" {
  type        = string
  description = "csi-spl-iac's path in the tf-runner (TF_VAR_proj_path, exported by do_tf_init). Empty: no ansible files are written (a bare plan)."
  default     = ""
}
