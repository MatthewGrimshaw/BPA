<#
.SYNOPSIS
    Registers one or more Azure VMs running SQL Server with the SQL IaaS Agent
    Extension and enables the SQL Best Practices Assessment feature.

.DESCRIPTION
    This script is designed to be run from your local workstation — it pushes
    configuration to the VMs via the Azure control plane.  It does NOT need to
    be executed from inside the VMs.

    Prerequisites that must exist before running this script:
      - The Microsoft.SqlVirtualMachine resource provider must be registered
        (typically done via Terraform / IaC).
      - The target Log Analytics workspace must already exist
        (typically created via Terraform / IaC).

    The script:
      1. Validates the Microsoft.SqlVirtualMachine provider is registered.
      2. Validates the Log Analytics workspace exists.
      3. For each VM: registers (or updates) the SQL VM resource with the
         SQL IaaS Agent Extension in Full management mode.
      4. For each VM: enables the SQL Best Practices Assessment, with an
         optional weekly schedule.

.PARAMETER SubscriptionId
    The Azure subscription ID that contains the SQL Server VM(s).

.PARAMETER ResourceGroupName
    The resource group that contains the SQL Server VM(s).

.PARAMETER VmNames
    One or more Azure VM names running SQL Server.
    Accepts a single name or an array of names for bulk enablement.

.PARAMETER Location
    The Azure region of the VM(s) (e.g. 'eastus', 'swedencentral').

.PARAMETER SqlLicenseType
    The SQL Server license type. Accepted values: PAYG, AHUB, DR.
    Default: PAYG.

.PARAMETER WorkspaceResourceGroupName
    The resource group for the Log Analytics workspace. Defaults to
    ResourceGroupName if not specified.

.PARAMETER WorkspaceName
    The name of the Log Analytics workspace used for assessment results.
    Must already exist.

.PARAMETER EnableAssessmentSchedule
    When specified, a weekly assessment schedule is configured.

.PARAMETER ScheduleDayOfWeek
    Day of the week for the scheduled assessment. Default: Sunday.

.PARAMETER ScheduleStartTime
    Start time for the scheduled assessment (24-hour format, e.g. '02:00').
    Default: '02:00'.

.PARAMETER ScheduleWeeklyInterval
    Interval in weeks between scheduled assessments. Default: 1.

.EXAMPLE
    # Enable BPA on a single VM
    .\Install-SqlIaaSExtension-BPA.ps1 `
        -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ResourceGroupName "rg-sql-vms" `
        -VmNames "sql-vm-01" `
        -Location "eastus" `
        -WorkspaceName "law-sql-bpa"

.EXAMPLE
    # Enable BPA on multiple VMs at once
    .\Install-SqlIaaSExtension-BPA.ps1 `
        -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ResourceGroupName "rg-sql-vms" `
        -VmNames "sql-vm-01","sql-vm-02","sql-vm-03" `
        -Location "eastus" `
        -WorkspaceName "law-sql-bpa"

.EXAMPLE
    # Enable BPA with a weekly Monday 03:00 schedule on multiple VMs
    .\Install-SqlIaaSExtension-BPA.ps1 `
        -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ResourceGroupName "rg-sql-vms" `
        -VmNames "sql-vm-01","sql-vm-02" `
        -Location "eastus" `
        -WorkspaceName "law-sql-bpa" `
        -EnableAssessmentSchedule `
        -ScheduleDayOfWeek "Monday" `
        -ScheduleStartTime "03:00"

.NOTES
    This script runs from your local workstation — all operations use the
    Azure control plane (Az PowerShell modules). No RDP or local execution
    on the VM is required.

    Prerequisites:
      - Az PowerShell modules (Az.Accounts, Az.SqlVirtualMachine,
        Az.OperationalInsights, Az.Resources).
      - Microsoft.SqlVirtualMachine resource provider must be registered
        (e.g. via Terraform).
      - The Log Analytics workspace must already exist (e.g. via Terraform).
      - Permissions: SQL Virtual Machine Contributor or Contributor on the
        VM's resource group; Log Analytics Reader on the workspace.
      - The VM(s) must be running SQL Server 2012 or later.
      - Full management mode may restart the SQL Server service.

    References:
      - https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/sql-server-iaas-agent-extension-automate-management
      - https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/sql-assessment-for-sql-vm
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string[]]$VmNames,

    [Parameter(Mandatory)]
    [string]$Location,

    [Parameter()]
    [ValidateSet('PAYG', 'AHUB', 'DR')]
    [string]$SqlLicenseType = 'PAYG',

    [Parameter()]
    [string]$WorkspaceResourceGroupName,

    [Parameter(Mandatory)]
    [string]$WorkspaceName,

    [Parameter()]
    [bool]$EnableAssessmentSchedule = $true,

    [Parameter()]
    [ValidateSet('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')]
    [string]$ScheduleDayOfWeek = 'Sunday',

    [Parameter()]
    [string]$ScheduleStartTime = '02:00',

    [Parameter()]
    [ValidateRange(1, 6)]
    [int]$ScheduleWeeklyInterval = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Helper functions ────────────────────────────────────────────────────

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Install-RequiredModules {
    $modules = @(
        'Az.Accounts',
        'Az.Resources',
        'Az.SqlVirtualMachine',
        'Az.OperationalInsights'
    )
    foreach ($mod in $modules) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            Write-Host "  Installing PowerShell module: $mod" -ForegroundColor Yellow
            Install-Module -Name $mod -Repository PSGallery -Force -AllowClobber -Scope CurrentUser
        }
        Import-Module -Name $mod -Force
    }
}

#endregion

#region ── Main ────────────────────────────────────────────────────────────────

# Default workspace resource group to the VM's resource group
if (-not $WorkspaceResourceGroupName) {
    $WorkspaceResourceGroupName = $ResourceGroupName
}

# ── Step 1: Install required PowerShell modules ──────────────────────────────
Write-Step 'Installing required PowerShell modules'
Install-RequiredModules

# ── Step 2: Authenticate to Azure ────────────────────────────────────────────
Write-Step 'Connecting to Azure'
$context = Get-AzContext
if (-not $context -or $context.Subscription.Id -ne $SubscriptionId) {
    $connectParams = @{ Subscription = $SubscriptionId }
    if ($TenantId) { $connectParams['TenantId'] = $TenantId }
    Connect-AzAccount @connectParams | Out-Null
} else {
    Set-AzContext -Subscription $SubscriptionId | Out-Null
}
Write-Host "  Using subscription: $SubscriptionId" -ForegroundColor Green

# ── Step 3: Validate the Microsoft.SqlVirtualMachine resource provider ───────
Write-Step 'Checking Microsoft.SqlVirtualMachine resource provider'
$providerState = (Get-AzResourceProvider -ProviderNamespace 'Microsoft.SqlVirtualMachine').RegistrationState |
    Select-Object -First 1
if ($providerState -ne 'Registered') {
    Write-Warning "Microsoft.SqlVirtualMachine provider is NOT registered (state: $providerState). Register it via Terraform or: Register-AzResourceProvider -ProviderNamespace 'Microsoft.SqlVirtualMachine'"
    exit 1
}
Write-Host '  Microsoft.SqlVirtualMachine is registered.' -ForegroundColor Green

# ── Step 4: Validate the Log Analytics workspace exists ──────────────────────
Write-Step "Validating Log Analytics workspace '$WorkspaceName'"
$workspace = Get-AzOperationalInsightsWorkspace `
    -ResourceGroupName $WorkspaceResourceGroupName `
    -Name $WorkspaceName `
    -ErrorAction SilentlyContinue

if ($null -eq $workspace) {
    Write-Warning "Log Analytics workspace '$WorkspaceName' not found in resource group '$WorkspaceResourceGroupName'. Create it via Terraform or the Azure portal before running this script."
    exit 1
}
Write-Host "  Workspace '$WorkspaceName' found." -ForegroundColor Green

# ── Step 5: Process each VM ──────────────────────────────────────────────────
$totalVms = $VmNames.Count
$successCount = 0
$failedVms = @()

Write-Step "Processing $totalVms VM(s): $($VmNames -join ', ')"

foreach ($VmName in $VmNames) {
    Write-Host "`n────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  [$($VmNames.IndexOf($VmName) + 1)/$totalVms] Processing VM: $VmName" -ForegroundColor Cyan

    try {
        # ── Register VM with the SQL IaaS Agent Extension (Full mode) ────────
        $existingSqlVm = Get-AzSqlVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction SilentlyContinue

        if ($null -eq $existingSqlVm) {
            Write-Host "    SQL VM resource not found. Creating with Full management mode..." -ForegroundColor Yellow
            New-AzSqlVM `
                -ResourceGroupName $ResourceGroupName `
                -Name $VmName `
                -Location $Location `
                -LicenseType $SqlLicenseType `
                -SqlManagementType Full | Out-Null
            Write-Host '    SQL VM resource created in Full mode.' -ForegroundColor Green
        } else {
            if ($existingSqlVm.SqlManagement -ne 'Full') {
                Write-Host "    Upgrading to Full management mode (current: $($existingSqlVm.SqlManagement))..." -ForegroundColor Yellow
                Write-Warning "    Upgrading to Full mode may restart the SQL Server service on $VmName."
                Update-AzSqlVM `
                    -ResourceGroupName $ResourceGroupName `
                    -Name $VmName `
                    -SqlManagementType Full | Out-Null
                Write-Host '    Management mode updated to Full.' -ForegroundColor Green
            } else {
                Write-Host '    SQL VM already in Full management mode.' -ForegroundColor Green
            }
        }

        # ── Enable SQL Best Practices Assessment via Azure CLI ──────────────
        # The az sql vm update CLI supports workspace linking in a single call
        Write-Host "    Enabling assessment and linking workspace..." -ForegroundColor Yellow

        $cliArgs = @(
            'sql', 'vm', 'update',
            '-n', $VmName,
            '-g', $ResourceGroupName,
            '--enable-assessment', 'true',
            '--workspace-name', $WorkspaceName,
            '--workspace-rg', $WorkspaceResourceGroupName,
            '--agent-rg', $ResourceGroupName
        )

        if ($EnableAssessmentSchedule) {
            Write-Host "    Schedule: $ScheduleDayOfWeek at $ScheduleStartTime (every $ScheduleWeeklyInterval week(s))." -ForegroundColor Yellow
            $cliArgs += '--enable-assessment-schedule', 'true'
            $cliArgs += '--assessment-day-of-week', $ScheduleDayOfWeek
            $cliArgs += '--assessment-start-time-local', $ScheduleStartTime
            $cliArgs += '--assessment-weekly-interval', $ScheduleWeeklyInterval.ToString()
        }

        $cliResult = az @cliArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "az sql vm update failed: $cliResult"
        }
        Write-Host "    Assessment enabled and workspace linked." -ForegroundColor Green

        Write-Host "    BPA enabled successfully on $VmName." -ForegroundColor Green
        $successCount++
    }
    catch {
        Write-Host "    FAILED on $VmName : $_" -ForegroundColor Red
        $failedVms += $VmName
    }
}

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Host "`n════════════════════════════════════════════════════════════════" -ForegroundColor Cyan

if ($failedVms.Count -gt 0) {
    Write-Host "[DONE] $successCount/$totalVms VM(s) completed successfully." -ForegroundColor Yellow
    Write-Host "FAILED VM(s): $($failedVms -join ', ')" -ForegroundColor Red
} else {
    Write-Host "[DONE] $successCount/$totalVms VM(s) completed successfully." -ForegroundColor Green
}

if ($successCount -gt 0) {
    Write-Host "`nAssessment results will appear in Log Analytics workspace: $WorkspaceName" -ForegroundColor Green
    Write-Host "Review results in the Azure portal:" -ForegroundColor Green
    foreach ($VmName in $VmNames) {
        if ($VmName -notin $failedVms) {
            Write-Host "  $VmName : https://portal.azure.com/#resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachines/$VmName/sqlBestPracticesAssessment" -ForegroundColor DarkCyan
        }
    }
}

#endregion
