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
  description = "Rendered from prd only: ONE satellite for dev and prd, in csi-spl-all (spec 057 R1, owner 2026-10-01)."

  validation {
    condition     = var.env == "prd"
    error_message = "060-gcp-vm-satellite renders from prd only (spec 057: one satellite, in csi-spl-all)."
  }
}

variable "gcp_project" {
  type        = string
  description = "The satellite's project, csi-spl-all (steps.060.gcp_project)."
}

variable "gcp_region" {
  type        = string
  description = "The GCP region."
  default     = "europe-north1"
}

variable "vm_name" {
  type        = string
  description = "The instance name, csi-spl-all-satellite."
}

variable "gcp_zone" {
  type        = string
  description = "The zone (round 1 Q5 A: europe-north1-a)."
}

variable "subnet_cidr" {
  type        = string
  description = "The satellite VPC's one subnet (its own VPC: no default network and none of its allow-all rules)."
}

variable "machine_type" {
  type        = string
  description = "The machine type (round 2 Q1)."
}

variable "boot_disk_image" {
  type        = string
  description = "A DATED image (spec R16), never a floating family."

  validation {
    condition     = can(regex("/images/debian-13-trixie-v[0-9]{8}$", var.boot_disk_image))
    error_message = "boot_disk_image must be a dated debian-13-trixie-vYYYYMMDD image, not a family."
  }
}

variable "boot_disk_size_gb" {
  type        = number
  description = "The boot disk size."
}

variable "data_disk_name" {
  type        = string
  description = "The data disk, separate from the VM so a rebuild keeps it."
}

variable "data_disk_type" {
  type        = string
  description = "The data disk type."
}

variable "data_disk_size_gb" {
  type        = number
  description = "The data disk size (round 2 Q2)."
}

variable "os_user" {
  type        = string
  description = "The GCE Debian default user (round 1 Q9)."
}

variable "ssh_public_key_file" {
  type        = string
  description = "The PUBLIC key minted by do_satellite_ssh_keygen (round 2 Q3 b). The private key never enters terraform."

  validation {
    condition     = endswith(var.ssh_public_key_file, ".pub")
    error_message = "ssh_public_key_file must name the .pub half: the private key never enters terraform (R14)."
  }
}

variable "ssh_source_ranges" {
  type        = list(string)
  description = "Who may reach tcp/22: Google IAP only (round 1 Q7 A)."
}

variable "iap_members" {
  type        = list(string)
  description = "Extra members allowed to open an IAP tunnel to the VM."
  default     = []
}

variable "box_label" {
  type        = string
  description = "The value of the box label the 059 budget filters on."
}
