output "lb_private_ip" {
  value = azurerm_lb.this.frontend_ip_configuration[0].private_ip_address
}

output "vm_private_ips" {
  value = { for k, nic in azurerm_network_interface.this : azurerm_windows_virtual_machine.this[k].computer_name => nic.private_ip_address }
}

output "vm_ids" {
  value = { for k, vm in azurerm_windows_virtual_machine.this : vm.name => vm.id }
}

output "admin_username" {
  value = var.admin_username
}

output "admin_password_secret_id" {
  description = "Key Vault secret holding the local admin password (value is never output)."
  value       = azurerm_key_vault_secret.admin_password.versionless_id
}
