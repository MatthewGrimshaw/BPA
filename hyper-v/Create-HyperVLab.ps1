<#
.SYNOPSIS
    Creates Hyper-V VMs running SQL Server for Arc-enabled SQL BPA testing.

.DESCRIPTION
    Creates lightweight Hyper-V VMs on your local machine:
      1. Creates a VHDX from a Windows Server ISO (unattended install).
      2. Creates a Hyper-V VM with a small footprint.
      3. Installs SQL Server Developer edition unattended via PowerShell Direct.
      4. Restores sample databases and applies intentional misconfigurations.

    The VMs can then be Arc-enabled using Install-AzureArcAgent-SqlBPA.ps1.

.PARAMETER VmConfigs
    Array of VM configuration hashtables. Each must contain:
      Name, WindowsIso, SqlIso, Databases, Misconfigs.
    Optional: MemoryGB (default 4), VCpus (default 2), DiskSizeGB (default 60),
      WindowsProductKey (MAK key for activation — omit for evaluation ISOs),
      SqlProductKey (SQL Server product key — omit for Developer edition).

.PARAMETER VmPath
    Base path for VM files. Default: C:\HyperVLab

.PARAMETER AdminPassword
    Local Administrator password. Default: P@ssw0rd!2026

.PARAMETER SwitchName
    Hyper-V switch name. Defaults to 'Default Switch'.

.EXAMPLE
    $vms = @(
        @{
            Name       = "arc-sql-01"
            WindowsIso = "C:\ISOs\WindowsServer2022.iso"
            SqlIso     = "C:\ISOs\SQLServer2022-Dev.iso"
            Databases  = "adventureworks,misconfigdemo"
            Misconfigs = "maxmem_default,maxdop_zero,auto_shrink,no_adhoc_opt"
        },
        @{
            Name       = "arc-sql-02"
            WindowsIso = "C:\ISOs\WindowsServer2019.iso"
            SqlIso     = "C:\ISOs\SQLServer2019-Dev.iso"
            Databases  = "adventureworks,worldwideimporters"
            Misconfigs = "maxmem_default,ctp_default,page_verify_none,filegrowth_pct"
        }
    )
    .\Create-HyperVLab.ps1 -VmConfigs $vms

.NOTES
    Prerequisites:
      - Windows 10/11 Pro/Enterprise with Hyper-V enabled
      - Run as Administrator
      - Windows Server ISO (2019 or 2022) and SQL Server Developer ISO
      - ISOs available from Visual Studio subscriptions or Evaluation Center
      - ~8GB free RAM and ~80GB free disk per VM
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable[]]$VmConfigs,

    [Parameter()]
    [string]$VmPath = "C:\HyperVLab",

    [Parameter()]
    [string]$AdminPassword = "P@ssw0rd!2026",

    [Parameter()]
    [string]$SwitchName
)

$ErrorActionPreference = 'Stop'

#region ── Helpers ─────────────────────────────────────────────────────────────

function Write-Step { param([string]$Message); Write-Host "`n==> $Message" -ForegroundColor Cyan }

function Assert-Administrator {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator."
    }
}

function Wait-VMReady {
    param([string]$VMName, [PSCredential]$Credential, [int]$TimeoutMinutes = 25)
    Write-Host "    Waiting for $VMName to be ready (up to $TimeoutMinutes min)..." -ForegroundColor Yellow
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock { hostname } -ErrorAction Stop | Out-Null
            Write-Host "    $VMName is ready." -ForegroundColor Green
            return
        } catch { Start-Sleep -Seconds 15 }
    }
    throw "Timed out waiting for $VMName."
}

#endregion

#region ── Main ────────────────────────────────────────────────────────────────

Assert-Administrator

if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    throw "Hyper-V not found. Enable it: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All"
}

if (-not $SwitchName) {
    $sw = Get-VMSwitch | Where-Object { $_.Name -eq 'Default Switch' } | Select-Object -First 1
    if (-not $sw) { $sw = Get-VMSwitch | Select-Object -First 1 }
    if (-not $sw) { throw "No Hyper-V switch found. Create one: New-VMSwitch -Name 'LabSwitch' -SwitchType Internal" }
    $SwitchName = $sw.Name
}
Write-Host "Using Hyper-V switch: $SwitchName" -ForegroundColor Green

$securePassword = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
$credential = [PSCredential]::new("Administrator", $securePassword)
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }

foreach ($config in $VmConfigs) {
    $vmName     = $config.Name
    $windowsIso = $config.WindowsIso
    $sqlIso     = $config.SqlIso
    $databases  = $config.Databases
    $misconfigs = $config.Misconfigs
    $memoryGB          = if ($config.MemoryGB)          { $config.MemoryGB }          else { 4 }
    $vCpus             = if ($config.VCpus)             { $config.VCpus }             else { 2 }
    $diskSizeGB        = if ($config.DiskSizeGB)        { $config.DiskSizeGB }        else { 60 }
    $windowsProductKey = if ($config.WindowsProductKey) { $config.WindowsProductKey } else { $null }
    $sqlProductKey     = if ($config.SqlProductKey)     { $config.SqlProductKey }     else { $null }

    Write-Step "Creating VM: $vmName"

    if (-not (Test-Path $windowsIso)) { throw "Windows ISO not found: $windowsIso" }
    if (-not (Test-Path $sqlIso))     { throw "SQL Server ISO not found: $sqlIso" }

    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
        Write-Host "  VM '$vmName' already exists. Skipping." -ForegroundColor Yellow
        continue
    }

    $vmDir = Join-Path $VmPath $vmName
    $vhdx  = Join-Path $vmDir "$vmName.vhdx"

    # Clean up leftover files from a previous failed run
    if (Test-Path $vhdx) {
        Write-Host "  Removing leftover VHDX from previous attempt..." -ForegroundColor Yellow
        Dismount-VHD -Path $vhdx -ErrorAction SilentlyContinue
        Remove-Item $vmDir -Recurse -Force
    }
    if (-not (Test-Path $vmDir)) { New-Item -ItemType Directory -Path $vmDir -Force | Out-Null }

    # ── Create VHDX from Windows ISO ─────────────────────────────────────
    Write-Host "  Creating VHDX from Windows ISO..." -ForegroundColor Yellow

    $mountResult = Mount-DiskImage -ImagePath $windowsIso -PassThru
    $isoDrive = ($mountResult | Get-Volume).DriveLetter
    $wimPath = "${isoDrive}:\sources\install.wim"
    if (-not (Test-Path $wimPath)) {
        $wimPath = "${isoDrive}:\sources\install.esd"
        if (-not (Test-Path $wimPath)) {
            Dismount-DiskImage -ImagePath $windowsIso | Out-Null
            throw "Cannot find install.wim or install.esd in the ISO."
        }
    }

    $images = Get-WindowsImage -ImagePath $wimPath
    $targetImage = $images | Where-Object { $_.ImageName -match 'Standard.*Desktop|Datacenter.*Desktop' } | Select-Object -First 1
    if (-not $targetImage) { $targetImage = $images | Where-Object { $_.ImageIndex -eq 2 } }
    if (-not $targetImage) { $targetImage = $images | Select-Object -First 1 }
    Write-Host "  Image: $($targetImage.ImageName) (Index $($targetImage.ImageIndex))" -ForegroundColor Yellow

    New-VHD -Path $vhdx -SizeBytes ([int64]$diskSizeGB * 1GB) -Dynamic | Out-Null
    $mountedVhd = Mount-VHD -Path $vhdx -Passthru
    $diskNum = $mountedVhd.DiskNumber

    Initialize-Disk -Number $diskNum -PartitionStyle GPT | Out-Null
    $efiPart = New-Partition -DiskNumber $diskNum -Size 100MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    Format-Volume -Partition $efiPart -FileSystem FAT32 -NewFileSystemLabel "EFI" -Confirm:$false | Out-Null
    $efiPart | Add-PartitionAccessPath -AccessPath "S:"

    New-Partition -DiskNumber $diskNum -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null

    $osPart = New-Partition -DiskNumber $diskNum -UseMaximumSize -AssignDriveLetter
    $osDrive = $osPart.DriveLetter
    Format-Volume -Partition $osPart -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false | Out-Null

    Write-Host "  Applying Windows image to ${osDrive}:\ ..." -ForegroundColor Yellow
    Expand-WindowsImage -ImagePath $wimPath -Index $targetImage.ImageIndex -ApplyPath "${osDrive}:\" | Out-Null

    # ── Inject unattend.xml ──────────────────────────────────────────────
    $pantherDir = "${osDrive}:\Windows\Panther"
    if (-not (Test-Path $pantherDir)) { New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null }

    # Build specialize pass for product key if provided
    $specializeXml = ""
    if ($windowsProductKey) {
        $specializeXml = @"

  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ProductKey>$windowsProductKey</ProductKey>
    </component>
  </settings>
"@
    }

    $unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">$specializeXml
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>$AdminPassword</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <TimeZone>UTC</TimeZone>
      <ComputerName>$vmName</ComputerName>
    </component>
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
  </settings>
</unattend>
"@
    # Write without BOM — Windows Setup can choke on UTF-8 BOM
    [System.IO.File]::WriteAllText("${osDrive}:\Windows\Panther\unattend.xml", $unattend)
    [System.IO.File]::WriteAllText("${osDrive}:\unattend.xml", $unattend)

    # Inject SetupComplete.cmd — runs once after setup, enables PSRemoting and RDP
    $setupDir = "${osDrive}:\Windows\Setup\Scripts"
    if (-not (Test-Path $setupDir)) { New-Item -ItemType Directory -Path $setupDir -Force | Out-Null }
    $setupComplete = @"
@echo off
powershell -Command "Enable-PSRemoting -Force -SkipNetworkProfileCheck" >C:\setup-psremoting.log 2>&1
powershell -Command "Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0" >>C:\setup-psremoting.log 2>&1
netsh advfirewall firewall set rule group="Remote Desktop" new enable=yes >>C:\setup-psremoting.log 2>&1
netsh advfirewall firewall add rule name="WinRM-HTTP" dir=in localport=5985 protocol=tcp action=allow >>C:\setup-psremoting.log 2>&1
"@
    [System.IO.File]::WriteAllText("${setupDir}\SetupComplete.cmd", $setupComplete)

    # ── Boot config ──────────────────────────────────────────────────────
    & bcdboot "${osDrive}:\Windows" /s S: /f UEFI | Out-Null

    Dismount-VHD -Path $vhdx
    Dismount-DiskImage -ImagePath $windowsIso | Out-Null

    # ── Create VM ────────────────────────────────────────────────────────
    Write-Host "  Creating VM ($vCpus vCPUs, ${memoryGB}GB RAM)..." -ForegroundColor Yellow

    New-VM -Name $vmName -MemoryStartupBytes ([int64]$memoryGB * 1GB) `
           -VHDPath $vhdx -Generation 2 -SwitchName $SwitchName -Path $VmPath | Out-Null

    Set-VM -Name $vmName -ProcessorCount $vCpus -DynamicMemory `
           -MemoryMinimumBytes 1GB -MemoryMaximumBytes ([int64]$memoryGB * 1GB) `
           -AutomaticCheckpointsEnabled $false -CheckpointType Disabled

    Set-VMFirmware -VMName $vmName -EnableSecureBoot Off
    Add-VMDvdDrive -VMName $vmName -Path $sqlIso

    # ── Start and wait ───────────────────────────────────────────────────
    Start-VM -Name $vmName
    Write-Host "  Waiting for Windows setup (10-15 min)..." -ForegroundColor Yellow
    Wait-VMReady -VMName $vmName -Credential $credential -TimeoutMinutes 25

    # ── Install SQL Server ───────────────────────────────────────────────
    Write-Host "  Installing SQL Server..." -ForegroundColor Yellow

    Invoke-Command -VMName $vmName -Credential $credential -ScriptBlock {
        param($sqlKey)
        $dvd = Get-Volume | Where-Object { $_.DriveType -eq 'CD-ROM' } |
            ForEach-Object { "$($_.DriveLetter):" } |
            Where-Object { Test-Path "$_\setup.exe" } | Select-Object -First 1

        if (-not $dvd) { throw "SQL Server ISO not found on DVD drive." }

        foreach ($d in @("C:\SQLData","C:\SQLLog","C:\SQLTempDB")) {
            if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        }

        $setupArgs = @(
            "/Q", "/ACTION=Install", "/FEATURES=SQLENGINE",
            "/INSTANCENAME=MSSQLSERVER",
            "/SQLSVCACCOUNT=`"NT AUTHORITY\SYSTEM`"",
            "/SQLSYSADMINACCOUNTS=`"BUILTIN\Administrators`"",
            "/AGTSVCACCOUNT=`"NT AUTHORITY\SYSTEM`"",
            "/AGTSVCSTARTUPTYPE=Automatic",
            "/SQLUSERDBDIR=`"C:\SQLData`"",
            "/SQLUSERDBLOGDIR=`"C:\SQLLog`"",
            "/SQLTEMPDBDIR=`"C:\SQLTempDB`"",
            "/SQLTEMPDBLOGDIR=`"C:\SQLTempDB`"",
            "/SECURITYMODE=SQL",
            "/SAPWD=`"$using:AdminPassword`"",
            "/TCPENABLED=1",
            "/IACCEPTSQLSERVERLICENSETERMS",
            "/UpdateEnabled=False"
        )

        # Add product key if provided (Developer edition doesn't need one)
        if ($sqlKey) { $setupArgs += "/PID=`"$sqlKey`"" }

        $proc = Start-Process "$dvd\setup.exe" -ArgumentList $setupArgs -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) { throw "SQL setup failed with exit code $($proc.ExitCode)" }

        New-NetFirewallRule -DisplayName 'SQL Server (TCP 1433)' -Direction Inbound -Protocol TCP `
            -LocalPort 1433 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
    } -ArgumentList $sqlProductKey

    Write-Host "  SQL Server installed." -ForegroundColor Green

    # ── Configure databases ──────────────────────────────────────────────
    Write-Host "  Configuring databases..." -ForegroundColor Yellow

    $configScript = Get-Content (Join-Path $scriptDir "configure-sql-hyperv.ps1") -Raw

    Invoke-Command -VMName $vmName -Credential $credential -ScriptBlock {
        param($script, $db, $mc)
        $script | Out-File -FilePath "C:\configure-sql-hyperv.ps1" -Encoding utf8
        & powershell -ExecutionPolicy Unrestricted -File "C:\configure-sql-hyperv.ps1" -Databases $db -Misconfigs $mc
    } -ArgumentList $configScript, $databases, $misconfigs

    Write-Host "  Databases configured." -ForegroundColor Green

    Get-VMDvdDrive -VMName $vmName | Set-VMDvdDrive -Path $null

    Write-Host "`n  VM '$vmName' ready for Arc enablement!" -ForegroundColor Green
    Write-Host "  Connect: vmconnect localhost $vmName" -ForegroundColor DarkCyan
    Write-Host "  Password: $AdminPassword" -ForegroundColor DarkCyan
}

Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host "[DONE] $($VmConfigs.Count) VM(s) created." -ForegroundColor Green
Write-Host "Next: Run Install-AzureArcAgent-SqlBPA.ps1 from within each VM." -ForegroundColor Green

#endregion
