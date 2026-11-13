# -----------------------------------------------------------------------------
# Azure Bastion (I-1 admin access)
#   Browser-based RDP to the private IIS VMs over TLS 443 on the Bastion's own
#   public IP. The VMs themselves never get a public IP, and the IIS NSG only
#   admits 3389 from AzureBastionSubnet.
#   Basic SKU is the cheapest SKU that lives in the VNet. Toggle off with
#   enable_bastion = false when not demoing (~$0.19/h).
# -----------------------------------------------------------------------------

resource "azurerm_public_ip" "this" {
  name                = "pip-${var.name}-bastion"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_bastion_host" "this" {
  name                = "bas-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Basic"
  tags                = var.tags

  ip_configuration {
    name                 = "ipconfig"
    subnet_id            = var.subnet_id
    public_ip_address_id = azurerm_public_ip.this.id
  }
}
