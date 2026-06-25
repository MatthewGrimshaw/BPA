<#
.SYNOPSIS
    Creates all Azure Monitor Scheduled Query Alert rules for the SQL BPA environment.

.DESCRIPTION
    Deploys 22 alert rules across five categories:
      - SQL Performance Critical (Severity 1)
      - SQL Performance Warning (Severity 2)
      - BPA Assessment Health (Severity 2-3)
      - Agent & Data Pipeline Health (Severity 1-2)
      - Capacity & Informational (Severity 3)

    The script reads configuration from terraform/terraform.tfvars by default so
    resource group and workspace names stay consistent with the Terraform deployment.

    All alerts target the Log Analytics workspace as scheduled query rules.

.PARAMETER ResourceGroupName
    The resource group containing the Log Analytics workspace. Defaults to {prefix}-rg
    from terraform.tfvars.

.PARAMETER WorkspaceName
    The Log Analytics workspace name. Defaults to {prefix}-law from terraform.tfvars.

.PARAMETER ActionGroupEmail
    Email address for the alert action group. Default: dba@company.com.

.PARAMETER ActionGroupName
    Name of the action group to create or reuse. Default: SQL-BPA-Alerts.

.PARAMETER RemoveExisting
    When specified, removes all alert rules created by this script before recreating.

.PARAMETER WhatIf
    Shows what would be created without actually creating anything.

.EXAMPLE
    .\Create-SqlAlerts.ps1

.EXAMPLE
    .\Create-SqlAlerts.ps1 -ActionGroupEmail "ops-team@contoso.com"

.EXAMPLE
    .\Create-SqlAlerts.ps1 -RemoveExisting

.NOTES
    Prerequisites:
      - Azure CLI (az) installed and authenticated
      - Contributor role on the resource group
      - Log Analytics workspace must already exist
      - The workspace must be receiving data (Perf, Heartbeat, SqlAssessment_CL tables)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ResourceGroupName,
    [string]$WorkspaceName,
    [string]$ActionGroupEmail = "dba@company.com",
    [string]$ActionGroupName = "SQL-BPA-Alerts",
    [switch]$RemoveExisting
)

$ErrorActionPreference = "Stop"

# ── Read defaults from terraform.tfvars ──────────────────────────────────────

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
$tfvarsPath = Join-Path $scriptRoot "terraform" "terraform.tfvars"

if (Test-Path $tfvarsPath) {
    $tfvars = @{}
    Get-Content $tfvarsPath | ForEach-Object {
        if ($_ -match '^\s*(\w+)\s*=\s*"([^"]*)"') {
            $tfvars[$Matches[1]] = $Matches[2]
        }
    }
    $prefix = $tfvars['prefix']
    if (-not $ResourceGroupName) { $ResourceGroupName = "$prefix-rg" }
    if (-not $WorkspaceName) { $WorkspaceName = "$prefix-law" }
} else {
    if (-not $ResourceGroupName -or -not $WorkspaceName) {
        Write-Error "terraform.tfvars not found and -ResourceGroupName / -WorkspaceName not provided."
        exit 1
    }
}

Write-Host "Configuration:" -ForegroundColor Cyan
Write-Host "  Resource Group : $ResourceGroupName"
Write-Host "  Workspace      : $WorkspaceName"
Write-Host "  Action Group   : $ActionGroupName"
Write-Host "  Email          : $ActionGroupEmail"
Write-Host ""

# ── Resolve workspace resource ID ────────────────────────────────────────────

Write-Host "Resolving Log Analytics workspace..." -ForegroundColor Cyan
$workspaceId = az monitor log-analytics workspace show `
    --resource-group $ResourceGroupName `
    --workspace-name $WorkspaceName `
    --query id -o tsv 2>$null

if (-not $workspaceId) {
    Write-Error "Log Analytics workspace '$WorkspaceName' not found in resource group '$ResourceGroupName'."
    exit 1
}
Write-Host "  Workspace ID: $workspaceId" -ForegroundColor Green

# ── Define all alert rules ───────────────────────────────────────────────────

# Alert naming convention: SQL-BPA-{##}-{ShortName}-{Severity}
# This makes them easy to list, sort, and identify in the portal.

$alerts = @(
    # ── Category 1: SQL Performance Critical (Severity 1) ──
    @{
        Name        = "SQL-BPA-01-PLE-Critical"
        Description = "Page life expectancy below 300 seconds - severe memory pressure. Check max server memory setting and memory-intensive queries."
        Severity    = 1
        Window      = "5m"
        Eval        = "5m"
        Condition   = "avg AggregatedValue < 300"
        Query       = "Perf | where CounterName == 'Page life expectancy' | summarize AggregatedValue = avg(CounterValue) by Computer"
    },
    @{
        Name        = "SQL-BPA-02-Deadlocks-Critical"
        Description = "Deadlocks detected on SQL Server. Capture deadlock graphs via Extended Events and review transaction ordering."
        Severity    = 1
        Window      = "5m"
        Eval        = "5m"
        Condition   = "sum AggregatedValue > 0"
        Query       = "Perf | where CounterName == 'Number of Deadlocks/sec' | summarize AggregatedValue = sum(CounterValue) by Computer"
    },
    @{
        Name        = "SQL-BPA-03-CPU-Critical"
        Description = "CPU above 95% sustained. Check top CPU queries via sys.dm_exec_query_stats, MAXDOP settings, and missing indexes."
        Severity    = 1
        Window      = "10m"
        Eval        = "5m"
        Condition   = "avg AggregatedValue > 95"
        Query       = "Perf | where CounterName == '% Processor Time' and InstanceName == '_Total' | summarize AggregatedValue = avg(CounterValue) by Computer"
    },
    @{
        Name        = "SQL-BPA-04-DiskLatency-Critical"
        Description = "Disk latency above 25ms. Check disk queue length, IOPS limits, and storage tier."
        Severity    = 1
        Window      = "10m"
        Eval        = "5m"
        Condition   = "avg AggregatedValue > 25"
        Query       = "Perf | where CounterName in ('Avg. Disk sec/Read', 'Avg. Disk sec/Write') | extend LatencyMs = CounterValue * 1000 | summarize AggregatedValue = avg(LatencyMs) by Computer, CounterName"
    },
    @{
        Name        = "SQL-BPA-05-OSMemory-Critical"
        Description = "Available OS memory below 512 MB. Check SQL max server memory setting. Leave at least 4 GB for the OS."
        Severity    = 1
        Window      = "10m"
        Eval        = "5m"
        Condition   = "avg AggregatedValue < 512"
        Query       = "Perf | where CounterName == 'Available MBytes' | summarize AggregatedValue = avg(CounterValue) by Computer"
    },

    # ── Category 4: Agent Health Critical (Severity 1) ──
    @{
        Name        = "SQL-BPA-06-AMA-Heartbeat-Missing"
        Description = "Azure Monitor Agent heartbeat missing for 10+ minutes. Check if the VM is running and AMA extension status."
        Severity    = 1
        Window      = "10m"
        Eval        = "5m"
        Condition   = "count AggregatedValue > 0"
        Query       = "Heartbeat | summarize LastBeat = max(TimeGenerated) by Computer | where LastBeat < ago(10m) | summarize AggregatedValue = count()"
    },
    @{
        Name        = "SQL-BPA-07-Arc-Disconnected"
        Description = "Arc agent disconnected for 15+ minutes. Check network (HTTPS 443), proxy settings, and himds service."
        Severity    = 1
        Window      = "15m"
        Eval        = "5m"
        Condition   = "count AggregatedValue > 0"
        Query       = "Heartbeat | where ResourceProvider == 'Microsoft.HybridCompute' | summarize LastBeat = max(TimeGenerated) by Computer | where LastBeat < ago(15m) | summarize AggregatedValue = count()"
    },

    # ── Category 2: SQL Performance Warning (Severity 2) ──
    @{
        Name        = "SQL-BPA-08-CPU-Warning"
        Description = "CPU above 80% sustained. Monitor for trending and consider scaling or query optimization."
        Severity    = 2
        Window      = "15m"
        Eval        = "5m"
        Condition   = "avg AggregatedValue > 80"
        Query       = "Perf | where CounterName == '% Processor Time' and InstanceName == '_Total' | summarize AggregatedValue = avg(CounterValue) by Computer"
    },
    @{
        Name        = "SQL-BPA-09-BufferCache-Warning"
        Description = "Buffer cache hit ratio below 95%. Indicates memory pressure - review max server memory and query memory grants."
        Severity    = 2
        Window      = "15m"
        Eval        = "5m"
        Condition   = "avg AggregatedValue < 95"
        Query       = "Perf | where CounterName == 'Buffer cache hit ratio' | summarize AggregatedValue = avg(CounterValue) by Computer"
    },
    @{
        Name        = "SQL-BPA-10-DiskLatency-Warning"
        Description = "Disk latency above 15ms. Storage may be a bottleneck."
        Severity    = 2
        Window      = "10m"
        Eval        = "5m"
        Condition   = "avg AggregatedValue > 15"
        Query       = "Perf | where CounterName in ('Avg. Disk sec/Read', 'Avg. Disk sec/Write') | extend LatencyMs = CounterValue * 1000 | summarize AggregatedValue = avg(LatencyMs) by Computer, CounterName"
    },
    @{
        Name        = "SQL-BPA-11-Recompilations-Warning"
        Description = "SQL recompilations above 50/sec. Check for schema changes, statistics updates, or temp table reuse patterns."
        Severity    = 2
        Window      = "15m"
        Eval        = "5m"
        Condition   = "avg AggregatedValue > 50"
        Query       = "Perf | where CounterName == 'SQL Re-Compilations/sec' | summarize AggregatedValue = avg(CounterValue) by Computer"
    },
    @{
        Name        = "SQL-BPA-12-Blocking-Warning"
        Description = "More than 3 blocked processes detected. Investigate blocking chains with sys.dm_exec_requests."
        Severity    = 2
        Window      = "10m"
        Eval        = "5m"
        Condition   = "avg AggregatedValue > 3"
        Query       = "Perf | where CounterName == 'Processes blocked' | summarize AggregatedValue = avg(CounterValue) by Computer"
    },
    @{
        Name        = "SQL-BPA-13-LockWaits-Warning"
        Description = "Lock waits above 10/sec. Applications are contending for locks - review transaction isolation and query patterns."
        Severity    = 2
        Window      = "10m"
        Eval        = "5m"
        Condition   = "avg AggregatedValue > 10"
        Query       = "Perf | where CounterName == 'Lock Waits/sec' | summarize AggregatedValue = avg(CounterValue) by Computer"
    },
    @{
        Name        = "SQL-BPA-14-FullScans-Warning"
        Description = "Full table/index scans above 100/sec. Likely missing indexes - review execution plans."
        Severity    = 2
        Window      = "15m"
        Eval        = "5m"
        Condition   = "avg AggregatedValue > 100"
        Query       = "Perf | where CounterName == 'Full Scans/sec' | summarize AggregatedValue = avg(CounterValue) by Computer"
    },
    @{
        Name        = "SQL-BPA-15-MemoryPressure-Warning"
        Description = "Available OS memory below 1024 MB. System approaching memory exhaustion."
        Severity    = 2
        Window      = "15m"
        Eval        = "5m"
        Condition   = "avg AggregatedValue < 1024"
        Query       = "Perf | where CounterName == 'Available MBytes' | summarize AggregatedValue = avg(CounterValue) by Computer"
    },
    @{
        Name        = "SQL-BPA-16-DiskQueue-Warning"
        Description = "Average disk queue length above 2. I/O subsystem may be saturated."
        Severity    = 2
        Window      = "10m"
        Eval        = "5m"
        Condition   = "avg AggregatedValue > 2"
        Query       = "Perf | where CounterName == 'Avg. Disk Queue Length' | summarize AggregatedValue = avg(CounterValue) by Computer, InstanceName"
    },

    # ── Category 3: BPA Assessment Health (Severity 2-3) ──
    @{
        Name        = "SQL-BPA-17-StaleAssessment"
        Description = "No BPA assessment run in 7+ days. Check assessment schedule, DCR associations, and AMA health."
        Severity    = 2
        Window      = "1440m"
        Eval        = "1440m"
        Condition   = "count AggregatedValue > 0"
        Query       = "SqlAssessment_CL | summarize LastSeen = max(TimeGenerated) by Computer = tostring(split(RawData, ',')[0]) | where LastSeen < ago(7d) | summarize AggregatedValue = count()"
    },

    # ── Category 4: Agent Health Warning (Severity 2) ──
    @{
        Name        = "SQL-BPA-18-PerfCounterGap"
        Description = "No SQL performance counter data in 30+ minutes. Check perf DCR association and AMA health."
        Severity    = 2
        Window      = "30m"
        Eval        = "15m"
        Condition   = "count AggregatedValue > 0"
        Query       = "Perf | where ObjectName startswith 'SQLServer:' | summarize LastSeen = max(TimeGenerated) by Computer | where LastSeen < ago(30m) | summarize AggregatedValue = count()"
    },

    # ── Category 5: Capacity & Informational (Severity 3) ──
    @{
        Name        = "SQL-BPA-19-PageSplits-Info"
        Description = "Page splits above 100/sec. Review index fill factors and rebuild fragmented indexes."
        Severity    = 3
        Window      = "15m"
        Eval        = "5m"
        Condition   = "avg AggregatedValue > 100"
        Query       = "Perf | where CounterName == 'Page Splits/sec' | summarize AggregatedValue = avg(CounterValue) by Computer"
    },
    @{
        Name        = "SQL-BPA-20-MemoryPaging-Info"
        Description = "Memory pages/sec above 50. OS is actively paging - review SQL max server memory and total RAM."
        Severity    = 3
        Window      = "10m"
        Eval        = "5m"
        Condition   = "avg AggregatedValue > 50"
        Query       = "Perf | where CounterName == 'Pages/sec' | summarize AggregatedValue = avg(CounterValue) by Computer"
    },
    @{
        Name        = "SQL-BPA-21-BPA-FindingsSpike"
        Description = "BPA findings spike - more than 20 failed recommendations. A config change may have regressed SQL settings."
        Severity    = 3
        Window      = "1440m"
        Eval        = "1440m"
        Condition   = "max AggregatedValue > 20"
        Query       = "SQLAssessmentRecommendation | where TimeGenerated > ago(1d) | where RecommendationResult == 'Failed' | summarize AggregatedValue = count() by Computer"
    },
    @{
        Name        = "SQL-BPA-22-HighConnections-Info"
        Description = "More than 500 concurrent user connections. Check for connection pool exhaustion or connection leaks."
        Severity    = 3
        Window      = "15m"
        Eval        = "5m"
        Condition   = "max AggregatedValue > 500"
        Query       = "Perf | where CounterName == 'User Connections' | summarize AggregatedValue = max(CounterValue) by Computer"
    }
)

# ── Remove existing alerts if requested ──────────────────────────────────────

if ($RemoveExisting) {
    Write-Host "Removing existing SQL-BPA alert rules..." -ForegroundColor Yellow
    $existing = az monitor scheduled-query list --resource-group $ResourceGroupName --query "[?starts_with(name,'SQL-BPA-')].name" -o tsv 2>$null
    if ($existing) {
        foreach ($name in $existing) {
            Write-Host "  Deleting $name..." -ForegroundColor Gray
            az monitor scheduled-query delete --name $name --resource-group $ResourceGroupName --yes 2>&1 | Out-Null
        }
        Write-Host "  Removed $($existing.Count) alert rules." -ForegroundColor Green
    } else {
        Write-Host "  No existing SQL-BPA alert rules found." -ForegroundColor Gray
    }
    Write-Host ""
}

# ── Create or update action group ────────────────────────────────────────────

Write-Host "Creating action group '$ActionGroupName'..." -ForegroundColor Cyan
az monitor action-group create `
    --name $ActionGroupName `
    --resource-group $ResourceGroupName `
    --short-name "SQLBPA" `
    --email-receiver "DBA Team" $ActionGroupEmail 2>&1 | Out-Null

$actionGroupId = az monitor action-group show `
    --name $ActionGroupName `
    --resource-group $ResourceGroupName `
    --query id -o tsv

if (-not $actionGroupId) {
    Write-Error "Failed to create or find action group '$ActionGroupName'."
    exit 1
}
Write-Host "  Action Group ID: $actionGroupId" -ForegroundColor Green
Write-Host ""

# ── Create all alert rules ───────────────────────────────────────────────────

$created = 0
$failed  = 0
$total   = $alerts.Count

Write-Host "Creating $total alert rules..." -ForegroundColor Cyan
Write-Host "─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

foreach ($alert in $alerts) {
    $num = $alerts.IndexOf($alert) + 1
    $severityLabel = switch ($alert.Severity) { 1 { "Crit" } 2 { "Warn" } 3 { "Info" } }
    Write-Host "  [$num/$total] $($alert.Name) ($severityLabel)..." -ForegroundColor Yellow -NoNewline

    if ($PSCmdlet.ShouldProcess($alert.Name, "Create scheduled query alert")) {
        try {
            az monitor scheduled-query create `
                --name $alert.Name `
                --resource-group $ResourceGroupName `
                --scopes $workspaceId `
                --condition $alert.Condition `
                --condition-query $alert.Query `
                --description $alert.Description `
                --evaluation-frequency $alert.Eval `
                --window-size $alert.Window `
                --severity $alert.Severity `
                --action-groups $actionGroupId 2>&1 | Out-Null

            if ($LASTEXITCODE -eq 0) {
                Write-Host " ✓" -ForegroundColor Green
                $created++
            } else {
                Write-Host " ✗ (az exit code $LASTEXITCODE)" -ForegroundColor Red
                $failed++
            }
        } catch {
            Write-Host " ✗ ($($_.Exception.Message))" -ForegroundColor Red
            $failed++
        }
    }
}

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "Results: $created created, $failed failed, $total total" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Yellow" })
Write-Host ""
Write-Host "Alert breakdown:" -ForegroundColor Cyan
Write-Host "  Severity 1 (Critical) : $($alerts.Where({ $_.Severity -eq 1 }).Count) rules"
Write-Host "  Severity 2 (Warning)  : $($alerts.Where({ $_.Severity -eq 2 }).Count) rules"
Write-Host "  Severity 3 (Info)     : $($alerts.Where({ $_.Severity -eq 3 }).Count) rules"
Write-Host ""
Write-Host "View alerts: https://portal.azure.com/#blade/Microsoft_Azure_Monitoring/AzureMonitoringBrowseBlade/alertsV2" -ForegroundColor Cyan

# ── Verify ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Verifying deployed alerts..." -ForegroundColor Cyan
$deployed = az monitor scheduled-query list --resource-group $ResourceGroupName --query "[?starts_with(name,'SQL-BPA-')].{Name:name, Severity:severity, Enabled:enabled}" -o table 2>$null
if ($deployed) {
    Write-Host $deployed
}
