output "state_resource_group_name" {
  value = azurerm_resource_group.state.name
}

output "state_storage_account_name" {
  value = azurerm_storage_account.state.name
}

output "state_container_name" {
  value = azurerm_storage_container.state.name
}

output "platform_key_vault_name" {
  value = azurerm_key_vault.platform.name
}

output "platform_key_vault_id" {
  value = azurerm_key_vault.platform.id
}

output "backend_hcl" {
  description = "Paste into envs/dev/backend.hcl"
  value       = <<-EOT
    resource_group_name  = "${azurerm_resource_group.state.name}"
    storage_account_name = "${azurerm_storage_account.state.name}"
    container_name       = "${azurerm_storage_container.state.name}"
    key                  = "dev/platform.tfstate"
    use_azuread_auth     = true
  EOT
}
