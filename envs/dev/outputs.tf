output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "aks_cluster_name" {
  value = module.aks.cluster_name
}

output "acr_name" {
  value = module.aks.acr_name
}

output "acr_login_server" {
  value = module.aks.acr_login_server
}

output "iis_lb_private_ip" {
  description = "Internal-only endpoint of the legacy app."
  value       = module.iis.lb_private_ip
}

output "iis_vm_private_ips" {
  value = module.iis.vm_private_ips
}

output "iis_admin_username" {
  value = module.iis.admin_username
}

output "iis_admin_password_secret_id" {
  value = module.iis.admin_password_secret_id
}

output "iis_egress_ip" {
  description = "NAT Gateway IP (outbound only - nothing listens on it)."
  value       = module.network.nat_public_ip
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.this.id
}
