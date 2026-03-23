# Migrating DCR/DCE to Terraform Management

This document explains how to migrate existing Data Collection Rules (DCR) and Data Collection Endpoints (DCE) from PowerShell auto-creation to Terraform management.

## Background

Previously, DCRs and DCEs were auto-created by the Azure CLI command `az sql vm update --enable-assessment`. This approach worked but made it difficult to version control and manage the infrastructure as code.

Now, all DCRs and DCEs are defined in Terraform for better control and repeatability.

## Architecture Overview

After migration, you will have:

| Resource | Name | Purpose | Managed By |
|----------|------|---------|------------|
| **Shared DCE** | `{prefix}-dce` | Shared endpoint for all data uploads | Terraform |
| **BPA DCR** | `{prefix}-bpa-dcr` | BPA CSV file ingestion | Terraform |
| **Perf DCR** | `{prefix}-sql-perfcounters-dcr` | Performance counter collection | Terraform |

**Both DCRs use the same shared DCE** and send data to Log Analytics workspace: `{prefix}-law`

> **Note:** Azure Monitor Agent best practice is to use a single DCE per environment rather than creating separate DCEs for each data type. Multiple DCRs can share the same DCE.

## Migration Steps

### For Existing Deployments (Resources Already Exist)

If you've already run the PowerShell scripts and have existing DCR/DCE resources:

#### 1. **Backup Current State**
```powershell
# List existing DCRs and DCEs
az monitor data-collection rule list --resource-group sql-bpa-lab-rg --output table
az monitor data-collection endpoint list --resource-group sql-bpa-lab-rg --output table

# Save the configuration
az monitor data-collection rule show --name <dcr-name> --resource-group sql-bpa-lab-rg > backup-dcr.json
az monitor data-collection endpoint show --name <dce-name> --resource-group sql-bpa-lab-rg > backup-dce.json
```

#### 2. **Import Existing Resources into Terraform**

Run the import helper script:
```powershell
.\Import-DcrDceToTerraform.ps1
```

This script will:
- Find your existing BPA Assessment DCR and DCE
- Import them into Terraform state
- Provide guidance on next steps

#### 3. **Verify Terraform Configuration**

```powershell
cd terraform
terraform plan
```

Review the plan output carefully:
- If you see **no changes** or only minor formatting differences, you're good to proceed
- If you see **destroy/recreate**, the Terraform config doesn't match existing resources perfectly

#### 4. **Apply Any Necessary Changes**

```powershell
terraform apply
```

This will bring the resources under Terraform management without disrupting them.

#### 5. **Update PowerShell Scripts**

The `Create-LabEnvironment.ps1` script has been updated to:
- Reference Terraform-created DCR/DCE instead of creating them
- Only associate Arc machines with the existing resources
- Not modify or update the DCR configuration

### For New Deployments (Clean Start)

If you're deploying from scratch:

#### 1. **Deploy Terraform First**
```powershell
cd terraform
terraform init
terraform plan
terraform apply
```

This creates all infrastructure including DCR/DCE.

#### 2. **Run Create-LabEnvironment.ps1**
```powershell
cd ..
.\Create-LabEnvironment.ps1
```

The script will:
- Use the Terraform-created DCR/DCE  
- Associate them with Arc machines
- Configure SQL BPA on all VMs

## Important Notes

### ⚠️ About `Install-SqlIaaSExtension-BPA.ps1`

The `Install-SqlIaaSExtension-BPA.ps1` script still uses `--enable-assessment` which attempts to auto-create a DCR/DCE. This is necessary to enable the assessment feature on Azure SQL VMs.

**What happens:**
- If DCR/DCE with matching names already exist (created by Terraform), Azure will use them
- If not, Azure creates new ones (which should then be imported into Terraform)

**Best practice:** Always run `terraform apply` before running the Install script to ensure Terraform-managed resources exist first.

### Resource Naming

Terraform creates resources with predictable names:
- DCE: `{prefix}-dce`
- DCR: `{prefix}-bpa-dcr`

Azure's auto-created names are typically: `{guid}_{location}_DCR_1`

### Associations

**Azure VMs:**
- DCR associations: Managed by Terraform (`azurerm_monitor_data_collection_rule_association.bpa_azure_vms`)
- DCE associations: Managed by Terraform (`azurerm_monitor_data_collection_rule_association.bpa_dce_azure_vms`)

**Arc Machines:**
- DCR associations: Created by PowerShell (dynamic, IDs not known at Terraform plan time)
- DCE associations: Created by PowerShell

## Troubleshooting

### Conflict: Resource Already Exists

If you get errors about resources already existing:

```
Error: A resource with the ID "/subscriptions/.../providers/Microsoft.Insights/dataCollectionRules/..." already exists
```

**Solution:** Import the existing resource
```powershell
terraform import azurerm_monitor_data_collection_rule.bpa_assessment "<full-resource-id>"
```

### Plan Shows Unexpected Changes

If `terraform plan` shows changes you don't expect:

1. **Compare configurations:** Check the Terraform config against the existing resource JSON
2. **Check for drift:** Use `terraform refresh` to update state
3. **Review sensitive values:** Some fields like `settings.text.recordStartTimestampFormat` may differ

### PowerShell Can't Find DCR/DCE

If the PowerShell script reports:
```
ERROR: BPA DCR or DCE not found. Ensure 'terraform apply' completed successfully.
```

**Solution:**
1. Verify Terraform deployed successfully: `cd terraform && terraform state list`
2. Check resources exist: `az monitor data-collection rule list --resource-group sql-bpa-lab-rg`
3. Verify naming: Resources should be named `{prefix}-dce` and `{prefix}-bpa-dcr`

## Rollback Plan

If migration causes issues, you can rollback:

1. **Remove Terraform-managed resources from state (don't destroy):**
   ```powershell
   terraform state rm azurerm_monitor_data_collection_rule.bpa_assessment
   terraform state rm azurerm_monitor_data_collection_endpoint.bpa_assessment
   ```

2. **Continue using PowerShell-managed resources** as before

3. **Revert Create-LabEnvironment.ps1** to previous version

## File Changes Summary

### New Files
- `terraform/bpa-assessment-dcr.tf` - BPA DCR/DCE Terraform config
- `terraform/performance-counters-dcr.tf` - Performance counter DCR/DCE Terraform config (already created)
- `Import-DcrDceToTerraform.ps1` - Helper script for importing existing resources
- `docs/DCR-DCE-MIGRATION.md` - This file

### Modified Files
- `Create-LabEnvironment.ps1` - Simplified to use Terraform-created DCR/DCE, removed DCR update logic
- `Install-SqlIaaSExtension-BPA.ps1` - No changes (still auto-creates, but defers to existing if present)

## Benefits

After migration:
✅ All infrastructure defined in version-controlled Terraform  
✅ Repeatable deployments with `terraform apply`
✅ Clear dependency management and resource relationships
✅ Easier to modify DCR configuration (just edit .tf file)
✅ State management and drift detection via Terraform
