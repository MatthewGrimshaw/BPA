[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)] [string] $Databases,
    [Parameter(Mandatory)] [string] $Misconfigs,
    [Parameter(Mandatory)] [int]    $DiskCount
)

$ErrorActionPreference = 'Stop'
$logFile = "C:\configure-sql-log.txt"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts - $Message" | Tee-Object -FilePath $logFile -Append
}

# ---------------------------------------------------------------------------
# 1. Open Windows Firewall for SQL Server (TCP 1433) from the VNet
# ---------------------------------------------------------------------------
if (-not (Get-NetFirewallRule -DisplayName 'SQL Server (TCP 1433)' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'SQL Server (TCP 1433)' -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow -Profile Domain,Private | Out-Null
    Write-Log "Firewall rule added: SQL Server TCP 1433"
} else {
    Write-Log "Firewall rule for SQL Server TCP 1433 already exists"
}

# ---------------------------------------------------------------------------
# 2. Initialize and format attached data disks
# ---------------------------------------------------------------------------
Write-Log "Initializing data disks (expecting $DiskCount)..."
$rawDisks = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' } | Sort-Object Number
$driveLetters = @('F', 'G', 'H', 'I', 'J')
$i = 0
foreach ($disk in $rawDisks) {
    $letter = $driveLetters[$i]
    Write-Log "Formatting disk $($disk.Number) as $($letter):"
    $disk | Initialize-Disk -PartitionStyle GPT -PassThru |
        New-Partition -DriveLetter $letter -UseMaximumSize |
        Format-Volume -FileSystem NTFS -NewFileSystemLabel "Data$i" -Confirm:$false
    $i++
}
Write-Log "Disk initialization complete. $i disk(s) formatted."

# If disks were already formatted from a previous run, count existing data drives
if ($i -eq 0) {
    Write-Log "No RAW disks found - checking for previously formatted data drives..."
    foreach ($letter in $driveLetters) {
        if (Test-Path "${letter}:\") { $i++ }
    }
    Write-Log "Found $i previously formatted data drive(s)."
}

# ---------------------------------------------------------------------------
# 2. Set up paths based on disk layout and misconfig flags
# ---------------------------------------------------------------------------
$misconfigList = $Misconfigs -split ','

# Default paths — use data disks when available
$dataPath  = "C:\SQLData"
$logPath   = "C:\SQLLog"
$tempPath  = "C:\SQLTempDB"
$backupDir = "C:\SQLBackups"

if ($i -ge 1) { $dataPath = "F:\SQLData"; $logPath = "F:\SQLLog"; $tempPath = "F:\SQLTempDB" }
if ($i -ge 2) { $logPath = "G:\SQLLog" }
if ($i -ge 3) { $tempPath = "H:\SQLTempDB" }

# Misconfig overrides: force data+log on same volume or tempdb on OS drive
if ($misconfigList -contains 'data_log_same_vol') {
    $logPath = $dataPath -replace 'SQLData', 'SQLLog'
}
if ($misconfigList -contains 'tempdb_os_drive') {
    $tempPath = "C:\SQLTempDB"
}

foreach ($dir in @($dataPath, $logPath, $tempPath, $backupDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

Write-Log "Paths: Data=$dataPath, Log=$logPath, TempDB=$tempPath, Backup=$backupDir"

# ---------------------------------------------------------------------------
# 3. Download sample database backups
# ---------------------------------------------------------------------------
$databaseList = $Databases -split ','
$downloads = @{}

if ($databaseList -contains 'adventureworks') {
    # Detect SQL Server major version to pick the correct backup
    $sqlVersionInfo = Invoke-Expression "sqlcmd -S localhost -E -Q `"SET NOCOUNT ON; SELECT SERVERPROPERTY('ProductMajorVersion')`" -h -1 -W" 2>&1
    $sqlMajorVersion = ($sqlVersionInfo | Where-Object { $_ -match '^\d+' } | Select-Object -First 1).Trim()
    Write-Log "Detected SQL Server major version: $sqlMajorVersion"

    if ($sqlMajorVersion -ge 16) {
        $downloads['AdventureWorks'] = @{
            Url     = 'https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2022.bak'
            BakFile = "$backupDir\AdventureWorks2022.bak"
            DbName  = 'AdventureWorks2022'
        }
    } else {
        $downloads['AdventureWorks'] = @{
            Url     = 'https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2019.bak'
            BakFile = "$backupDir\AdventureWorks2019.bak"
            DbName  = 'AdventureWorks2019'
        }
    }
}

if ($databaseList -contains 'worldwideimporters') {
    $downloads['WideWorldImporters'] = @{
        Url     = 'https://github.com/Microsoft/sql-server-samples/releases/download/wide-world-importers-v1.0/WideWorldImporters-Full.bak'
        BakFile = "$backupDir\WideWorldImporters-Full.bak"
        DbName  = 'WideWorldImporters'
    }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

foreach ($key in $downloads.Keys) {
    $dl = $downloads[$key]
    if (-not (Test-Path $dl.BakFile)) {
        Write-Log "Downloading $key backup..."
        Invoke-WebRequest -Uri $dl.Url -OutFile $dl.BakFile -UseBasicParsing
        Write-Log "Downloaded $key to $($dl.BakFile)"
    } else {
        Write-Log "$key backup already exists at $($dl.BakFile), skipping download."
    }
}

# ---------------------------------------------------------------------------
# 4. Ensure SqlServer module is available
# ---------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-Log "Installing SqlServer module..."
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue
    Install-Module -Name SqlServer -Force -AllowClobber -Scope AllUsers
}
Import-Module SqlServer -Force

$sqlInstance = "localhost"

# ---------------------------------------------------------------------------
# 5. Ensure SYSTEM has sysadmin access (CustomScriptExtension runs as SYSTEM)
# ---------------------------------------------------------------------------
$hasSysadmin = $false
try {
    $check = Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "SELECT IS_SRVROLEMEMBER('sysadmin') AS IsSA" -TrustServerCertificate -ErrorAction Stop
    if ($check.IsSA -eq 1) { $hasSysadmin = $true }
} catch {
    Write-Log "Cannot connect to SQL Server as sysadmin: $_"
}

if (-not $hasSysadmin) {
    Write-Log "SYSTEM does not have sysadmin - restarting SQL in single-user mode to fix..."

    # Stop SQL Agent first to prevent it grabbing the single-user connection
    Stop-Service SQLSERVERAGENT -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Stop-Service MSSQLSERVER -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5

    # Start SQL Server in single-user mode restricted to SQLCMD only
    & net start MSSQLSERVER /mSQLCMD 2>&1 | Out-Null
    Start-Sleep -Seconds 10

    # Add BUILTIN\Administrators to sysadmin (SYSTEM is a member)
    $retries = 0
    $success = $false
    while (-not $success -and $retries -lt 5) {
        $retries++
        Write-Log "Attempting to add sysadmin (attempt $retries)..."
        $result = & sqlcmd -S localhost -E -Q "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'BUILTIN\Administrators') CREATE LOGIN [BUILTIN\Administrators] FROM WINDOWS; EXEC sp_addsrvrolemember 'BUILTIN\Administrators', 'sysadmin'; IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'NT AUTHORITY\SYSTEM') CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS; EXEC sp_addsrvrolemember 'NT AUTHORITY\SYSTEM', 'sysadmin';" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $success = $true
            Write-Log "Added BUILTIN\Administrators to sysadmin role"
        } else {
            Write-Log "sqlcmd attempt $retries failed: $result"
            Start-Sleep -Seconds 5
        }
    }

    # Restart SQL Server normally
    & net stop MSSQLSERVER /y 2>&1 | Out-Null
    Start-Sleep -Seconds 5
    & net start MSSQLSERVER 2>&1 | Out-Null
    Start-Sleep -Seconds 5
    & net start SQLSERVERAGENT 2>&1 | Out-Null
    Start-Sleep -Seconds 10
    Write-Log "SQL Server restarted in normal mode"
}

# ---------------------------------------------------------------------------
# Ensure SQL Server is running in multi-user mode (not stuck from a prior run)
# ---------------------------------------------------------------------------
try {
    $userMode = Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "SELECT SERVERPROPERTY('IsSingleUser') AS IsSingle" -TrustServerCertificate -ErrorAction Stop
    if ($userMode.IsSingle -eq 1) {
        Write-Log "SQL Server is stuck in single-user mode - restarting normally..."
        & net stop MSSQLSERVER /y 2>&1 | Out-Null
        Start-Sleep -Seconds 5
        & net start MSSQLSERVER 2>&1 | Out-Null
        Start-Sleep -Seconds 5
        & net start SQLSERVERAGENT 2>&1 | Out-Null
        Start-Sleep -Seconds 10
        Write-Log "SQL Server restarted in multi-user mode"
    }
} catch {
    Write-Log "Could not check user mode, attempting restart..."
    & net stop MSSQLSERVER /y 2>&1 | Out-Null
    Start-Sleep -Seconds 5
    & net start MSSQLSERVER 2>&1 | Out-Null
    Start-Sleep -Seconds 5
    & net start SQLSERVERAGENT 2>&1 | Out-Null
    Start-Sleep -Seconds 10
}

# ---------------------------------------------------------------------------
# 5. Restore databases from backup
# ---------------------------------------------------------------------------
foreach ($key in $downloads.Keys) {
    $dl = $downloads[$key]
    $dbName = $dl.DbName

    $dbCheck = Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "SELECT DB_ID('$dbName') AS DbId" -TrustServerCertificate
    if ($null -ne $dbCheck.DbId -and $dbCheck.DbId -ne [DBNull]::Value) {
        Write-Log "Database $dbName already exists, skipping restore."
        continue
    }

    Write-Log "Restoring $dbName from $($dl.BakFile)..."

    # Get logical file names from backup
    $fileList = Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "RESTORE FILELISTONLY FROM DISK = '$($dl.BakFile)'" -TrustServerCertificate

    $moveStatements = @()
    foreach ($f in $fileList) {
        if ($f.Type -eq 'D') {
            $ext  = if ($f.FileId -eq 1) { '.mdf' } else { '.ndf' }
            $dest = Join-Path $dataPath "$($f.LogicalName)$ext"
        }
        elseif ($f.Type -eq 'L') {
            $dest = Join-Path $logPath "$($f.LogicalName).ldf"
        }
        elseif ($f.Type -eq 'S') {
            # Full-text catalog — place alongside data files
            $dest = Join-Path $dataPath $f.LogicalName
        }
        else {
            $dest = Join-Path $dataPath $f.LogicalName
        }
        $moveStatements += "MOVE '$($f.LogicalName)' TO '$dest'"
    }

    $moveClause = $moveStatements -join ",`n"
    $restoreQuery = @"
RESTORE DATABASE [$dbName]
FROM DISK = '$($dl.BakFile)'
WITH $moveClause,
REPLACE, RECOVERY
"@

    Write-Log "Running restore for $dbName..."
    Invoke-Sqlcmd -ServerInstance $sqlInstance -Query $restoreQuery -QueryTimeout 600 -TrustServerCertificate
    Write-Log "Restored $dbName successfully."
}

# ---------------------------------------------------------------------------
# 6. Create MisconfigDemo database with intentionally bad file settings
# ---------------------------------------------------------------------------
if ($databaseList -contains 'misconfigdemo') {
    $dbCheck = Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "SELECT DB_ID('MisconfigDemo') AS DbId" -TrustServerCertificate
    if ($null -eq $dbCheck.DbId -or $dbCheck.DbId -eq [DBNull]::Value) {
        Write-Log "Creating MisconfigDemo database with poor file settings..."

        # Intentionally place data and log in same folder, use percentage growth
        $misconfigDataFile = Join-Path $dataPath "MisconfigDemo.mdf"
        $misconfigLogFile  = Join-Path $dataPath "MisconfigDemo_log.ldf"

        $createDbQuery = @"
CREATE DATABASE [MisconfigDemo]
ON PRIMARY (
    NAME = N'MisconfigDemo',
    FILENAME = N'$misconfigDataFile',
    SIZE = 8MB,
    FILEGROWTH = 10%
)
LOG ON (
    NAME = N'MisconfigDemo_log',
    FILENAME = N'$misconfigLogFile',
    SIZE = 8MB,
    FILEGROWTH = 10%
);
"@
        Invoke-Sqlcmd -ServerInstance $sqlInstance -Query $createDbQuery -TrustServerCertificate

        # Create tables with sample data to simulate an OLTP workload
        $tablesQuery = @"
USE [MisconfigDemo];

CREATE TABLE dbo.Customers (
    CustomerID INT IDENTITY(1,1) PRIMARY KEY,
    FirstName NVARCHAR(50),
    LastName NVARCHAR(50),
    Email NVARCHAR(100),
    CreatedDate DATETIME DEFAULT GETDATE()
);

CREATE TABLE dbo.Orders (
    OrderID INT IDENTITY(1,1) PRIMARY KEY,
    CustomerID INT FOREIGN KEY REFERENCES dbo.Customers(CustomerID),
    OrderDate DATETIME DEFAULT GETDATE(),
    TotalAmount DECIMAL(18,2),
    Status NVARCHAR(20)
);

CREATE TABLE dbo.OrderItems (
    OrderItemID INT IDENTITY(1,1) PRIMARY KEY,
    OrderID INT FOREIGN KEY REFERENCES dbo.Orders(OrderID),
    ProductName NVARCHAR(100),
    Quantity INT,
    UnitPrice DECIMAL(18,2)
);

-- Insert sample data
SET NOCOUNT ON;

DECLARE @i INT = 1;
WHILE @i <= 1000
BEGIN
    INSERT INTO dbo.Customers (FirstName, LastName, Email)
    VALUES (
        CONCAT('First', @i),
        CONCAT('Last', @i),
        CONCAT('user', @i, '@example.com')
    );
    SET @i = @i + 1;
END;

DECLARE @j INT = 1;
WHILE @j <= 5000
BEGIN
    INSERT INTO dbo.Orders (CustomerID, OrderDate, TotalAmount, Status)
    VALUES (
        ABS(CHECKSUM(NEWID())) % 1000 + 1,
        DATEADD(DAY, -ABS(CHECKSUM(NEWID())) % 365, GETDATE()),
        ROUND(RAND(CHECKSUM(NEWID())) * 500, 2),
        CASE ABS(CHECKSUM(NEWID())) % 3
            WHEN 0 THEN 'Pending'
            WHEN 1 THEN 'Shipped'
            ELSE 'Delivered'
        END
    );
    SET @j = @j + 1;
END;
"@
        Invoke-Sqlcmd -ServerInstance $sqlInstance -Query $tablesQuery -QueryTimeout 120 -TrustServerCertificate
        Write-Log "MisconfigDemo database created with sample data."
    }
    else {
        Write-Log "MisconfigDemo database already exists, skipping."
    }
}

# ---------------------------------------------------------------------------
# 7. Apply instance-level misconfigurations
# ---------------------------------------------------------------------------
Write-Log "Applying misconfigurations: $Misconfigs"

$enableAdvanced = "EXEC sp_configure 'show advanced options', 1; RECONFIGURE;"

if ($misconfigList -contains 'maxdop_zero') {
    Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "$enableAdvanced EXEC sp_configure 'max degree of parallelism', 0; RECONFIGURE;" -TrustServerCertificate
    Write-Log "Set MAXDOP = 0"
}

if ($misconfigList -contains 'maxmem_default') {
    Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "$enableAdvanced EXEC sp_configure 'max server memory (MB)', 2147483647; RECONFIGURE;" -TrustServerCertificate
    Write-Log "Max server memory set to default (2147483647 MB)"
}

if ($misconfigList -contains 'ctp_default') {
    Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "$enableAdvanced EXEC sp_configure 'cost threshold for parallelism', 5; RECONFIGURE;" -TrustServerCertificate
    Write-Log "Cost threshold for parallelism set to 5 (default)"
}

if ($misconfigList -contains 'tempdb_one_file') {
    Write-Log "TempDB left with 1 file (default) - BPA will flag this"
}

if ($misconfigList -contains 'no_adhoc_opt') {
    Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "$enableAdvanced EXEC sp_configure 'optimize for ad hoc workloads', 0; RECONFIGURE;" -TrustServerCertificate
    Write-Log "optimize for ad hoc workloads disabled"
}

# ---------------------------------------------------------------------------
# 8. Apply database-level misconfigurations
# ---------------------------------------------------------------------------
$allUserDbs = Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "SELECT name FROM sys.databases WHERE database_id > 4" -TrustServerCertificate

foreach ($db in $allUserDbs) {
    $dbName = $db.name

    if ($misconfigList -contains 'auto_close') {
        Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "ALTER DATABASE [$dbName] SET AUTO_CLOSE ON;" -TrustServerCertificate
        Write-Log "AUTO_CLOSE ON for $dbName"
    }

    if ($misconfigList -contains 'auto_shrink') {
        Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "ALTER DATABASE [$dbName] SET AUTO_SHRINK ON;" -TrustServerCertificate
        Write-Log "AUTO_SHRINK ON for $dbName"
    }

    if ($misconfigList -contains 'page_verify_none') {
        Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "ALTER DATABASE [$dbName] SET PAGE_VERIFY NONE;" -TrustServerCertificate
        Write-Log "PAGE_VERIFY NONE for $dbName"
    }

    if ($misconfigList -contains 'recovery_simple') {
        Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "ALTER DATABASE [$dbName] SET RECOVERY SIMPLE;" -TrustServerCertificate
        Write-Log "RECOVERY SIMPLE for $dbName"
    }

    if ($misconfigList -contains 'filegrowth_pct') {
        $files = Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "SELECT name FROM [$dbName].sys.database_files WHERE type IN (0, 1)" -TrustServerCertificate
        foreach ($f in $files) {
            Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "ALTER DATABASE [$dbName] MODIFY FILE (NAME = '$($f.name)', FILEGROWTH = 10%);" -TrustServerCertificate
        }
        Write-Log "File growth set to 10% for all files in $dbName"
    }
}

# ---------------------------------------------------------------------------
# 9. Baseline VM — apply correct settings (sql-bpa-04)
# ---------------------------------------------------------------------------
if ($misconfigList -contains 'baseline') {
    Write-Log "Applying baseline (correct) configuration..."

    # Proper max memory — leave 4GB for OS on D4s_v5 (16GB RAM) => 12GB for SQL
    Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "$enableAdvanced EXEC sp_configure 'max server memory (MB)', 12288; RECONFIGURE;" -TrustServerCertificate
    Write-Log "Max server memory = 12288 MB"

    # MAXDOP = 4 for 4-vCPU VM
    Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "EXEC sp_configure 'max degree of parallelism', 4; RECONFIGURE;" -TrustServerCertificate
    Write-Log "MAXDOP = 4"

    # Cost threshold = 50
    Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "EXEC sp_configure 'cost threshold for parallelism', 50; RECONFIGURE;" -TrustServerCertificate
    Write-Log "Cost threshold for parallelism = 50"

    # Optimize for ad hoc workloads
    Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "EXEC sp_configure 'optimize for ad hoc workloads', 1; RECONFIGURE;" -TrustServerCertificate
    Write-Log "optimize for ad hoc workloads = 1"

    # Add tempdb files to match vCPU count (4) — skip if already added
    $existingTempFiles = Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "SELECT COUNT(*) AS cnt FROM tempdb.sys.database_files WHERE type = 0" -TrustServerCertificate
    if ($existingTempFiles.cnt -lt 4) {
        for ($t = ($existingTempFiles.cnt + 1); $t -le 4; $t++) {
            $tempFile = Join-Path $tempPath "tempdev$t.ndf"
            $addTempFileQuery = @"
ALTER DATABASE [tempdb] ADD FILE (
    NAME = N'tempdev$t',
    FILENAME = N'$tempFile',
    SIZE = 64MB,
    FILEGROWTH = 64MB
);
"@
            Invoke-Sqlcmd -ServerInstance $sqlInstance -Query $addTempFileQuery -TrustServerCertificate
        }
        Write-Log "TempDB expanded to 4 files"
    } else {
        Write-Log "TempDB already has $($existingTempFiles.cnt) data files, skipping"
    }

    # Set fixed file growth and PAGE_VERIFY CHECKSUM on all user databases
    $baselineDbs = Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "SELECT name FROM sys.databases WHERE database_id > 4" -TrustServerCertificate
    foreach ($db in $baselineDbs) {
        $files = Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "SELECT name FROM [$($db.name)].sys.database_files WHERE type IN (0, 1)" -TrustServerCertificate
        foreach ($f in $files) {
            Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "ALTER DATABASE [$($db.name)] MODIFY FILE (NAME = '$($f.name)', FILEGROWTH = 64MB);" -TrustServerCertificate
        }
        Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "ALTER DATABASE [$($db.name)] SET PAGE_VERIFY CHECKSUM;" -TrustServerCertificate
    }
    Write-Log "Baseline database settings applied (64MB growth, CHECKSUM)."
}

Write-Log "=== SQL configuration complete for $VmName ==="
