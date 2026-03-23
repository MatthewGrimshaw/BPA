# Import Existing DCR/DCE Resources into Terraform State
# Run this script ONCE after creating the Terraform configuration but BEFORE running terraform apply
# This imports the DCR/DCE that were auto-created by the PowerShell script into Terraform management

param(
    [Parameter(Mandatory=$false)]
    [string]$TerraformPath = ".\terraform"
)

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
$tfvarsPath = Join-Path $scriptRoot "terraform" "terraform.tfvars"

# Read variables from terraform.tfvars
if (-not (Test-Path $tfvarsPath)) {
    Write-Error "terraform.tfvars not found at $tfvarsPath"
    exit 1
}

$tfvars = @{}
Get-Content $tfvarsPath | ForEach-Object {
    if ($_ -match '^\s*(\w+)\s*=\s*"([^"]*)"') {
        $tfvars[$Matches[1]] = $Matches[2]
    }
}

$PREFIX = $tfvars['prefix']
$SUBSCRIPTION_ID = $tfvars['subscription_id']

Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "  Importing Existing DCR/DCE into Terraform" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""

# Change to terraform directory
Push-Location (Join-Path $scriptRoot $TerraformPath)

try {
    # Get existing DCR and DCE
    Write-Host "Finding existing DCR and DCE..." -ForegroundColor Yellow
    
    $existingDcrs = az monitor data-collection rule list `
        --resource-group "$PREFIX-rg" `
        --query "[].{name:name, id:id}" -o json | ConvertFrom-Json
    
    $existingDces = az monitor data-collection endpoint list `
        --resource-group "$PREFIX-rg" `
        --query "[].{name:name, id:id}" -o json | ConvertFrom-Json
    
    Write-Host "  Found $($existingDcrs.Count) DCR(s)" -ForegroundColor Green
    Write-Host "  Found $($existingDces.Count) DCE(s)" -ForegroundColor Green
    Write-Host ""
    
    # Identify BPA Assessment DCR/DCE (not the performance counter ones)
    # The auto-created BPA DCR usually has a GUID-based name or pattern like {rg}_{location}_DCR_1
    $bpaDcr = $existingDcrs | Where-Object { $_.name -notlike "*perfcounters*" } | Select-Object -First 1
    $bpaDce = $existingDces | Where-Object { $_.name -notlike "*perfcounters*" } | Select-Object -First 1
    
    if (-not $bpaDcr) {
        Write-Host "ERROR: Could not find BPA Assessment DCR to import." -ForegroundColor Red
        Write-Host "  Available DCRs:" -ForegroundColor Yellow
        $existingDcrs | ForEach-Object { Write-Host "    - $($_.name)" -ForegroundColor Gray }
        exit 1
    }
    
    if (-not $bpaDce) {
        Write-Host "ERROR: Could not find BPA Assessment DCE to import." -ForegroundColor Red
        Write-Host "  Available DCEs:" -ForegroundColor Yellow
        $existingDces | ForEach-Object { Write-Host "    - $($_.name)" -ForegroundColor Gray }
        exit 1
    }
    
    Write-Host "Will import:" -ForegroundColor Cyan
    Write-Host "  DCR: $($bpaDcr.name)" -ForegroundColor White
    Write-Host "       $($bpaDcr.id)" -ForegroundColor Gray
    Write-Host "  DCE: $($bpaDce.name)" -ForegroundColor White
    Write-Host "       $($bpaDce.id)" -ForegroundColor Gray
    Write-Host ""
    
    # Import DCE
    Write-Host "Importing BPA Assessment DCE..." -ForegroundColor Yellow
    terraform import azurerm_monitor_data_collection_endpoint.bpa_assessment $bpaDce.id
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ DCE imported successfully" -ForegroundColor Green
    } else {
        Write-Host "  ✗ DCE import failed (may already be imported)" -ForegroundColor Yellow
    }
    Write-Host ""
    
    # Import DCR
    Write-Host "Importing BPA Assessment DCR..." -ForegroundColor Yellow
    terraform import azurerm_monitor_data_collection_rule.bpa_assessment $bpaDcr.id
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ DCR imported successfully" -ForegroundColor Green
    } else {
        Write-Host "  ✗ DCR import failed (may already be imported)" -ForegroundColor Yellow
    }
    Write-Host ""
    
    # Note: DCR/DCE associations with Azure VMs were auto-created, but Terraform will recreate them
    # You may need to manually import those associations if you want to avoid conflicts
    
    Write-Host "Import complete!" -ForegroundColor Green
    Write-Host ""
    Write-Host "IMPORTANT NOTES:" -ForegroundColor Cyan
    Write-Host "1. Run 'terraform plan' to verify the configuration matches" -ForegroundColor White
    Write-Host "2. You may see planned changes if the Terraform config differs from existing resources" -ForegroundColor White
    Write-Host "3. DCR associations with Azure VMs are managed by Terraform resources" -ForegroundColor White
    Write-Host "4. You may need to import existing associations to avoid conflicts:" -ForegroundColor White
    Write-Host "   terraform import 'azurerm_monitor_data_collection_rule_association.bpa_azure_vms[0]' '<association-id>'" -ForegroundColor Gray
    Write-Host ""
    
} finally {
    Pop-Location
}
