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

variable "subnet_id" {
  description = "Subnet for AKS nodes."
  type        = string
}

variable "acr_name" {
  description = "Globally unique, alphanumeric only."
  type        = string
}

variable "acr_sku" {
  type    = string
  default = "Basic"
}

variable "kubernetes_version" {
  description = "null = AKS default version for the region."
  type        = string
  default     = null
}

variable "node_vm_size" {
  type    = string
  default = "Standard_B2ms" # BS family: the only family with quota in this subscription
}

variable "node_min_count" {
  type    = number
  default = 1
}

variable "node_max_count" {
  type    = number
  default = 2
}

variable "pod_cidr" {
  description = "Overlay pod CIDR, must not overlap the VNet."
  type        = string
}

variable "service_cidr" {
  description = "Kubernetes service CIDR, must not overlap the VNet or pod CIDR."
  type        = string
}

variable "log_analytics_workspace_id" {
  type = string
}

variable "deployer_object_ids" {
  description = "Entra object IDs (CI service principal, humans) allowed to push images and deploy to the cluster."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
