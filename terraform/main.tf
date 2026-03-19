terraform {
  required_version = ">= 1.5.0"

  backend "azurerm" {
    use_azuread_auth = true
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
  subscription_id = var.subscription_id

  # Use Azure AD auth for Storage data-plane operations (required when shared key auth is disabled).
  storage_use_azuread = true
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "main" {
  name     = "${var.prefix}-rg"
  location = var.location
  tags     = var.tags
}

# Query the Microsoft.SqlVirtualMachine provider registration status
data "external" "sql_vm_provider_status" {
  program = ["powershell", "-NoProfile", "-Command", "az provider show --namespace Microsoft.SqlVirtualMachine --query '{state: registrationState}' -o json"]
}

# Register only if not already registered
resource "terraform_data" "register_sql_vm_provider" {
  count = data.external.sql_vm_provider_status.result.state != "Registered" ? 1 : 0

  provisioner "local-exec" {
    command = "az provider register --namespace Microsoft.SqlVirtualMachine --wait"
  }
}

resource "azurerm_log_analytics_workspace" "bpa" {
  name                = "${var.prefix}-law"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_role_assignment" "law_contributor" {
  scope                = azurerm_log_analytics_workspace.bpa.id
  role_definition_name = "Log Analytics Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "random_password" "admin" {
  length           = 20
  special          = true
  override_special = "!@#$%&*()-_=+"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}
