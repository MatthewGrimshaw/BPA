# Agent & Extension Verification Checklist

Use this checklist to verify that VMs and SQL Servers have the correct agents installed and are properly configured for SQL Best Practice Assessment.

---

## Azure VMs – Required Agents & Extensions

### 1. SQL IaaS Agent Extension (SqlIaaSAgent)

**What it does**: Manages SQL Server on Azure VMs. Must be in **Full** management mode for BPA.

**How to verify**:
```powershell
# Check if SQL VM resource exists and is in Full mode
az sql vm show --resource-group <rg> --name <vm-name> --query "{name:name, managementMode:sqlManagement, provisioningState:provisioningState}" -o table
```

**Expected output**: `sqlManagement` should be `Full`, `provisioningState` should be `Succeeded`.

**If missing or in LightWeight mode**:
```powershell
# Register VM with SQL IaaS Extension in Full mode
az sql vm create --name <vm-name> --resource-group <rg> --location <location> --license-type PAYG --sql-mgmt-type Full
```

> **Warning**: Upgrading from LightWeight to Full mode may restart the SQL Server service. Schedule during a maintenance window.

### 2. Azure Monitor Agent (AMA)

**What it does**: Collects BPA CSV files and performance counters, sends them to Log Analytics via DCR.

**How to verify**:
```powershell
# Check AMA extension on Azure VM
az vm extension list --resource-group <rg> --vm-name <vm-name> --query "[?contains(type,'AzureMonitorWindowsAgent')].{name:name, provisioningState:provisioningState, type:type}" -o table
```

**Expected output**: Extension `AzureMonitorWindowsAgent` with `provisioningState` = `Succeeded`.

**If missing**: AMA is auto-installed when you associate a DCR with the VM. Ensure the BPA DCR association exists:
```powershell
az monitor data-collection rule association list --resource <vm-resource-id> --query "[].{name:name, ruleId:dataCollectionRuleId}" -o table
```

### 3. CustomScriptExtension (configure-sql)

**What it does**: Downloads and runs `configure-sql.ps1` from blob storage to set up databases and apply SQL misconfigurations for the lab.

**How to verify**:
```powershell
az vm extension list --resource-group <rg> --vm-name <vm-name> --query "[?name=='configure-sql'].{name:name, provisioningState:provisioningState}" -o table
```

---

## Arc-Enabled Servers – Required Agents & Extensions

### 1. Azure Connected Machine Agent (azcmagent)

**What it does**: Connects the server to Azure Arc for management.

**How to verify (on the server)**:
```powershell
azcmagent show
```

**Expected output**: Status should be `Connected`. Check `Resource Name`, `Resource Group`, `Subscription ID`.

**How to verify (from Azure)**:
```powershell
az connectedmachine show --resource-group <rg> --name <machine-name> --query "{name:name, status:status, provisioningState:provisioningState}" -o table
```

**Expected**: `status` = `Connected`, `provisioningState` = `Succeeded`.

**If missing**: Run `Install-AzureArcAgent-SqlBPA.ps1` with the required parameters (TenantId, SubscriptionId, ResourceGroupName, Location, ServicePrincipalClientId, ServicePrincipalSecret, WorkspaceId, WorkspaceKey).

### 2. SQL Server Arc Extension (WindowsAgent.SqlServer)

**What it does**: Auto-provisioned by Azure Arc once the Connected Machine Agent is installed on a server running SQL Server. Enables SQL-specific management features including BPA.

**How to verify**:
```powershell
az connectedmachine extension list --machine-name <machine-name> --resource-group <rg> --query "[?name=='WindowsAgent.SqlServer'].{name:name, provisioningState:provisioningState, type:type}" -o table
```

**Expected**: `provisioningState` = `Succeeded`.

**If missing**: The extension is auto-deployed when Arc detects SQL Server. If not appearing after 15 minutes:
1. Verify SQL Server is installed and the service is running.
2. Verify the Arc agent status is `Connected`.
3. Check the Arc agent logs: `C:\ProgramData\AzureConnectedMachineAgent\Log\azcmagent.log`.

### 3. Azure Monitor Agent (AMA) on Arc Machines

**How to verify**:
```powershell
az connectedmachine extension list --machine-name <machine-name> --resource-group <rg> --query "[?contains(type,'AzureMonitorWindowsAgent')].{name:name, provisioningState:provisioningState}" -o table
```

---

## DCR & DCE Associations – Required for Data Collection

Both Azure VMs and Arc machines need DCR and DCE associations to collect BPA data.

### Verify DCR associations:
```powershell
# For Azure VMs
az monitor data-collection rule association list --resource "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/virtualMachines/<vm-name>" -o table

# For Arc machines
az monitor data-collection rule association list --resource "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.HybridCompute/machines/<machine-name>" -o table
```

### Expected associations per machine:

| Association | Name Pattern | Purpose |
|-------------|-------------|---------|
| BPA DCR | `<vm-name>-bpa-dcr-association` | Collects BPA CSV assessment results |
| BPA DCE | `configurationAccessEndpoint` | Data upload endpoint for BPA |
| Perf DCR | `<vm-name>-perf-dcr-association` | Collects SQL Server performance counters |

### If DCR associations are missing:
```powershell
# Create DCR association for Azure VM
az monitor data-collection rule association create --name "<vm-name>-bpa-dcr-association" --resource "<vm-resource-id>" --rule-id "<dcr-resource-id>"

# Create DCE association (must use exact name)
az monitor data-collection rule association create --name "configurationAccessEndpoint" --resource "<vm-resource-id>" --data-collection-endpoint-id "<dce-resource-id>"
```

---

## SQL Server Service Account Requirements

The SQL Server service account must be a member of the **sysadmin** fixed server role for BPA to work correctly.

**How to verify** (run on the SQL Server):
```sql
SELECT sp.name, sp.type_desc, srl.role_principal_id
FROM sys.server_principals sp
JOIN sys.server_role_members srl ON sp.principal_id = srl.member_principal_id
WHERE srl.role_principal_id = SYSADMIN_ROLE_ID
```

---

## Quick Diagnostic Summary

Run this from your workstation to check all VMs in a resource group:

```powershell
$rg = "<resource-group>"

# Check Azure VMs
$vms = az vm list --resource-group $rg --query "[].name" -o tsv
foreach ($vm in $vms) {
    Write-Host "=== $vm ===" -ForegroundColor Cyan
    # SQL VM resource
    az sql vm show --resource-group $rg --name $vm --query "{sqlManagement:sqlManagement}" -o table 2>$null
    # Extensions
    az vm extension list --resource-group $rg --vm-name $vm --query "[].{name:name, state:provisioningState, type:type}" -o table
    # DCR associations
    $vmId = az vm show --resource-group $rg --name $vm --query id -o tsv
    az monitor data-collection rule association list --resource $vmId --query "[].{name:name}" -o table
}

# Check Arc machines
$arcMachines = az resource list --resource-group $rg --resource-type "Microsoft.HybridCompute/machines" --query "[].name" -o tsv
foreach ($machine in $arcMachines) {
    Write-Host "=== $machine (Arc) ===" -ForegroundColor Cyan
    az connectedmachine show --resource-group $rg --name $machine --query "{status:status}" -o table
    az connectedmachine extension list --machine-name $machine --resource-group $rg --query "[].{name:name, state:provisioningState, type:type}" -o table
}
```
