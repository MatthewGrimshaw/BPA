<#
.SYNOPSIS
    Registers an Azure VM running SQL Server with the SQL Server IaaS Agent
    Extension and enables the SQL Best Practices Assessment feature.

.DESCRIPTION
    This script:
      1. Registers the Microsoft.SqlVirtualMachine resource provider.
      2. Registers (or updates) the SQL Server VM with the SQL IaaS Agent
         Extension in Full management mode.
      3. Creates or validates the target Log Analytics workspace.
      4. Enables the SQL Best Practices Assessment, with an optional weekly
         schedule.

    The SQL IaaS Agent Extension provides automated patching, automated backup,
    Azure Key Vault integration, and SQL best practices assessment. Full mode
    is required for the assessment feature.

    Run this script from any machine that has the Az PowerShell module installed
    and the necessary permissions.

.PARAMETER SubscriptionId
    The Azure subscription ID that contains the SQL Server VM.

.PARAMETER ResourceGroupName
    The resource group that contains the SQL Server VM.

.PARAMETER VmName
    The name of the Azure VM running SQL Server.

.PARAMETER Location
    The Azure region of the VM (e.g. 'eastus', 'westeurope').

.PARAMETER SqlLicenseType
    The SQL Server license type. Accepted values: PAYG, AHUB, DR.
    Default: PAYG.

.PARAMETER WorkspaceResourceGroupName
    The resource group for the Log Analytics workspace. Defaults to
    ResourceGroupName if not specified.

.PARAMETER WorkspaceName
    The name of the Log Analytics workspace used for assessment results.
    If the workspace does not exist it will be created.

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
    # Enable the IaaS extension and assessment with defaults
    .\Install-SqlIaaSExtension-BPA.ps1 `
        -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ResourceGroupName "rg-sql-vms" `
        -VmName "sql-vm-01" `
        -Location "eastus" `
        -WorkspaceName "law-sql-bpa"

.EXAMPLE
    # Enable the IaaS extension, assessment, and a weekly Monday 03:00 schedule
    .\Install-SqlIaaSExtension-BPA.ps1 `
        -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ResourceGroupName "rg-sql-vms" `
        -VmName "sql-vm-01" `
        -Location "eastus" `
        -WorkspaceName "law-sql-bpa" `
        -EnableAssessmentSchedule `
        -ScheduleDayOfWeek "Monday" `
        -ScheduleStartTime "03:00"

.NOTES
    Prerequisites:
      - Az PowerShell module (Az.Accounts, Az.SqlVirtualMachine,
        Az.OperationalInsights, Az.Resources).
      - Permissions: SQL Virtual Machine Contributor or Contributor on the VM's
        resource group; Log Analytics Contributor on the workspace resource group.
      - The VM must be running SQL Server 2012 or later.
      - The SQL Server service account must be a member of the sysadmin role.
      - Full management mode may restart the SQL Server service; schedule
        accordingly.
    
    References:
      - https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/sql-server-iaas-agent-extension-automate-management
      - https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/sql-assessment-for-sql-vm
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$VmName,

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
    [switch]$EnableAssessmentSchedule,

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
# If already connected and the correct subscription is active, this is a no-op.
$context = Get-AzContext
if (-not $context -or $context.Subscription.Id -ne $SubscriptionId) {
    Connect-AzAccount -Subscription $SubscriptionId | Out-Null
} else {
    Set-AzContext -Subscription $SubscriptionId | Out-Null
}
Write-Host "  Using subscription: $SubscriptionId" -ForegroundColor Green

# ── Step 3: Register the SQL Virtual Machine resource provider ───────────────
Write-Step 'Registering the Microsoft.SqlVirtualMachine resource provider'
$providerState = (Get-AzResourceProvider -ProviderNamespace 'Microsoft.SqlVirtualMachine').RegistrationState |
    Select-Object -First 1
if ($providerState -ne 'Registered') {
    Register-AzResourceProvider -ProviderNamespace 'Microsoft.SqlVirtualMachine' | Out-Null
    Write-Host '  Resource provider registered. Waiting for registration to complete...' -ForegroundColor Yellow

    # Poll until the registration is complete (usually takes <1 minute)
    do {
        Start-Sleep -Seconds 15
        $providerState = (Get-AzResourceProvider -ProviderNamespace 'Microsoft.SqlVirtualMachine').RegistrationState |
            Select-Object -First 1
    } while ($providerState -eq 'Registering')

    Write-Host "  Provider state: $providerState" -ForegroundColor Green
} else {
    Write-Host '  Microsoft.SqlVirtualMachine already registered.' -ForegroundColor Green
}

# ── Step 4: Register VM with the SQL IaaS Agent Extension (Full mode) ────────
Write-Step "Registering '$VmName' with the SQL IaaS Agent Extension (Full mode)"

$existingSqlVm = Get-AzSqlVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction SilentlyContinue

if ($null -eq $existingSqlVm) {
    Write-Host "  SQL VM resource not found. Creating with Full management mode..." -ForegroundColor Yellow
    New-AzSqlVM `
        -ResourceGroupName $ResourceGroupName `
        -Name $VmName `
        -Location $Location `
        -LicenseType $SqlLicenseType `
        -SqlManagementType Full | Out-Null
    Write-Host '  SQL VM resource created in Full mode.' -ForegroundColor Green
} else {
    Write-Host "  Existing SQL VM resource found (management type: $($existingSqlVm.SqlManagementType))." -ForegroundColor Yellow
    if ($existingSqlVm.SqlManagementType -ne 'Full') {
        Write-Host '  Upgrading to Full management mode...' -ForegroundColor Yellow
        Write-Warning 'Upgrading to Full mode may restart the SQL Server service.'
        Update-AzSqlVM `
            -ResourceGroupName $ResourceGroupName `
            -Name $VmName `
            -SqlManagementType Full | Out-Null
        Write-Host '  Management mode updated to Full.' -ForegroundColor Green
    } else {
        Write-Host '  SQL VM is already in Full management mode.' -ForegroundColor Green
    }
}

# ── Step 5: Create or retrieve the Log Analytics workspace ───────────────────
Write-Step "Ensuring Log Analytics workspace '$WorkspaceName' exists"

$workspace = Get-AzOperationalInsightsWorkspace `
    -ResourceGroupName $WorkspaceResourceGroupName `
    -Name $WorkspaceName `
    -ErrorAction SilentlyContinue

if ($null -eq $workspace) {
    Write-Host "  Workspace not found. Creating '$WorkspaceName' in '$WorkspaceResourceGroupName'..." -ForegroundColor Yellow
    $workspace = New-AzOperationalInsightsWorkspace `
        -ResourceGroupName $WorkspaceResourceGroupName `
        -Name $WorkspaceName `
        -Location $Location `
        -Sku PerGB2018
    Write-Host '  Log Analytics workspace created.' -ForegroundColor Green
} else {
    Write-Host "  Log Analytics workspace '$WorkspaceName' already exists." -ForegroundColor Green
}

# ── Step 6: Enable SQL Best Practices Assessment ──────────────────────────────
Write-Step 'Enabling SQL Best Practices Assessment'

if ($EnableAssessmentSchedule) {
    Write-Host "  Enabling assessment with a weekly schedule: $ScheduleDayOfWeek at $ScheduleStartTime (every $ScheduleWeeklyInterval week(s))." -ForegroundColor Yellow

    Update-AzSqlVM `
        -ResourceGroupName $ResourceGroupName `
        -Name $VmName `
        -AssessmentSettingEnable $true `
        -AssessmentSettingRunImmediately $true `
        -ScheduleEnable $true `
        -ScheduleDayOfWeek $ScheduleDayOfWeek `
        -ScheduleStartTime $ScheduleStartTime `
        -ScheduleWeeklyInterval $ScheduleWeeklyInterval `
        -WorkspaceId $workspace.CustomerId.ToString() `
        -WorkspaceKey (Get-AzOperationalInsightsWorkspaceSharedKey `
            -ResourceGroupName $WorkspaceResourceGroupName `
            -Name $WorkspaceName).PrimarySharedKey | Out-Null
} else {
    Write-Host '  Enabling assessment (no schedule – run on-demand from the Azure portal).' -ForegroundColor Yellow

    Update-AzSqlVM `
        -ResourceGroupName $ResourceGroupName `
        -Name $VmName `
        -AssessmentSettingEnable $true `
        -AssessmentSettingRunImmediately $true `
        -WorkspaceId $workspace.CustomerId.ToString() `
        -WorkspaceKey (Get-AzOperationalInsightsWorkspaceSharedKey `
            -ResourceGroupName $WorkspaceResourceGroupName `
            -Name $WorkspaceName).PrimarySharedKey | Out-Null
}

Write-Host '  SQL Best Practices Assessment enabled successfully.' -ForegroundColor Green
Write-Host "  Assessment results will appear in Log Analytics workspace: $WorkspaceName" -ForegroundColor Green
Write-Host '  Results will be available in the Azure portal under your SQL VM > SQL best practices assessment.' -ForegroundColor Green

Write-Host "`n[DONE] SQL IaaS Extension installation and SQL Best Practices Assessment setup complete." -ForegroundColor Cyan
Write-Host "       Review assessment results in the Azure portal:" -ForegroundColor Cyan
Write-Host "       https://portal.azure.com/#resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachines/$VmName/sqlBestPracticesAssessment" -ForegroundColor Cyan

#endregion
