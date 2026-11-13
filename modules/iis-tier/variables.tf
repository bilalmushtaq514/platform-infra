variable "name" {
  description = "Name stem, e.g. hybrid-dev-eus2."
  type        = string
}

variable "computer_name_stem" {
  description = "Short stem for Windows computer names (total must stay <= 15 chars), e.g. 'dev' -> iisdev01."
  type        = string
  default     = "dev"
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "subnet_id" {
  description = "Private subnet for the IIS NICs and the ILB frontend."
  type        = string
}

variable "lb_private_ip" {
  description = "Static private IP of the internal load balancer frontend (inside subnet_id)."
  type        = string
}

variable "vm_count" {
  type    = number
  default = 3
}

variable "vm_size" {
  description = "Windows needs >= 2 vCPU / 4-8 GB to be usable."
  type        = string
  default     = "Standard_B2ms"
}

variable "windows_sku" {
  type    = string
  default = "2022-datacenter-azure-edition"
}

variable "zones" {
  description = "Availability zones to spread VMs across. Empty list for regions without zones."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "admin_username" {
  type    = string
  default = "iisadmin"
}

variable "site_name" {
  type    = string
  default = "eShopLegacy"
}

variable "app_pool_name" {
  type    = string
  default = "eShopLegacy"
}

variable "health_probe_path" {
  type    = string
  default = "/health"
}

variable "key_vault_id" {
  description = "Platform Key Vault (stores the admin password; holds the agent PAT)."
  type        = string
}

variable "key_vault_name" {
  type = string
}

variable "azdo" {
  description = "Azure DevOps Environment registration. Leave org_url empty to skip agent install."
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

variable "tags" {
  type    = map(string)
  default = {}
}
