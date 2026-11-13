output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "vnet_name" {
  value = azurerm_virtual_network.this.name
}

output "aks_subnet_id" {
  value = azurerm_subnet.aks.id
}

output "iis_subnet_id" {
  value = azurerm_subnet.iis.id
}

output "bastion_subnet_id" {
  value = azurerm_subnet.bastion.id
}

output "iis_nsg_id" {
  value = azurerm_network_security_group.iis.id
}

output "nat_public_ip" {
  description = "Static egress IP of the IIS tier (outbound only)."
  value       = azurerm_public_ip.nat.ip_address
}
