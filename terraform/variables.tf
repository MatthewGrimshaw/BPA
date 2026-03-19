variable "tenant_id" {
  description = "Azure AD tenant ID (used by Create-LabEnvironment.ps1 for az login)"
  type        = string
}

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "backend_resource_group_name" {
  description = "Resource group containing the Terraform state storage account"
  type        = string
}

variable "backend_storage_account_name" {
  description = "Storage account name for Terraform state"
  type        = string
}

variable "backend_storage_container_name" {
  description = "Storage container name for Terraform state"
  type        = string
}

variable "prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "sql-bpa-lab"
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "swedencentral"
}

variable "admin_username" {
  description = "Admin username for all VMs (also SQL sysadmin)"
  type        = string
  default     = "sqladmin"
}

variable "shutdown_time" {
  description = "Daily auto-shutdown time in HHMM format (UTC)"
  type        = string
  default     = "1900"
}

variable "script_version" {
  description = "Increment to force the SQL configuration script to re-run on all VMs"
  type        = number
  default     = 1
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    environment = "lab"
    project     = "sql-bpa"
  }
}
