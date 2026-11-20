#requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'Set-HyperVGuestWindowsActivation.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Syntax errors: $errors" }
$function = $ast.Find({param($n)
    $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-GuestWindowsActivation'
}, $true)
. ([scriptblock]::Create($function.Extent.Text))
$state = @{ Status=0; Edition='ServerStandard'; Calls=@(); Polls=0; Fail=$false; NeverLicensed=$false; ThrowMethod=''; InstalledKey=$null }
function Get-ItemPropertyValue { $state.Edition }
function Get-CimInstance {
    param($ClassName, $Filter)
    switch ($ClassName) {
        Win32_OperatingSystem {
            [pscustomobject]@{Caption='Windows Server 2022 Standard'; Version='10.0.20348'; BuildNumber='20348'; ProductType=3}
        }
        SoftwareLicensingService { [pscustomobject]@{Name='Licensing service'} }
        SoftwareLicensingProduct {
            if ($Filter -ne "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'") { throw 'Must query only Windows licenses.' }
            $state.Polls++
            [pscustomobject]@{ID='windows'; PartialProductKey='AAAAA'; LicenseIsAddon=$false; LicenseStatus=$state.Status}
            [pscustomobject]@{ID='addon'; PartialProductKey='BBBBB'; LicenseIsAddon=$true; LicenseStatus=1}
        }
        default { throw "Unexpected class: $ClassName" }
    }
}
function Invoke-CimMethod {
    param($InputObject, $MethodName, $Arguments)
    $state.Calls += $MethodName
    if ($MethodName -eq 'InstallProductKey') { $state.InstalledKey=$Arguments.ProductKey }
    if ($MethodName -eq $state.ThrowMethod) {
        throw [InvalidOperationException]::new(
            "Provider failed for $($state.InstalledKey)",
            [Exception]::new('The Software Licensing Service reported that the product key is invalid. 0xC004F050'))
    }
    if ($state.Fail) { return [pscustomobject]@{ReturnValue=[uint32]5} }
    if ($MethodName -eq 'Activate' -and -not $state.NeverLicensed) { $state.Status=1 }
    [pscustomobject]@{ReturnValue=0}
}
function Start-Sleep { throw 'Unexpected polling sleep.' }
$key = ConvertTo-SecureString ('AAAAA-' * 4 + 'AAAAA') -AsPlainText -Force
$result = @(Invoke-GuestWindowsActivation -Activate $false -TimeoutSeconds 1)
if ($result.Count -ne 1 -or $result[0].Activated -or $result[0].Version -ne '10.0.20348' -or $state.Calls.Count) {
    throw 'Query must report OS/status, exclude add-ons, and make no changes.'
}
$result = Invoke-GuestWindowsActivation -Activate $true -ProductKey $key -TimeoutSeconds 1
if (-not $result.Activated -or $result.Action -ne 'Activated' -or
    ($state.Calls -join ',') -ne 'InstallProductKey,Activate' -or $state.Polls -lt 4) {
    throw 'Activation must install, activate, and re-query the exact installed license.'
}
$state.Calls=@()
$result = Invoke-GuestWindowsActivation -Activate $true -ProductKey $key -TimeoutSeconds 1
if ($result.Action -ne 'AlreadyActivated' -or $state.Calls.Count) { throw 'Already licensed guest must not change.' }
$state.Status=0
$state.Edition='ServerStandardEval'
$failure=$null
try { Invoke-GuestWindowsActivation -Activate $true -ProductKey $key -TimeoutSeconds 1 } catch { $failure=$_ }
if (-not $failure -or "$failure" -notlike '*Evaluation edition*' -or $state.Calls.Count) { throw 'Evaluation conversion must be refused.' }
$state.Edition='ServerStandard'
$state.Fail=$true
$failure=$null
try { Invoke-GuestWindowsActivation -Activate $true -ProductKey $key -TimeoutSeconds 1 } catch { $failure=$_ }
if (-not $failure -or "$failure" -notlike '*InstallProductKey failed*') { throw 'Nonzero licensing result must fail.' }
$state.Fail=$false
$paddedKey = ConvertTo-SecureString ('  ' + ('AAAAA-' * 4 + 'AAAAA') + "`r`n") -AsPlainText -Force
foreach ($method in @('InstallProductKey', 'Activate')) {
    $state.ThrowMethod=$method
    $failure=$null
    try { Invoke-GuestWindowsActivation -Activate $true -ProductKey $paddedKey -TimeoutSeconds 1 } catch { $failure=$_ }
    if (-not $failure -or "$failure" -notlike '*0xC004F050*' -or "$failure" -notlike '*[[]redacted[]]*' -or
        "$failure" -match 'AAAAA-AAAAA' -or $state.InstalledKey -ne ('AAAAA-' * 4 + 'AAAAA')) {
        throw 'Provider errors must retain the underlying licensing diagnostic, redact keys, and trim copied whitespace.'
    }
}
$state.ThrowMethod=''
$state.NeverLicensed=$true
# An expired deadline exercises failure even when Activate returned zero.
$failure=$null
try { Invoke-GuestWindowsActivation -Activate $true -ProductKey $key -TimeoutSeconds -1 } catch { $failure=$_ }
if (-not $failure -or "$failure" -notlike '*verification timed out*') { throw 'A zero Activate result alone must not count as success.' }
& {
    $statements = @($ast.EndBlock.Statements | Where-Object {
        $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] -and
        $_.Extent.Text -notmatch '^\$principal =' -and $_.Extent.Text -notmatch '^if \(-not \$principal\.'
    })
    $script = [scriptblock]::Create("[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]`n" + $ast.ParamBlock.Extent.Text + "`n" +
        (($statements | ForEach-Object { $_.Extent.Text }) -join "`n"))
    $batch = @{ Prompts=@(); Changes=@(); Queries=@(); Empty=$false }
    $credential = [PSCredential]::new('Administrator', (ConvertTo-SecureString 'Test-only!' -AsPlainText -Force))
    function Import-Module {}
    function Get-VM { [pscustomobject]@{State='Running'} }
    function Read-Host {
        param($Prompt, [switch]$AsSecureString)
        if (-not $AsSecureString) { throw 'Key prompt must be secure.' }
        $batch.Prompts += $Prompt
        if ($batch.Empty) { return [Security.SecureString]::new() }
        ConvertTo-SecureString ("prompt-key-$($batch.Prompts.Count)") -AsPlainText -Force
    }
    function Invoke-Command {
        param($VMName, $Credential, $ScriptBlock, $ArgumentList)
        $year = '2022'; $version='10.0.20348'; $build='20348'; $edition='ServerStandard'
        if ($VMName -eq 'old') { $year='2019'; $version='10.0.17763'; $build='17763' }
        if ($VMName -eq 'eval') { $edition='ServerStandardEval' }
        if ($ArgumentList[0]) {
            $secret = [PSCredential]::new('key', $ArgumentList[1]).GetNetworkCredential().Password
            $batch.Changes += "$VMName=$secret"
        } else { $batch.Queries += $VMName }
        [pscustomobject]@{
            ComputerName=$VMName; Windows="Windows Server $year Standard"; Version=$version
            Build=$build; Edition=$edition; ProductType=3; LicenseStatus='Licensed'
            Activated=($VMName -eq 'licensed' -or $ArgumentList[0])
            PartialProductKey='AAAAA'; Action='Queried'
        }
    }
    $args = @{ GuestCredential=$credential; Activate=$true; Confirm=$false }
    $result = @(& $script @args -VMName old,new,licensed)
    if ($batch.Prompts.Count -ne 2 -or $batch.Prompts[0] -notlike '*old*Windows Server 2019*ServerStandard*10.0.17763*17763*' -or
        $batch.Prompts[1] -notlike '*new*Windows Server 2022*ServerStandard*10.0.20348*20348*' -or
        ($batch.Changes -join ',') -ne 'old=prompt-key-1,new=prompt-key-2' -or
        $result[2].Action -ne 'AlreadyActivated') { throw 'Mixed guests must get separate OS-specific prompts; licensed guests must skip prompting.' }
    $batch.Prompts=@(); $batch.Changes=@()
    $null = & $script @args -VMName old,new -WhatIf
    if ($batch.Prompts.Count -or $batch.Changes.Count) { throw 'WhatIf must not prompt for keys or activate.' }
    $null = & $script -VMName old,new -GuestCredential $credential
    if ($batch.Prompts.Count -or $batch.Changes.Count) { throw 'Query must not prompt for keys or activate.' }
    $failure=$null
    try { $null = & $script @args -VMName eval -WarningAction SilentlyContinue } catch { $failure=$_ }
    if (-not $failure -or $batch.Prompts.Count -or $batch.Changes.Count) { throw 'Evaluation guests must fail before prompting.' }
    $batch.Empty=$true
    $failure=$null
    try { $null = & $script @args -VMName old -WarningAction SilentlyContinue } catch { $failure=$_ }
    if (-not $failure -or $batch.Changes.Count) { throw 'Empty prompted key must fail without activation.' }
}
Write-Host 'Windows activation tests passed (mocked; no guest or licensing changes).'
