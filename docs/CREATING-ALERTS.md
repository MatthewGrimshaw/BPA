# Creating Alerts for SQL Server Performance Counters

This guide shows how to create Azure Monitor alerts for the SQL Server performance counters being collected.

## Using Azure Portal

### 1. Create Buffer Cache Hit Ratio Alert

```bash
# Via Azure CLI
az monitor metrics alert create \
  --name "SQL Buffer Cache Hit Ratio Low" \
  --resource-group sql-bpa-lab-rg \
  --scopes /subscriptions/{subscription-id}/resourceGroups/sql-bpa-lab-rg/providers/Microsoft.OperationalInsights/workspaces/sql-bpa-law \
  --condition "avg Perf | where CounterName == 'Buffer cache hit ratio' | summarize AggregatedValue = avg(CounterValue) < 95" \
  --window-size 5m \
  --evaluation-frequency 5m \
  --severity 2 \
  --description "Buffer cache hit ratio below 95% indicates memory pressure"
```

### 2. Create Scheduled Query Alert (Recommended Approach)

```bash
# Create action group first (for notifications)
az monitor action-group create \
  --name "SQL-Alerts" \
  --resource-group sql-bpa-lab-rg \
  --short-name "SQLAlert" \
  --email-receiver "DBA Team" dba@company.com

# Get the action group ID
ACTION_GROUP_ID=$(az monitor action-group show \
  --name "SQL-Alerts" \
  --resource-group sql-bpa-lab-rg \
  --query id -o tsv)

# Create scheduled query alert for Buffer Cache Hit Ratio
az monitor scheduled-query create \
  --name "Low Buffer Cache Hit Ratio" \
  --resource-group sql-bpa-lab-rg \
  --scopes /subscriptions/{subscription-id}/resourceGroups/sql-bpa-lab-rg/providers/Microsoft.OperationalInsights/workspaces/sql-bpa-law \
  --condition "avg CounterValue < 95" \
  --condition-query "Perf | where CounterName == 'Buffer cache hit ratio' | summarize AggregatedValue = avg(CounterValue) by Computer" \
  --description "Buffer cache hit ratio below 95%" \
  --evaluation-frequency 5m \
  --window-size 15m \
  --severity 2 \
  --action-groups $ACTION_GROUP_ID
```

## Recommended Alert Rules

### Critical Alerts (Severity 1)

#### 1. Severe Memory Pressure
```kql
Perf
| where CounterName == "Page life expectancy"
| summarize AvgPLE = avg(CounterValue) by Computer
| where AvgPLE < 300
```
**Threshold:** < 300 seconds  
**Window:** 5 minutes  
**Action:** Immediate investigation

#### 2. Deadlocks Detected
```kql
Perf
| where CounterName == "Number of Deadlocks/sec"
| where CounterValue > 0
| summarize DeadlockCount = sum(CounterValue) by Computer
```
**Threshold:** > 0  
**Window:** 5 minutes  
**Action:** Review application code

#### 3. Critical CPU
```kql
Perf
| where CounterName == "% Processor Time" and InstanceName == "_Total"
| summarize AvgCPU = avg(CounterValue) by Computer
| where AvgCPU > 90
```
**Threshold:** > 90%  
**Window:** 10 minutes  
**Action:** Immediate investigation

### Warning Alerts (Severity 2)

#### 4. High CPU
```kql
Perf
| where CounterName == "% Processor Time" and InstanceName == "_Total"
| summarize AvgCPU = avg(CounterValue) by Computer
| where AvgCPU > 80
```
**Threshold:** > 80%  
**Window:** 15 minutes

#### 5. Low Buffer Cache Hit Ratio
```kql
Perf
| where CounterName == "Buffer cache hit ratio"
| summarize AvgBCHR = avg(CounterValue) by Computer
| where AvgBCHR < 95
```
**Threshold:** < 95%  
**Window:** 10 minutes

#### 6. High Disk Latency
```kql
Perf
| where CounterName in ("Avg. Disk sec/Read", "Avg. Disk sec/Write")
| extend LatencyMs = CounterValue * 1000
| summarize AvgLatency = avg(LatencyMs) by Computer, CounterName
| where AvgLatency > 20
```
**Threshold:** > 20ms  
**Window:** 10 minutes

#### 7. Excessive Recompilations
```kql
Perf
| where CounterName == "SQL Re-Compilations/sec"
| summarize AvgRecomp = avg(CounterValue) by Computer
| where AvgRecomp > 10
```
**Threshold:** > 10 per second  
**Window:** 5 minutes

### Informational Alerts (Severity 3)

#### 8. High Page Splits
```kql
Perf
| where CounterName == "Page Splits/sec"
| summarize AvgPageSplits = avg(CounterValue) by Computer
| where AvgPageSplits > 20
```
**Threshold:** > 20 per second  
**Window:** 15 minutes

#### 9. Memory Pages/sec
```kql
Perf
| where CounterName == "Pages/sec"
| summarize AvgPages = avg(CounterValue) by Computer
| where AvgPages > 5
```
**Threshold:** > 5  
**Window:** 10 minutes

## PowerShell Script to Create All Alerts

Save this as `Create-SqlAlerts.ps1`:

```powershell
param(
    [string]$ResourceGroup = "sql-bpa-lab-rg",
    [string]$WorkspaceName = "sql-bpa-law",
    [string]$ActionGroupEmail = "dba@company.com"
)

$workspaceId = az monitor log-analytics workspace show `
    --resource-group $ResourceGroup `
    --workspace-name $WorkspaceName `
    --query id -o tsv

# Create action group
Write-Host "Creating action group..." -ForegroundColor Cyan
az monitor action-group create `
    --name "SQL-Performance-Alerts" `
    --resource-group $ResourceGroup `
    --short-name "SQLPerf" `
    --email-receiver "DBA Team" $ActionGroupEmail

$actionGroupId = az monitor action-group show `
    --name "SQL-Performance-Alerts" `
    --resource-group $ResourceGroup `
    --query id -o tsv

# Alert 1: Low Page Life Expectancy
Write-Host "Creating Page Life Expectancy alert..." -ForegroundColor Yellow
az monitor scheduled-query create `
    --name "Critical - Low Page Life Expectancy" `
    --resource-group $ResourceGroup `
    --scopes $workspaceId `
    --condition "avg CounterValue < 300" `
    --condition-query "Perf | where CounterName == 'Page life expectancy' | summarize AggregatedValue = avg(CounterValue) by Computer" `
    --description "Page life expectancy below 300 seconds indicates severe memory pressure" `
    --evaluation-frequency 5m `
    --window-size 15m `
    --severity 1 `
    --action-groups $actionGroupId

# Alert 2: Deadlocks
Write-Host "Creating Deadlock alert..." -ForegroundColor Yellow
az monitor scheduled-query create `
    --name "Critical - Deadlocks Detected" `
    --resource-group $ResourceGroup `
    --scopes $workspaceId `
    --condition "sum CounterValue > 0" `
    --condition-query "Perf | where CounterName == 'Number of Deadlocks/sec' | summarize AggregatedValue = sum(CounterValue) by Computer" `
    --description "Deadlocks detected on SQL Server" `
    --evaluation-frequency 5m `
    --window-size 5m `
    --severity 1 `
    --action-groups $actionGroupId

# Alert 3: High CPU
Write-Host "Creating High CPU alert..." -ForegroundColor Yellow
az monitor scheduled-query create `
    --name "Warning - High CPU Usage" `
    --resource-group $ResourceGroup `
    --scopes $workspaceId `
    --condition "avg CounterValue > 80" `
    --condition-query "Perf | where CounterName == '% Processor Time' and InstanceName == '_Total' | summarize AggregatedValue = avg(CounterValue) by Computer" `
    --description "CPU usage above 80% for extended period" `
    --evaluation-frequency 5m `
    --window-size 15m `
    --severity 2 `
    --action-groups $actionGroupId

# Alert 4: Low Buffer Cache Hit Ratio
Write-Host "Creating Buffer Cache Hit Ratio alert..." -ForegroundColor Yellow
az monitor scheduled-query create `
    --name "Warning - Low Buffer Cache Hit Ratio" `
    --resource-group $ResourceGroup `
    --scopes $workspaceId `
    --condition "avg CounterValue < 95" `
    --condition-query "Perf | where CounterName == 'Buffer cache hit ratio' | summarize AggregatedValue = avg(CounterValue) by Computer" `
    --description "Buffer cache hit ratio below 95%" `
    --evaluation-frequency 5m `
    --window-size 10m `
    --severity 2 `
    --action-groups $actionGroupId

# Alert 5: High Disk Latency
Write-Host "Creating Disk Latency alert..." -ForegroundColor Yellow
az monitor scheduled-query create `
    --name "Warning - High Disk Latency" `
    --resource-group $ResourceGroup `
    --scopes $workspaceId `
    --condition "avg LatencyMs > 20" `
    --condition-query "Perf | where CounterName in ('Avg. Disk sec/Read', 'Avg. Disk sec/Write') | extend LatencyMs = CounterValue * 1000 | summarize AggregatedValue = avg(LatencyMs) by Computer" `
    --description "Disk latency above 20ms" `
    --evaluation-frequency 5m `
    --window-size 10m `
    --severity 2 `
    --action-groups $actionGroupId

Write-Host "`nAll alerts created successfully!" -ForegroundColor Green
Write-Host "View alerts at: https://portal.azure.com/#blade/Microsoft_Azure_Monitoring/AzureMonitoringBrowseBlade/alertsV2" -ForegroundColor Cyan
```

## Testing Alerts

### Manually trigger an alert test:

```bash
# List all alert rules
az monitor scheduled-query list \
  --resource-group sql-bpa-lab-rg \
  --output table

# View alert rule details
az monitor scheduled-query show \
  --name "Warning - High CPU Usage" \
  --resource-group sql-bpa-lab-rg

# View fired alerts
az monitor metrics alert list \
  --resource-group sql-bpa-lab-rg
```

## Azure Portal Steps

For those who prefer the portal:

1. Navigate to your Log Analytics workspace
2. Click **Alerts** in the left menu
3. Click **+ Create** → **Alert rule**
4. **Scope**: Select your Log Analytics workspace
5. **Condition**: Click **Add condition**
   - Signal type: **Custom log search**
   - Paste one of the KQL queries above
   - Set threshold and evaluation frequency
6. **Actions**: Select or create an action group
7. **Details**: Name, severity, description
8. Click **Create alert rule**

## Best Practices

1. **Start with Critical Alerts**: Implement deadlock and severe memory pressure alerts first
2. **Tune Thresholds**: Adjust based on your baseline performance
3. **Use Action Groups**: Group related alerts to avoid notification fatigue
4. **Set Proper Severity**: Don't make everything critical
5. **Include Runbooks**: Link remediation steps in alert descriptions
6. **Monitor Alert Effectiveness**: Review and adjust based on false positives

## Cost Optimization

- **Evaluation Frequency**: Default 5-minute intervals balance cost and detection speed
- **Log Query Alerts**: Charged per evaluation (~$0.10 per rule per month for 5-minute evaluations)
- **Action Groups**: Email notifications are free; SMS and voice calls have charges

## Viewing Active Alerts

```kql
// Query alert history in Log Analytics
AlertEvidence
| where TimeGenerated > ago(7d)
| summarize count() by AlertName, AlertSeverity
| order by count_ desc
```

## Integration with Azure Workbooks

Create a custom Workbook to display:
- Current alert status
- Alert history trends
- Performance metrics alongside alert thresholds
- See `PERFORMANCE-COUNTERS.md` for KQL query examples
