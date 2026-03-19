resource "azurerm_bastion_host" "main" {
  name                = "${var.prefix}-bastion"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Developer"
  virtual_network_id  = azurerm_virtual_network.main.id
  tags                = var.tags
}
