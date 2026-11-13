# -----------------------------------------------------------------------------
# dev environment: composes the reusable modules into the hybrid platform.
#
#   rg-hybrid-dev-eus2
#   ├─ vnet 10.20.0.0/16
#   │   ├─ snet-aks            10.20.0.0/22   -> AKS nodes (public app via AKS LB)
#   │   ├─ snet-iis            10.20.10.0/24  -> 3x IIS VMs + internal LB (private)
#   │   └─ AzureBastionSubnet  10.20.20.0/26  -> Azure Bastion (admin access)
#   ├─ NAT Gateway  (egress-only for snet-iis)
#   ├─ ACR + AKS    (AcrPull via kubelet managed identity)
#   └─ Log Analytics (AKS Container Insights)
# -----------------------------------------------------------------------------


data "azurerm_key_vault" "platform" {
  name                = var.platform_key_vault_name
  resource_group_name = var.platform_key_vault_rg
}

resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
}

locals {
  name = "${var.project}-${var.environment}-${var.location_short}"

  tags = merge(var.tags, {
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
    repo        = "platform-infra"
  })

  # Explicit list (NOT "whoever runs terraform"): otherwise a pipeline apply would
  # swap the human's access for the infra SP's and vice versa on every run.
  deployer_object_ids = distinct(var.deployer_object_ids)
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 1 # cost guard-rail for a sandbox
  tags                = local.tags
}

module "network" {
  source              = "../../modules/network"
  name                = local.name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = var.vnet_cidr
  aks_subnet_cidr     = var.aks_subnet_cidr
  iis_subnet_cidr     = var.iis_subnet_cidr
  bastion_subnet_cidr = var.bastion_subnet_cidr
  tags                = local.tags
}

module "bastion" {
  count               = var.enable_bastion ? 1 : 0
  source              = "../../modules/bastion"
  name                = local.name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = module.network.bastion_subnet_id
  tags                = local.tags
}

module "aks" {
  source                     = "../../modules/aks"
  name                       = local.name
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  subnet_id                  = module.network.aks_subnet_id
  acr_name                   = "acr${var.project}${var.environment}${random_string.suffix.result}"
  node_vm_size               = var.aks_node_vm_size
  node_min_count             = var.aks_node_min_count
  node_max_count             = var.aks_node_max_count
  pod_cidr                   = var.aks_pod_cidr
  service_cidr               = var.aks_service_cidr
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  deployer_object_ids        = local.deployer_object_ids
  tags                       = local.tags
}

module "iis" {
  source              = "../../modules/iis-tier"
  name                = local.name
  computer_name_stem  = var.environment
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = module.network.iis_subnet_id
  lb_private_ip       = cidrhost(var.iis_subnet_cidr, 10)
  vm_count            = var.iis_vm_count
  vm_size             = var.iis_vm_size
  zones               = var.zones
  key_vault_id        = data.azurerm_key_vault.platform.id
  key_vault_name      = data.azurerm_key_vault.platform.name
  azdo                = var.azdo
  tags                = local.tags

  # Egress must exist before the bootstrap script downloads the agent.
  depends_on = [module.network]
}
