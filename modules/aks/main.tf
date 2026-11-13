# -----------------------------------------------------------------------------
# AKS + ACR module (I-2)
#   - ACR with admin user DISABLED; AKS kubelet identity gets AcrPull (managed
#     identity pull, no registry credentials anywhere).
#   - Control plane uses a user-assigned identity so we can grant it
#     "Network Contributor" on the BYO subnet *before* the cluster is created.
#   - Entra ID auth + Azure RBAC for Kubernetes, local accounts disabled.
# -----------------------------------------------------------------------------

data "azurerm_client_config" "current" {}

resource "azurerm_container_registry" "this" {
  name                          = var.acr_name
  location                      = var.location
  resource_group_name           = var.resource_group_name
  sku                           = var.acr_sku
  admin_enabled                 = false
  anonymous_pull_enabled        = false
  public_network_access_enabled = true # Basic SKU; private endpoint needs Premium (see docs/improvements)
  tags                          = var.tags
}

resource "azurerm_user_assigned_identity" "control_plane" {
  name                = "id-aks-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_role_assignment" "control_plane_subnet" {
  scope                = var.subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.control_plane.principal_id
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = "aks-${var.name}"
  kubernetes_version  = var.kubernetes_version
  sku_tier            = "Free"
  node_resource_group = "rg-${var.name}-aks-nodes"

  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  local_account_disabled            = true
  role_based_access_control_enabled = true
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name                         = "system"
    vm_size                      = var.node_vm_size
    vnet_subnet_id               = var.subnet_id
    auto_scaling_enabled         = true
    min_count                    = var.node_min_count
    max_count                    = var.node_max_count
    os_disk_size_gb              = 64
    os_sku                       = "AzureLinux"
    max_pods                     = 50
    only_critical_addons_enabled = false
    temporary_name_for_rotation  = "systemtmp"
    tags                         = var.tags

    upgrade_settings {
      max_surge = "33%"
    }
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay" # pods get IPs from pod_cidr, not the VNet: saves VNet space
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = cidrhost(var.service_cidr, 10)
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.control_plane.id]
  }

  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_workspace_id
    msi_auth_for_monitoring_enabled = true
  }

  tags = var.tags

  depends_on = [azurerm_role_assignment.control_plane_subnet]

  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count, # owned by the cluster autoscaler
      kubernetes_version,              # owned by automatic_upgrade_channel
    ]
  }
}

# Image pull via the kubelet managed identity: no imagePullSecrets, no ACR admin.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                            = azurerm_container_registry.this.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

# --- Deployers (CI/CD service principal and humans) ---------------------------

# Push images.
resource "azurerm_role_assignment" "deployer_acr_push" {
  for_each             = toset(var.deployer_object_ids)
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPush"
  principal_id         = each.value
}

# `az aks get-credentials`.
resource "azurerm_role_assignment" "deployer_cluster_user" {
  for_each             = toset(var.deployer_object_ids)
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = each.value
}

# Kubernetes RBAC (Azure RBAC for K8s). Cluster-admin keeps the demo simple;
# in a real setup scope "RBAC Writer" to the app namespace only.
resource "azurerm_role_assignment" "deployer_rbac_admin" {
  for_each             = toset(var.deployer_object_ids)
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}
