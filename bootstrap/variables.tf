variable "subscription_id" {
  description = "Azure subscription to deploy into."
  type        = string
}

variable "project" {
  description = "Short project name used in resource names (lowercase letters/digits only)."
  type        = string
  default     = "hybrid"

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.project))
    error_message = "project must be 2-8 lowercase letters/digits (it is used inside storage account names)."
  }
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "eastus2"
}

variable "location_short" {
  description = "Short region code used in names."
  type        = string
  default     = "eus2"
}

variable "state_contributor_object_ids" {
  description = "Extra Entra object IDs (e.g. the Azure DevOps service connection's service principal) that may read/write state and platform secrets."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Extra tags applied to every resource."
  type        = map(string)
  default     = {}
}
