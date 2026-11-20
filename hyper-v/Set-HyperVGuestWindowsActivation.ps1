<#
.SYNOPSIS
    Queries Windows versions and optionally activates selected Hyper-V guests.
.DESCRIPTION
    Run elevated on the Hyper-V host with guest administrator credentials.
    Uses PowerShell Direct, not Azure Arc or WinRM. Query is the default.
    With -Activate, queries each guest and securely prompts for its matching key.
    Optionally supply -ProductKey to use one key for all selected eligible guests.
    Already activated guests are not changed. Evaluation conversion is not performed.
.EXAMPLE
    .\Set-HyperVGuestWindowsActivation.ps1 -VMName arcsql-01,arcsql-02 -Activate
.EXAMPLE
    .\Set-HyperVGuestWindowsActivation.ps1 -VMName arcsql-01,arcsql-02
.EXAMPLE
    $key = Read-Host 'Windows product key' -AsSecureString
    .\Set-HyperVGuestWindowsActivation.ps1 -VMName arcsql-01 -Activate -ProductKey $key
#>
#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string[]]$VMName,
    [PSCredential]$GuestCredential,
    [switch]$Activate,
    [Security.SecureString]$ProductKey,
    [ValidateRange(1, 600)] [int]$VerificationTimeoutSeconds = 60
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-GuestWindowsActivation {
    param([bool]$Activate, [Security.SecureString]$ProductKey, [int]$TimeoutSeconds)
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $edition = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID
    $windowsAppId = '55c92734-d682-4d71-983e-d6ec3f16059f'
    function Get-WindowsLicense {
        @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID='$windowsAppId'" |
            Where-Object { $_.PartialProductKey -and -not $_.LicenseIsAddon })
    }
    function Format-LicensingError {
        param([Management.Automation.ErrorRecord]$Record, [Security.SecureString]$Key)
        $details = @()
        if ($Record.ErrorDetails) { $details += $Record.ErrorDetails.Message }
        $exception = $Record.Exception
        while ($exception) {
            $details += ('HRESULT 0x{0:X8}: {1}' -f $exception.HResult, $exception.Message)
            if ($exception.PSObject.Properties['NativeErrorCode']) {
                $details += "NativeErrorCode: $($exception.NativeErrorCode)"
            }
            if ($exception.PSObject.Properties['ErrorData'] -and $exception.ErrorData) {
                foreach ($property in $exception.ErrorData.CimInstanceProperties) {
                    if ($property.Name -in @('Message', 'Error_Code', 'StatusCode')) {
                        $details += "$($property.Name): $($property.Value)"
                    }
                }
            }
            $exception = $exception.InnerException
        }
        $text = ($details | Select-Object -Unique) -join ' | '
        $secret = [PSCredential]::new('key', $Key).GetNetworkCredential().Password
        try {
            foreach ($value in @($secret, $secret.Trim())) {
                if ($value) { $text = [regex]::Replace($text, [regex]::Escape($value), '[redacted]', 'IgnoreCase') }
            }
            [regex]::Replace($text, '(?i)[a-z0-9]{5}(?:-[a-z0-9]{5}){4}', '[redacted]')
        } finally { $secret = $null }
    }
    $products = @(Get-WindowsLicense)
    $action = 'Queried'
    if ($Activate) {
        if ($os.ProductType -eq 1) { throw 'Only Windows Server guests can be activated by this script.' }
        if ($edition -match 'Eval' -or $os.Caption -match 'Evaluation') {
            throw 'Evaluation edition: convert to a supported licensed edition separately, reboot, then rerun.'
        }
        if ($products | Where-Object { $_.LicenseStatus -eq 1 }) {
            $action = 'AlreadyActivated'
        } else {
            $plainKey = [PSCredential]::new('key', $ProductKey).GetNetworkCredential().Password.Trim()
            try {
                if ($plainKey -notmatch '^[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){4}$' -or $plainKey -eq 'XXXXX-XXXXX-XXXXX-XXXXX-XXXXX') {
                    throw 'Product key must contain five groups of five characters and must not be a placeholder.'
                }
                $service = Get-CimInstance -ClassName SoftwareLicensingService
                try {
                    $installed = Invoke-CimMethod -InputObject $service -MethodName InstallProductKey -Arguments @{ ProductKey = $plainKey }
                } catch { throw "InstallProductKey failed: $(Format-LicensingError -Record $_ -Key $ProductKey)" }
                if ($installed.ReturnValue -ne 0) { throw ('InstallProductKey failed (code 0x{0:X8}).' -f [uint32]$installed.ReturnValue) }
                $suffix = $plainKey.Substring($plainKey.Length - 5)
            } finally { $plainKey = $null }
            $products = @(Get-WindowsLicense | Where-Object { $_.PartialProductKey -eq $suffix })
            if ($products.Count -ne 1) { throw 'Cannot uniquely identify the installed Windows license; activation was not attempted.' }
            $id = $products[0].ID
            try {
                $activated = Invoke-CimMethod -InputObject $products[0] -MethodName Activate
            } catch { throw "Windows activation failed: $(Format-LicensingError -Record $_ -Key $ProductKey)" }
            if ($activated.ReturnValue -ne 0) { throw ('Windows activation failed (code 0x{0:X8}).' -f [uint32]$activated.ReturnValue) }
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            do {
                $products = @(Get-WindowsLicense | Where-Object { $_.ID -eq $id })
                if ($products.Count -eq 1 -and $products[0].LicenseStatus -eq 1) { break }
                if ((Get-Date) -ge $deadline) { throw 'Activation verification timed out: the installed Windows license is not Licensed (LicenseStatus=1).' }
                Start-Sleep -Seconds 2
            } while ($true)
            $action = 'Activated'
        }
    }
    $states = @('Unlicensed', 'Licensed', 'OOBGrace', 'OOTGrace', 'NonGenuineGrace', 'Notification', 'ExtendedGrace')
    if (-not $products.Count) { $products = @($null) }
    foreach ($product in $products) {
        $status = 'No installed Windows product key'
        if ($product) {
            $status = "Unknown ($($product.LicenseStatus))"
            if ($product.LicenseStatus -ge 0 -and $product.LicenseStatus -lt $states.Count) { $status = $states[[int]$product.LicenseStatus] }
        }
        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Windows = $os.Caption
            Version = $os.Version
            Build = $os.BuildNumber
            Edition = $edition
            ProductType = $os.ProductType
            LicenseStatus = $status
            Activated = [bool]($product -and $product.LicenseStatus -eq 1)
            PartialProductKey = $(if ($product) { $product.PartialProductKey } else { $null })
            Action = $action
        }
    }
}

if ($ProductKey -and -not $Activate) { throw 'ProductKey requires -Activate.' }
if (@($VMName | Select-Object -Unique).Count -ne $VMName.Count) { throw 'Supply unique VM names.' }
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run elevated on the Hyper-V host.' }
Import-Module Hyper-V -ErrorAction Stop
foreach ($name in $VMName) {
    if ([string]::IsNullOrWhiteSpace($name) -or [Management.Automation.WildcardPattern]::ContainsWildcardCharacters($name)) {
        throw 'Supply literal, nonempty VM names without wildcards.'
    }
    if ((Get-VM -Name $name -ErrorAction Stop).State -ne 'Running') { throw "Guest $name is not running." }
}
if (-not $GuestCredential) { $GuestCredential = Get-Credential -Message 'Administrator credentials for selected guests' }
if (-not $GuestCredential) { throw 'Guest credentials are required.' }
if ($ProductKey -and $ProductKey.Length -eq 0) { throw 'A nonempty product key is required.' }
$failed = @()
foreach ($name in $VMName) {
    try {
        $rows = @(Invoke-Command -VMName $name -Credential $GuestCredential `
            -ScriptBlock ${function:Invoke-GuestWindowsActivation} `
            -ArgumentList $false, $null, $VerificationTimeoutSeconds -ErrorAction Stop)
        if (-not $rows.Count) { throw 'Guest returned no Windows licensing information.' }
        if ($Activate) {
            $os = $rows[0]
            if ($os.ProductType -eq 1) { throw 'Only Windows Server guests can be activated by this script.' }
            if ($os.Edition -match 'Eval' -or $os.Windows -match 'Evaluation') {
                throw 'Evaluation edition: convert to a supported licensed edition separately, reboot, then rerun.'
            }
            if ($rows | Where-Object { $_.Activated }) {
                foreach ($row in $rows) { $row.Action = 'AlreadyActivated' }
            } elseif ($PSCmdlet.ShouldProcess($name, "Install Windows product key and activate $($os.Windows) [$($os.Edition)]")) {
                $guestKey = $ProductKey
                try {
                    if (-not $guestKey) {
                        $guestKey = Read-Host "Windows product key for $name - $($os.Windows), edition $($os.Edition), version $($os.Version), build $($os.Build)" -AsSecureString
                    }
                    if (-not $guestKey -or $guestKey.Length -eq 0) { throw 'A nonempty product key is required.' }
                    $rows = @(Invoke-Command -VMName $name -Credential $GuestCredential `
                        -ScriptBlock ${function:Invoke-GuestWindowsActivation} `
                        -ArgumentList $true, $guestKey, $VerificationTimeoutSeconds -ErrorAction Stop)
                } finally { $guestKey = $null }
            }
        }
        $rows | Select-Object @{Name='VMName'; Expression={$name}}, ComputerName, Windows, Version, Build, Edition, LicenseStatus, Activated, PartialProductKey, Action
    } catch {
        $failed += $name
        Write-Warning "Guest ${name}: $($_.Exception.Message)"
        [pscustomobject]@{ VMName=$name; Activated=$false; Action='Failed'; Error=$_.Exception.Message }
    }
}
if ($failed.Count) { throw "Windows licensing failed for: $($failed -join ', '). See per-guest diagnostics." }
