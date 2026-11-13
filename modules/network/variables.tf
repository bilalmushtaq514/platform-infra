variable "name" {
  description = "Name stem, e.g. hybrid-dev-eus2."
  type        = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "address_space" {
  description = "VNet CIDR."
  type        = string
}

variable "aks_subnet_cidr" {
  type = string
}

variable "iis_subnet_cidr" {
  type = string
}

variable "bastion_subnet_cidr" {
  description = "Must be /26 or larger (Azure Bastion requirement)."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
