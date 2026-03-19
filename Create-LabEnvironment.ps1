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