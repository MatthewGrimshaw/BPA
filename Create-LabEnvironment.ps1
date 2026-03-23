# Read variables from terraform.tfvars
$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
$tfvarsPath = Join-Path $scriptRoot "terraform" "terraform.tfvars"
if (-not (Test-Path $tfvarsPath)) {
    Write-Error "terraform.tfvars not found at $tfvarsPath. Copy terraform.tfvars.example and fill in your values."
    exit 1
}


$tfvars = @{}
Get-Content $tfvarsPath | ForEach-Object {
    if ($_ -match '^\s*(\w+)\s*=\s*"([^"]*)"') {
        $tfvars[$Matches[1]] = $Matches[2]
    }
}

$AZURE_TENANT_ID                      = $tfvars['tenant_id']
$AZURE_SUBSCRIPTION_ID                = $tfvars['subscription_id']
$BACKEND_AZURE_RESOURCE_GROUP_NAME    = $tfvars['backend_resource_group_name']
$BACKEND_AZURE_STORAGE_ACCOUNT_NAME   = $tfvars['backend_storage_account_name']
$BACKEND_AZURE_STORAGE_CONTAINER_NAME = $tfvars['backend_storage_container_name']
$PREFIX                               = $tfvars['prefix']
$LOCATION                             = $tfvars['location']

# authenticate to azure and set the subscription context
az login --tenant $AZURE_TENANT_ID
az account set --subscription $AZURE_SUBSCRIPTION_ID

# set terraform directory
if ((Split-Path -Leaf (Get-Location)).ToLower() -ne "terraform") {
    Write-Host "Changing directory to .\terraform"
    Set-Location -Path (Join-Path $scriptRoot "terraform")
}

# initialise and run terraform
terraform init -backend-config="storage_account_name=$BACKEND_AZURE_STORAGE_ACCOUNT_NAME" `
               -backend-config="container_name=$BACKEND_AZURE_STORAGE_CONTAINER_NAME" `
               -backend-config="key=bpa.tfstate" `
               -backend-config="subscription_id=$AZURE_SUBSCRIPTION_ID" `
               -backend-config="resource_group_name=$BACKEND_AZURE_RESOURCE_GROUP_NAME" 
terraform fmt -recursive
terraform validate
terraform plan
terraform apply -auto-approve





#### Install SQL IaaS Agent Extension and enable BPA with AMA

# Set directory back to script root if currently in terraform directory
If(((Get-Location).Path).Split('\')[-1] -eq "terraform") {
    Write-Host "Changing directory to $scriptRoot"
    cd ..
}

# Enable SQL BPA with AMA on all Azure VMs using the Install-SqlIaaSExtension-BPA.ps1 script
# This handles: SQL VM creation (if needed), Full mode, assessment, schedule, AMA + DCR/DCE, workspace linking
$azureVmNames = @("sql-bpa-01","sql-bpa-02","sql-bpa-03","sql-bpa-04","sql-bpa-05")

.\Install-SqlIaaSExtension-BPA.ps1 `
    -SubscriptionId $AZURE_SUBSCRIPTION_ID `
    -TenantId $AZURE_TENANT_ID `
    -ResourceGroupName "$PREFIX-rg" `
    -VmNames $azureVmNames `
    -Location $terraform apply -auto-approveLOCATION `
    -WorkspaceName "$PREFIX-law"

### Create Hyper-V environment with SQL Servers

# How to get the ISOs (Visual Studio subscription):

# Go to my.visualstudio.com/Downloads
# Download Windows Server 2022 and/or Windows Server 2019 ISOs
# Download SQL Server 2022 Developer and/or SQL Server 2019 Developer ISOs
# Place the ISOs in C:\ISOs (or update the paths in the $vms variable below)
# Use the license keys from the Visual Studio subscription (also found on my.visualstudio.com) to create the VMs. The keys are stored in hyper-v\license-keys.ps1, which is dot-sourced in the script below.



# Source your keys
. .\hyper-v\license-keys.ps1

$vms = @(
    @{
        Name       = "arc-sql-01"
        WindowsIso = "C:\ISO\en-us_windows_server_2022_updated_march_2026_x64_dvd_3f772967.iso"
        SqlIso     = "C:\ISO\enu_sql_server_2022_developer_edition_x64_dvd_7cacf733.iso"
        WindowsProductKey = $LicenseKeys.WindowsServer2022
        Databases  = "adventureworks,misconfigdemo"
        Misconfigs = "maxmem_default,maxdop_zero,auto_shrink,no_adhoc_opt"
    },
    @{
        Name       = "arc-sql-02"
        WindowsIso = "C:\ISO\en_windows_server_2019_updated_march_2021_x64_dvd_ec2626a1.iso"
        SqlIso     = "C:\ISO\en_sql_server_2019_developer_x64_dvd_baea4195.iso"
        WindowsProductKey = $LicenseKeys.WindowsServer2019
        Databases  = "adventureworks,worldwideimporters"
        Misconfigs = "maxmem_default,ctp_default,page_verify_none,filegrowth_pct"
    }
)
.\hyper-v\Create-HyperVLab.ps1 -VmConfigs $vms


## troubleshooting tips & remove hyper-v lab if needed
#Stop-VM -Name arc-sql-01 -TurnOff -Force -ErrorAction SilentlyContinue
#Remove-VM -Name arc-sql-01 -Force -ErrorAction SilentlyContinue
#Dismount-VHD -Path "C:\HyperVLab\arc-sql-01\arc-sql-01.vhdx" -ErrorAction SilentlyContinue
#Dismount-DiskImage -ImagePath "C:\ISO\en-us_windows_server_2022_updated_march_2026_x64_dvd_3f772967.iso" -ErrorAction SilentlyContinue
#Remove-Item "C:\HyperVLab\arc-sql-01" -Recurse 



## Arc-enable the Hyper-V VMs
$credential = [PSCredential]::new("Administrator", (ConvertTo-SecureString "P@ssw0rd!2026" -AsPlainText -Force))

# Register required resource providers for Azure Arc
Write-Host "Registering Azure resource providers for Arc..." -ForegroundColor Cyan
foreach ($provider in @('Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.AzureArcData', 'Microsoft.OperationalInsights')) {
    $state = (az provider show --namespace $provider --query "registrationState" -o tsv 2>$null)
    if ($state -ne 'Registered') {
        Write-Host "  Registering $provider..." -ForegroundColor Yellow
        az provider register --namespace $provider --wait 2>&1 | Out-Null
    } else {
        Write-Host "  $provider already registered." -ForegroundColor Green
    }
}

# Create the service principal and assign permissions using the az cli, then set the $AZURE_SP_CLIENT_ID and $AZURE_SP_SECRET variables in terraform.tfvars before running this script. The service principal needs at least the 'Virtual Machine Contributor' role on the resource group to onboard the VMs to Arc, and 'Log Analytics Contributor' role to onboard to Log Analytics workspace."
# Create SP and capture output
$spOutput = az ad sp create-for-rbac --name "sp-arc-onboarding" `
    --role "Azure Connected Machine Onboarding" `
    --scopes "/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$PREFIX-rg" | ConvertFrom-Json

$AZURE_SP_CLIENT_ID = $spOutput.appId
$AZURE_SP_SECRET    = $spOutput.password

# Add extra role for resource administration
$spAppId = (az ad sp list --display-name "sp-arc-onboarding" --query "[0].appId" -o tsv)
az role assignment create --assignee $spAppId `
    --role "Azure Connected Machine Resource Administrator" `
    --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$PREFIX-rg"

# Get Log Analytics workspace id and key
$AZURE_LOG_ANALYTICS_WORKSPACE_ID = (az monitor log-analytics workspace show --resource-group "$PREFIX-rg" --workspace-name "$PREFIX-law" --query id -o tsv)
$AZURE_LOG_ANALYTICS_WORKSPACE_KEY = (az monitor log-analytics workspace get-shared-keys --resource-group "$PREFIX-rg" --workspace-name "$PREFIX-law" --query "primarySharedKey" -o tsv)

# Read the script content
$arcScript = Get-Content ".\Install-AzureArcAgent-SqlBPA.ps1" -Raw

# Parameters for Arc onboarding
$params = @{
    TenantId                = $AZURE_TENANT_ID
    SubscriptionId          = $AZURE_SUBSCRIPTION_ID
    ResourceGroupName       = "$PREFIX-rg"
    Location                = $LOCATION
    ServicePrincipalClientId = $AZURE_SP_CLIENT_ID
    ServicePrincipalSecret  = $AZURE_SP_SECRET
    WorkspaceId             = $AZURE_LOG_ANALYTICS_WORKSPACE_ID
    WorkspaceKey            = $AZURE_LOG_ANALYTICS_WORKSPACE_KEY
}

foreach ($vmName in @("arc-sql-01", "arc-sql-02")) {
    Write-Host "Arc-enabling $vmName..."
    
    # Copy script into VM and run it
    Invoke-Command -VMName $vmName -Credential $credential -ScriptBlock {
        param($script, $p)
        $script | Out-File "C:\Install-AzureArcAgent-SqlBPA.ps1" -Encoding utf8
        & powershell -ExecutionPolicy Unrestricted -File "C:\Install-AzureArcAgent-SqlBPA.ps1" `
            -TenantId $p.TenantId `
            -SubscriptionId $p.SubscriptionId `
            -ResourceGroupName $p.ResourceGroupName `
            -Location $p.Location `
            -ServicePrincipalClientId $p.ServicePrincipalClientId `
            -ServicePrincipalSecret $p.ServicePrincipalSecret `
            -WorkspaceId $p.WorkspaceId `
            -WorkspaceKey $p.WorkspaceKey
    } -ArgumentList $arcScript, $params
}

# Configure Arc SQL instances: license type, BPA workspace, schedule, and trigger assessment
# Uses dynamic discovery since Arc machine names may differ from Hyper-V VM names
# Configures everything via the WindowsAgent.SqlServer extension settings
Write-Host "`nConfiguring Arc SQL instances..." -ForegroundColor Cyan
$env:PYTHONWARNINGS = "ignore::SyntaxWarning"

$lawId = az monitor log-analytics workspace show `
    --resource-group "$PREFIX-rg" `
    --workspace-name "$PREFIX-law" `
    --query id -o tsv

# Get the DCR and DCE created by Terraform for BPA Assessment
Write-Host "Getting DCR and DCE created by Terraform..." -ForegroundColor Cyan
$bpaDcrId = az monitor data-collection rule list `
    --resource-group "$PREFIX-rg" `
    --query "[?contains(name, 'bpa-dcr')].id" -o tsv 2>$null
$bpaDceId = az monitor data-collection endpoint list `
    --resource-group "$PREFIX-rg" `
    --query "[?contains(name, '$PREFIX-dce')].id" -o tsv 2>$null

if (-not $bpaDcrId -or -not $bpaDceId) {
    Write-Host "  ERROR: BPA DCR or DCE not found. Ensure 'terraform apply' completed successfully." -ForegroundColor Red
    exit 1
}

Write-Host "  Found BPA DCR: $bpaDcrId" -ForegroundColor Green
Write-Host "  Found BPA DCE: $bpaDceId" -ForegroundColor Green

# Associate BPA DCR and DCE with Arc machines
$arcMachines = az resource list --resource-group "$PREFIX-rg" `
    --resource-type "Microsoft.HybridCompute/machines" `
    --query "[].name" -o tsv

foreach ($machine in $arcMachines) {
    Write-Host "  Configuring: $machine" -ForegroundColor Yellow

    # Step 1: Install AzureMonitorWindowsAgent extension (required for BPA results upload)
    $amaExists = az connectedmachine extension show `
        --machine-name $machine `
        --resource-group "$PREFIX-rg" `
        --name "AzureMonitorWindowsAgent" `
        --query "name" -o tsv 2>$null
    if (-not $amaExists) {
        Write-Host "    Installing AzureMonitorWindowsAgent..."
        az connectedmachine extension create `
            --machine-name $machine `
            --resource-group "$PREFIX-rg" `
            --name "AzureMonitorWindowsAgent" `
            --publisher "Microsoft.Azure.Monitor" `
            --type "AzureMonitorWindowsAgent" `
            --location $LOCATION `
            --enable-auto-upgrade true 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "    WARNING: AMA install failed" -ForegroundColor Red }
        else { Write-Host "    AMA installed." -ForegroundColor Green }
    } else {
        Write-Host "    AMA already installed." -ForegroundColor Green
    }

    # Step 2: Associate BPA DCR and DCE with the Arc machine
    $arcMachineId = "/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$PREFIX-rg/providers/Microsoft.HybridCompute/machines/$machine"
    Write-Host "    Creating BPA DCR association..."
    az monitor data-collection rule association create `
        --name "arc-bpa-dcr-$machine" `
        --resource $arcMachineId `
        --rule-id $bpaDcrId 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "    WARNING: BPA DCR association failed" -ForegroundColor Red }
    else { Write-Host "    BPA DCR associated." -ForegroundColor Green }

    Write-Host "    Creating BPA DCE association..."
    az monitor data-collection rule association create `
        --name "configurationAccessEndpoint" `
        --resource $arcMachineId `
        --endpoint-id $bpaDceId 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "    WARNING: DCE association failed" -ForegroundColor Red }
    else { Write-Host "    DCE associated." -ForegroundColor Green }

    # Step 3: Configure WindowsAgent.SqlServer extension settings (license type + BPA)
    $settings = @{
        LicenseType = "Paid"
        AssessmentSettings = @{
            Enable = $true
            WorkspaceResourceId = $lawId
            Schedule = @{
                Enable = $true
                WeeklyInterval = 1
                DayOfWeek = "Sunday"
                StartTime = "02:00"
            }
            RunImmediately = $true
        }
    } | ConvertTo-Json -Depth 5

    $settingsFile = Join-Path $env:TEMP "arc-ext-settings-$machine.json"
    [System.IO.File]::WriteAllText($settingsFile, $settings)

    Write-Host "    Updating WindowsAgent.SqlServer extension settings..."
    $extResult = az connectedmachine extension update `
        --machine-name $machine `
        --resource-group "$PREFIX-rg" `
        --name "WindowsAgent.SqlServer" `
        --settings "@$settingsFile" 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "    WARNING: Extension update failed: $extResult" -ForegroundColor Red }

    Remove-Item $settingsFile -ErrorAction SilentlyContinue

    # Verify extension settings were applied
    Write-Host "    Verifying extension settings..."
    $extLic = az connectedmachine extension show `
        --machine-name $machine `
        --resource-group "$PREFIX-rg" `
        --name "WindowsAgent.SqlServer" `
        --query "properties.settings.LicenseType" -o tsv 2>$null
    if ($extLic -eq "Paid") { Write-Host "    Extension LicenseType: Paid" -ForegroundColor Green }
    else { Write-Host "    WARNING: Extension LicenseType is '$extLic' (expected 'Paid')" -ForegroundColor Red }

    Write-Host "    Done." -ForegroundColor Green
}

## Associate Performance Counter DCR with Arc machines
Write-Host "`nAssociating Performance Counter DCR with Arc machines..." -ForegroundColor Cyan

# Get the performance counter DCR created by Terraform
$perfCounterDcrId = az monitor data-collection rule list `
    --resource-group "$PREFIX-rg" `
    --query "[?contains(name, 'perfcounters')].id" -o tsv 2>$null

if ($perfCounterDcrId) {
    Write-Host "  Found Performance Counter DCR: $perfCounterDcrId" -ForegroundColor Yellow

    # Associate with each Arc machine
    $arcMachines = az resource list --resource-group "$PREFIX-rg" `
        --resource-type "Microsoft.HybridCompute/machines" `
        --query "[].name" -o tsv

    foreach ($machine in $arcMachines) {
        $arcMachineId = "/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$PREFIX-rg/providers/Microsoft.HybridCompute/machines/$machine"
        
        Write-Host "    Associating DCR with $machine..."
        
        # Associate DCR (DCE association already created earlier with BPA setup)
        az monitor data-collection rule association create `
            --name "arc-perf-dcr-$machine" `
            --resource $arcMachineId `
            --rule-id $perfCounterDcrId 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) { 
            Write-Host "      Performance Counter DCR associated." -ForegroundColor Green 
        } else { 
            Write-Host "      WARNING: Performance Counter DCR association failed" -ForegroundColor Red 
        }
    }
} else {
    Write-Host "  WARNING: Performance Counter DCR not found. Run 'terraform apply' first." -ForegroundColor Yellow
}

## Install BPA Dashboard

# Import the Azure Workbook — use a temp file to avoid command-line length limits
#$workbookJson = Get-Content ".\AzureBPAWorkbook\Azure_SQL_BPA_Dashboard.json" -Raw
$workbookJson = Get-Content ".\AzureBPAWorkbook\Azure_Arc_SQL_Dashboard_with_cpu.json" -Raw
$workbookId = (New-Guid).Guid
$sourceId = "/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$PREFIX-rg/providers/Microsoft.OperationalInsights/workspaces/$PREFIX-law"

$body = @{
    location   = $LOCATION
    kind       = "shared"
    properties = @{
        displayName    = "Azure SQL BPA Dashboard with CPU"
        category       = "workbook"
        serializedData = $workbookJson
        sourceId       = $sourceId
    }
} | ConvertTo-Json -Depth 5

$bodyFile = Join-Path $env:TEMP "workbook-body.json"
[System.IO.File]::WriteAllText($bodyFile, $body)

az rest --method PUT `
    --uri "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$PREFIX-rg/providers/Microsoft.Insights/workbooks/${workbookId}?api-version=2022-04-01" `
    --body "@$bodyFile"

Remove-Item $bodyFile -ErrorAction SilentlyContinue
Write-Host "Azure SQL BPA Dashboard workbook deployed." -ForegroundColor Green


# Associate DCE with Azure VMs (required for custom log ingestion via AMA)
# Note: DCR associations are created by Terraform, this just adds the DCE endpoint
Write-Host "\nAssociating BPA DCE with Azure VMs..." -ForegroundColor Cyan
foreach ($vm in $azureVmNames) {
    $vmId = "/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$PREFIX-rg/providers/Microsoft.Compute/virtualMachines/$vm"
    az monitor data-collection rule association create `
        --name "configurationAccessEndpoint" `
        --resource $vmId `
        --endpoint-id $bpaDceId 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  WARNING: DCE association failed for $vm" -ForegroundColor Red }
    else { Write-Host "  DCE associated with $vm" -ForegroundColor Green }
}

# trigger the BPA assessment on all Azure VMs
foreach ($vm in @("sql-bpa-01","sql-bpa-02","sql-bpa-03","sql-bpa-04","sql-bpa-05")) {
    Write-Host "Checking $vm..."
    $settings = az sql vm show -n $vm -g"$PREFIX-rg"  --query "assessmentSettings" -o tsv
    if (-not $settings -or $settings -eq "None") {
        Write-Host "  Assessment not configured - fixing..."
        az sql vm update -n $vm -g "$PREFIX-rg" `
            --enable-assessment true `
            --workspace-name "$PREFIX-law" `
            --workspace-rg "$PREFIX-rg" `
            --agent-rg "$PREFIX-rg" 2>&1
    } else {
        Write-Host "  Assessment already configured."
    }

    Write-Host " Starting Assessment. "
    az sql vm start-assessment -n $vm -g "$PREFIX-rg"
}

# Arc BPA assessment is triggered automatically via RunImmediately=true in the extension settings above