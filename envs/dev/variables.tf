variable "subscription_id" {
  type = string
}

variable "project" {
  type    = string
  default = "hybrid"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "location" {
  type    = string
  default = "eastus2"
}

variable "location_short" {
  type    = string
  default = "eus2"
}

variable "zones" {
  description = "Availability zones for the IIS VMs and ILB frontend."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "tags" {
  type    = map(string)
  default = {}
}

# --- Platform (bootstrap) Key Vault --------------------------------------------

variable "platform_key_vault_name" {
  description = "Created by ../../bootstrap."
  type        = string
}

variable "platform_key_vault_rg" {
  type = string
}

# --- Network -------------------------------------------------------------------

variable "vnet_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "aks_subnet_cidr" {
  type    = string
  default = "10.20.0.0/22"
}

variable "iis_subnet_cidr" {
  type    = string
  default = "10.20.10.0/24"
}

variable "bastion_subnet_cidr" {
  type    = string
  default = "10.20.20.0/26"
}

variable "enable_bastion" {
  description = "Bastion costs ~$0.19/h; switch off between demos."
  type        = bool
  default     = true
}

# --- AKS -------------------------------------------------------------------------

variable "aks_node_vm_size" {
  type    = string
  default = "Standard_B2ms" # BS family: the only family with quota in this subscription
}

variable "aks_node_min_count" {
  type    = number
  default = 1
}

variable "aks_node_max_count" {
  type    = number
  default = 2
}

variable "aks_pod_cidr" {
  type    = string
  default = "192.168.0.0/16"
}

variable "aks_service_cidr" {
  type    = string
  default = "172.16.0.0/16"
}

variable "deployer_object_ids" {
  description = "Object IDs of the Azure DevOps service connection SP (and any humans) that deploy to AKS/ACR."
  type        = list(string)
  default     = []
}

# --- IIS tier --------------------------------------------------------------------

variable "iis_vm_count" {
  type    = number
  default = 3
}

variable "iis_vm_size" {
  type    = string
  default = "Standard_B2ms"
}

variable "azdo" {
  description = "Azure DevOps Environment the IIS VMs self-register into. org_url = \"\" skips agent install."
  type = object({
    org_url         = string
    project         = string
    environment     = string
    vm_tags         = optional(string, "iis")
    pat_secret_name = optional(string, "azdo-agent-pat")
  })
  default = {
    org_url     = ""
    project     = ""
    environment = ""
  }
}
