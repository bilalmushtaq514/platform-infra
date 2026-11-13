# -----------------------------------------------------------------------------
# Private IIS tier (I-3, I-4, I-5, I-6)
#   N x Windows Server 2022 VMs, NO public IPs, spread across zones,
#   behind a Standard *internal* load balancer with an HTTP /health probe.
#   Bootstrapped by the Run Command extension (scripts/iis-bootstrap.ps1).
# -----------------------------------------------------------------------------

locals {
  vms = { for i in range(var.vm_count) : format("%02d", i + 1) => {
    name = "vm-${var.name}-iis-${format("%02d", i + 1)}"
    # Windows computer names are limited to 15 characters.
    computer_name = substr("iis${var.computer_name_stem}${format("%02d", i + 1)}", 0, 15)
    zone          = length(var.zones) > 0 ? var.zones[i % length(var.zones)] : null
  } }

  bootstrap_parameters = {
    SiteName        = var.site_name
    AppPoolName     = var.app_pool_name
    AzdoOrgUrl      = var.azdo.org_url
    AzdoProject     = var.azdo.project
    AzdoEnvironment = var.azdo.environment
    AzdoVmTags      = var.azdo.vm_tags
    KeyVaultName    = var.azdo.org_url == "" ? "" : var.key_vault_name
    PatSecretName   = var.azdo.org_url == "" ? "" : var.azdo.pat_secret_name
  }
}

# --- Load balancer (internal only) ---------------------------------------------

resource "azurerm_lb" "this" {
  name                = "lbi-${var.name}-iis"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                          = "fe-private"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.lb_private_ip
    zones                         = length(var.zones) > 0 ? var.zones : null
  }
}

resource "azurerm_lb_backend_address_pool" "this" {
  name            = "be-iis"
  loadbalancer_id = azurerm_lb.this.id
}

resource "azurerm_lb_probe" "health" {
  name                = "probe-http-health"
  loadbalancer_id     = azurerm_lb.this.id
  protocol            = "Http"
  port                = 80
  request_path        = var.health_probe_path
  interval_in_seconds = 5
  number_of_probes    = 2 # node pulled after ~10s of failures
}

resource "azurerm_lb_rule" "http" {
  name                           = "http-80"
  loadbalancer_id                = azurerm_lb.this.id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "fe-private"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.this.id]
  probe_id                       = azurerm_lb_probe.health.id
  load_distribution              = "Default" # 5-tuple hash -> requests spread across nodes
  idle_timeout_in_minutes        = 4
  disable_outbound_snat          = true # egress goes through the NAT Gateway
}

# --- VMs -------------------------------------------------------------------------

resource "random_password" "admin" {
  length           = 24
  special          = true
  override_special = "!@#%^*-_=+"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

# Stored in Key Vault so humans can retrieve it for break-glass Bastion RDP.
resource "azurerm_key_vault_secret" "admin_password" {
  name         = "${var.name}-iis-admin-password"
  value        = random_password.admin.result
  key_vault_id = var.key_vault_id
  content_type = "IIS VM local admin (${var.admin_username})"
  tags         = var.tags
}

resource "azurerm_network_interface" "this" {
  for_each            = local.vms
  name                = "nic-${each.value.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    # deliberately no public_ip_address_id (I-4)
  }
}

resource "azurerm_network_interface_backend_address_pool_association" "this" {
  for_each                = local.vms
  network_interface_id    = azurerm_network_interface.this[each.key].id
  ip_configuration_name   = "ipconfig1"
  backend_address_pool_id = azurerm_lb_backend_address_pool.this.id
}

resource "azurerm_windows_virtual_machine" "this" {
  for_each              = local.vms
  name                  = each.value.name
  computer_name         = each.value.computer_name
  location              = var.location
  resource_group_name   = var.resource_group_name
  size                  = var.vm_size
  zone                  = each.value.zone
  admin_username        = var.admin_username
  admin_password        = random_password.admin.result
  network_interface_ids = [azurerm_network_interface.this[each.key].id]

  provision_vm_agent        = true
  patch_mode                = "AutomaticByPlatform"
  patch_assessment_mode     = "AutomaticByPlatform"
  hotpatching_enabled       = false
  secure_boot_enabled       = true
  vtpm_enabled              = true
  automatic_updates_enabled = true
  timezone                  = "UTC"

  identity {
    type = "SystemAssigned" # used to read the agent PAT from Key Vault
  }

  os_disk {
    name                 = "osdisk-${each.value.name}"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = var.windows_sku
    version   = "latest"
  }

  boot_diagnostics {} # managed storage account

  tags = merge(var.tags, { role = "iis" })
}

# Least privilege: each VM can read exactly ONE secret (the agent PAT), not the vault.
resource "azurerm_role_assignment" "vm_read_pat" {
  for_each             = var.azdo.org_url == "" ? {} : local.vms
  scope                = "${var.key_vault_id}/secrets/${var.azdo.pat_secret_name}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_windows_virtual_machine.this[each.key].identity[0].principal_id
}

resource "azurerm_virtual_machine_run_command" "bootstrap" {
  for_each           = local.vms
  name               = "iis-bootstrap"
  location           = var.location
  virtual_machine_id = azurerm_windows_virtual_machine.this[each.key].id

  source {
    script = file("${path.module}/scripts/iis-bootstrap.ps1")
  }

  # Run Command rejects empty parameter values, so only non-empty ones are sent;
  # the script's own defaults cover the rest (no org URL = skip agent install).
  dynamic "parameter" {
    for_each = { for k, v in local.bootstrap_parameters : k => v if v != "" }
    content {
      name  = parameter.key
      value = parameter.value
    }
  }

  tags = var.tags

  depends_on = [
    azurerm_role_assignment.vm_read_pat,
    azurerm_network_interface_backend_address_pool_association.this,
  ]
}
