# -----------------------------------------------------------------------------
# Network module
#   VNet + 3 subnets (AKS, IIS, Bastion) + NSGs + NAT Gateway for IIS egress.
#   Requirements: I-1, I-4, I-10
# -----------------------------------------------------------------------------

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.address_space]
  tags                = var.tags
}

# --- Subnets -----------------------------------------------------------------

resource "azurerm_subnet" "aks" {
  name                 = "snet-aks"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.aks_subnet_cidr]
}

resource "azurerm_subnet" "iis" {
  name                 = "snet-iis"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.iis_subnet_cidr]
  # Private subnet: no implicit "default outbound" internet access.
  # The only egress path is the NAT Gateway below (I-10).
  default_outbound_access_enabled = false
}

# Name is mandated by Azure Bastion.
resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.bastion_subnet_cidr]
}

# --- NSG: IIS (private) subnet ---------------------------------------------
# Rule order matters: explicit allows for the few legitimate sources, then an
# explicit deny of the Internet service tag, then a catch-all deny that also
# overrides Azure's default "AllowVnetInBound" (65000) so that only the listed
# ports are reachable even from inside the VNet.

resource "azurerm_network_security_group" "iis" {
  name                = "nsg-${var.name}-iis"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "Allow-HTTP-HTTPS-From-VNet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = var.address_space
    source_port_range          = "*"
    destination_address_prefix = var.iis_subnet_cidr
    destination_port_ranges    = ["80", "443"]
    description                = "App traffic from inside the VNet only (AKS pods, Bastion-hosted sessions, other IIS nodes, internal LB)."
  }

  security_rule {
    name                       = "Allow-RDP-From-Bastion"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = var.bastion_subnet_cidr
    source_port_range          = "*"
    destination_address_prefix = var.iis_subnet_cidr
    destination_port_range     = "3389"
    description                = "Admin access only through Azure Bastion."
  }

  security_rule {
    name                       = "Allow-AzureLoadBalancer-Probe"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "AzureLoadBalancer"
    source_port_range          = "*"
    destination_address_prefix = var.iis_subnet_cidr
    destination_port_range     = "80"
    description                = "Health probes from the internal load balancer (168.63.129.16)."
  }

  security_rule {
    name                       = "Deny-Internet-Inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "Internet"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
    description                = "Explicit: nothing from the Internet, ever (I-4)."
  }

  security_rule {
    name                       = "Deny-All-Other-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "*"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
    description                = "Default-deny; overrides AllowVnetInBound so only the ports above are open."
  }
}

resource "azurerm_subnet_network_security_group_association" "iis" {
  subnet_id                 = azurerm_subnet.iis.id
  network_security_group_id = azurerm_network_security_group.iis.id
}

# --- NSG: AKS subnet ----------------------------------------------------------
# The public app lives here. Only HTTP/HTTPS is admitted from the Internet;
# everything else falls through to Azure defaults (VNet + LB allowed, Internet denied).

resource "azurerm_network_security_group" "aks" {
  name                = "nsg-${var.name}-aks"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "Allow-HTTP-HTTPS-From-Internet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "Internet"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_ranges    = ["80", "443"]
    description                = "Public entry to the modern app via the AKS-managed public load balancer."
  }
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

# --- NAT Gateway: outbound-only egress for the IIS subnet (I-10) ---------------
# Gives the IIS VMs a single, static egress IP for Windows Update, NuGet/agent
# downloads and the Azure Pipelines agent's outbound HTTPS long-poll to
# dev.azure.com. NAT Gateway never accepts unsolicited inbound connections.

resource "azurerm_public_ip" "nat" {
  name                = "pip-${var.name}-nat"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  name                    = "ng-${var.name}"
  location                = var.location
  resource_group_name     = var.resource_group_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "iis" {
  subnet_id      = azurerm_subnet.iis.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}
