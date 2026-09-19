variable "org" {
  type        = string
  description = "the 3-letter code of the organisation used in the account name"
}

variable "app" {
  type        = string
  description = "The current application name."
}

variable "env" {
  type        = string
  description = "The current environment."
  validation {
    condition     = contains(["dev", "tst", "stg", "prd", "all"], var.env)
    error_message = "Environment must be one of: dev, tst, stg, prd, all."
  }
}

variable "STEP" {
  type        = string
  description = "the current step"
}
