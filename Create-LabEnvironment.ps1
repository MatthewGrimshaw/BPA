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



#### Install SQL IaaS Agent Extension

# Set directory back to script root if currently in terraform directory, since the Install-SqlIaaSExtension-BPA.ps1 script is located in the root of the repo, not in the terraform folder
If(((Get-Location).Path).Split('\')[-1] -eq "terraform") {
    Write-Host "Changing directory to $scriptRoot"
    cd ..
}

# Check if Install-SqlIaaSExtension-BPA.ps1 exists in the script root directory
If (-not (Test-Path ".\Install-SqlIaaSExtension-BPA.ps1")) {
    Write-Error "Install-SqlIaaSExtension-BPA.ps1 not found in $scriptRoot. Make sure you have the latest version of the repo and that the file is not blocked by Windows."
    exit 1
}

# Single VM
.\Install-SqlIaaSExtension-BPA.ps1 -SubscriptionId $AZURE_SUBSCRIPTION_ID -TenantId $AZURE_TENANT_ID-ResourceGroupName "$PREFIX-rg" `
    -VmNames "sql-bpa-01" -Location $LOCATION -WorkspaceName "$PREFIX-law"

# All 5 lab VMs at once
.\Install-SqlIaaSExtension-BPA.ps1 -SubscriptionId $AZURE_SUBSCRIPTION_ID -TenantId $AZURE_TENANT_ID -ResourceGroupName "$PREFIX-rg" `
    -VmNames "sql-bpa-01","sql-bpa-02","sql-bpa-03","sql-bpa-04","sql-bpa-05" `
    -Location $LOCATION -WorkspaceName "$PREFIX-law"

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

