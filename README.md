# BPA – SQL Best Practice Assessment Deployment Scripts

This repository contains PowerShell scripts that automate the deployment of
**Azure SQL Best Practices Assessment** for SQL Server workloads running on
Azure VMs or on-premises / multi-cloud servers connected via Azure Arc.

---

## Scripts

### 1. `Install-AzureArcAgent-SqlBPA.ps1`

Installs the **Azure Connected Machine (Arc) Agent** on a Windows server that
is running SQL Server, connects it to Azure Arc, and enables the
**SQL Best Practices Assessment** via the SQL Server – Azure Arc extension.

Use this script when the SQL Server is running on a **non-Azure VM** (on-premises,
another cloud provider, etc.) or when you want to manage SQL Server through the
Azure Arc experience.

#### Prerequisites

| Requirement | Details |
|---|---|
| OS | Windows Server 2012 R2 or later |
| Privileges | Local Administrator on the target server |
| Network | Outbound HTTPS (port 443) to Azure endpoints |
| PowerShell modules | Az.Accounts, Az.ConnectedMachine, Az.ArcData, Az.Resources (auto-installed) |
| Service principal | Needs **Azure Connected Machine Onboarding** role on the resource group |
| Log Analytics workspace | Pre-created or pass an existing resource ID |

#### Usage

```powershell
.\Install-AzureArcAgent-SqlBPA.ps1 `
    -TenantId              "<tenant-id>" `
    -SubscriptionId        "<subscription-id>" `
    -ResourceGroupName     "rg-arc-sql" `
    -Location              "eastus" `
    -ServicePrincipalClientId  "<sp-client-id>" `
    -ServicePrincipalSecret    "<sp-secret>" `
    -WorkspaceId           "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>" `
    -WorkspaceKey          "<workspace-primary-key>"
```

Optional parameters:
- `-MachineName` – override the Arc resource name (defaults to `$env:COMPUTERNAME`).
- `-ProxyUrl` – HTTPS proxy URL for the agent (e.g. `https://proxy.contoso.com:8080`).

#### What the script does

1. Installs required Az PowerShell modules.
2. Authenticates to Azure via the provided service principal.
3. Registers `Microsoft.HybridCompute`, `Microsoft.GuestConfiguration`,
   `Microsoft.AzureArcData`, and `Microsoft.OperationalInsights` resource providers.
4. Downloads and installs the Azure Connected Machine Agent MSI.
5. Runs `azcmagent connect` to register the server with Azure Arc.
6. Waits for the SQL Server Arc extension (`WindowsAgent.SqlServer`) to be
   auto-provisioned.
7. Enables SQL Best Practices Assessment via the Arc-enabled SQL Server resource.

---

### 2. `Install-SqlIaaSExtension-BPA.ps1`

Registers an **Azure VM** running SQL Server with the
**SQL Server IaaS Agent Extension** (Full mode) and enables the
**SQL Best Practices Assessment** feature with an optional recurring schedule.

Use this script when the SQL Server is already running on an **Azure VM** and
you want to use the SQL IaaS Extension–based management experience.

#### Prerequisites

| Requirement | Details |
|---|---|
| SQL Server version | SQL Server 2012 or later |
| Azure VM | Must already exist in Azure |
| Permissions | SQL Virtual Machine Contributor (or Contributor) on the VM's resource group; Log Analytics Contributor on the workspace resource group |
| PowerShell modules | Az.Accounts, Az.Resources, Az.SqlVirtualMachine, Az.OperationalInsights (auto-installed) |
| SQL service account | Must be a member of the **sysadmin** fixed server role |

> **Note:** Upgrading to Full management mode may restart the SQL Server
> service. Schedule this operation during a maintenance window.

#### Usage

```powershell
# Enable IaaS extension + assessment (on-demand runs only)
.\Install-SqlIaaSExtension-BPA.ps1 `
    -SubscriptionId    "<subscription-id>" `
    -ResourceGroupName "rg-sql-vms" `
    -VmName            "sql-vm-01" `
    -Location          "eastus" `
    -WorkspaceName     "law-sql-bpa"
```

```powershell
# Enable IaaS extension + assessment with a weekly Monday 03:00 schedule
.\Install-SqlIaaSExtension-BPA.ps1 `
    -SubscriptionId          "<subscription-id>" `
    -ResourceGroupName       "rg-sql-vms" `
    -VmName                  "sql-vm-01" `
    -Location                "eastus" `
    -WorkspaceName           "law-sql-bpa" `
    -EnableAssessmentSchedule `
    -ScheduleDayOfWeek       "Monday" `
    -ScheduleStartTime       "03:00" `
    -ScheduleWeeklyInterval  1
```

Optional parameters:
- `-SqlLicenseType` – `PAYG` (default), `AHUB`, or `DR`.
- `-WorkspaceResourceGroupName` – resource group for the Log Analytics workspace
  (defaults to `-ResourceGroupName`).
- `-EnableAssessmentSchedule` – switch to configure a recurring schedule.
- `-ScheduleDayOfWeek` – day of the week (default: `Sunday`).
- `-ScheduleStartTime` – 24-hour time string (default: `02:00`).
- `-ScheduleWeeklyInterval` – weeks between runs (default: `1`).

#### What the script does

1. Installs required Az PowerShell modules.
2. Connects to the specified Azure subscription.
3. Registers the `Microsoft.SqlVirtualMachine` resource provider.
4. Creates or upgrades the SQL VM resource in **Full** management mode
   (installs the IaaS Agent Extension on the VM).
5. Creates the Log Analytics workspace if it does not already exist.
6. Enables SQL Best Practices Assessment and links it to the workspace.
7. Optionally configures a recurring assessment schedule.
8. Triggers an immediate assessment run.

---

## Viewing Assessment Results

After the scripts complete, assessment results are available in:

- **Azure portal → SQL Virtual Machines → \<your VM\> → SQL best practices assessment**
- **Azure portal → Log Analytics workspace → Logs** – query the
  `SQLAssessmentRecommendation` table.

---

## References

- [SQL Server IaaS Agent Extension](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/sql-server-iaas-agent-extension-automate-management)
- [SQL Best Practices Assessment for SQL Server on Azure VMs](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/sql-assessment-for-sql-vm)
- [Connect hybrid machines to Azure using PowerShell (Azure Arc)](https://learn.microsoft.com/azure/azure-arc/servers/onboard-powershell)
- [SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/overview)
