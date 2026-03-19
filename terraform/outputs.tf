output "resource_group_name" {
  description = "Name of the resource group containing all lab resources"
  value       = azurerm_resource_group.main.name
}

output "key_vault_name" {
  description = "Name of the Key Vault storing the VM admin password"
  value       = azurerm_key_vault.main.name
}

output "admin_username" {
  description = "Admin username for all VMs (also SQL sysadmin)"
  value       = var.admin_username
}

output "get_password_command" {
  description = "Azure CLI command to retrieve the VM admin password"
  value       = "az keyvault secret show --vault-name ${azurerm_key_vault.main.name} --name vm-admin-password --query value -o tsv"
}

output "vm_names" {
  description = "Names of all SQL Server VMs"
  value       = [for vm in azurerm_windows_virtual_machine.sql : vm.name]
}

output "vm_private_ips" {
  description = "Private IP addresses of all SQL Server VMs"
  value       = { for name, nic in azurerm_network_interface.sql : name => nic.private_ip_address }
}

output "bastion_name" {
  description = "Name of the Azure Bastion host (use Azure Portal to connect)"
  value       = azurerm_bastion_host.main.name
}

output "log_analytics_workspace_name" {
  description = "Name of the Log Analytics workspace for BPA results"
  value       = azurerm_log_analytics_workspace.bpa.name
}

output "bpa_command" {
  description = "Command to enable SQL BPA on all lab VMs at once"
  value = join(" ", [
    ".\\Install-SqlIaaSExtension-BPA.ps1",
    "-SubscriptionId '${data.azurerm_client_config.current.subscription_id}'",
    "-ResourceGroupName '${azurerm_resource_group.main.name}'",
    "-VmNames ${join(",", [for vm in azurerm_windows_virtual_machine.sql : "'${vm.name}'"])}",
    "-Location '${var.location}'",
    "-WorkspaceName '${azurerm_log_analytics_workspace.bpa.name}'"
  ])
}
