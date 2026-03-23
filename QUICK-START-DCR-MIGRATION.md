# Quick Start: DCR/DCE Migration to Terraform

## What Changed

All Data Collection Rules (DCR) and Data Collection Endpoints (DCE) are now managed by Terraform instead of being auto-created by PowerShell scripts.

## New Terraform Resources

**File: `terraform/bpa-assessment-dcr.tf`**
- `azurerm_monitor_data_collection_endpoint.bpa_assessment` - BPA DCE
- `azurerm_monitor_data_collection_rule.bpa_assessment` - BPA DCR with both IaaS and Extension Agent CSV paths
- `azurerm_monitor_data_collection_rule_association.bpa_azure_vms[0-4]` - Associates BPA DCR with Azure VMs
- `azurerm_monitor_data_collection_rule_association.bpa_dce_azure_vms[0-4]` - Associates BPA DCE with Azure VMs

**File: `terraform/performance-counters-dcr.tf`**
- `azurerm_monitor_data_collection_endpoint.perf_counters` - Performance counter DCE
- `azurerm_monitor_data_collection_rule.sql_perf_counters` - Performance counter DCR
- `azurerm_monitor_data_collection_rule_association.sql_vms_perf[0-4]` - Associates perf DCR with Azure VMs

## Total Resources Created by Terraform

| Type | Count | Purpose |
|------|-------|---------|
| Data Collection Endpoints (DCE) | 2 | BPA + Performance Counters |
| Data Collection Rules (DCR) | 2 | BPA + Performance Counters |
| DCR Associations (Azure VMs) | 10 | 2 DCRs × 5 VMs |
| DCE Associations (Azure VMs) | 5 | BPA DCE × 5 VMs |

**Arc machine associations** are still created by PowerShell (dynamic, can't be known at Terraform plan time).

## For Existing Deployments - IMPORT WORKFLOW

### Step 1: Import Existing Resources
```powershell
# From the BPA directory
.\Import-DcrDceToTerraform.ps1
```

This will:
- Find your existing BPA DCR and DCE
- Import them into Terraform state
- Preserve existing configuration

### Step 2: Verify No Destructive Changes
```powershell
cd terraform
terraform plan
```

**Expected output:** Minor formatting changes, no destroys/recreates

### Step 3: Apply Terraform
```powershell
terraform apply
```

This brings resources under Terraform management.

### Step 4: Future Deployments
From now on, `terraform apply` manages everything. PowerShell scripts will reference Terraform-created resources.

## For New Deployments - CLEAN START

Simply run:
```powershell
cd terraform
terraform init
terraform plan
terraform apply

cd ..
.\Create-LabEnvironment.ps1
```

Terraform creates all DCR/DCE, PowerShell uses them and associates Arc machines.

## Key Files Modified

### `Create-LabEnvironment.ps1`
**Removed:**
- DCR update logic (lines ~200-250) - no longer needed, Terraform creates with correct config
- Auto-creation of DCR/DCE - references Terraform resources instead

**Added:**
- Logic to find Terraform-created DCR/DCE by name pattern
- Error checking if Terraform resources don't exist

### `terraform/bpa-assessment-dcr.tf` (NEW)
- Defines BPA DCR with both IaaS Agent and Extension Agent CSV paths
- Includes all associations for Azure VMs
- Matches the configuration previously created by PowerShell

### `terraform/performance-counters-dcr.tf` (NEW)
- Defines performance counter DCR with 34 SQL Server counters
- Separate DCE for performance data
- Already configured correctly

## Troubleshooting

### "BPA DCR or DCE not found"
**Cause:** Terraform hasn't created the resources yet.
**Fix:** Run `cd terraform && terraform apply`

### "Resource already exists"
**Cause:** Existing resources not imported.
**Fix:** Run `.\Import-DcrDceToTerraform.ps1`

### Terraform wants to destroy/recreate DCR
**Cause:** Configuration mismatch between Terraform and existing resource.
**Fix Options:**
1. **Preferred:** Adjust Terraform config to match existing resource
2. **Alternative:** Remove existing resource from Azure, let Terraform create new one
3. **Last resort:** Import with different resource name pattern

### Association conflicts
**Cause:** PowerShell tried to create associations that Terraform also creates.
**Fix:** Import the associations or let Terraform recreate them (harmless).

## Benefits

✅ **Version Control** - All DCR/DCE configuration in Git
✅ **Repeatability** - `terraform apply` creates consistent infrastructure  
✅ **Easy Updates** - Edit .tf files, run `terraform apply`
✅ **Drift Detection** - `terraform plan` shows any manual changes
✅ **State Management** - Terraform tracks all resources
✅ **Better Testing** - Deploy/destroy test environments easily

## See Also

- [docs/DCR-DCE-MIGRATION.md](docs/DCR-DCE-MIGRATION.md) - Detailed migration guide
- [docs/PERFORMANCE-COUNTERS.md](docs/PERFORMANCE-COUNTERS.md) - Performance counter documentation
- [docs/CREATING-ALERTS.md](docs/CREATING-ALERTS.md) - Alert setup guide
