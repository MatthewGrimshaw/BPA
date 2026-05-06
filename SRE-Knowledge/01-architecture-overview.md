# SQL Best Practice Assessment (BPA) – Architecture Overview

## Purpose

This environment deploys and manages **SQL Server Best Practice Assessment** across two types of SQL Server workloads:

1. **Azure VMs** – SQL Server running on Azure IaaS virtual machines, managed via the SQL IaaS Agent Extension.
2. **Arc-enabled servers** – SQL Server running on-premises or in other clouds, connected to Azure via the Azure Connected Machine Agent (Azure Arc).

## Components

### Infrastructure (Terraform-managed)

| Resource | Name Pattern | Purpose |
|----------|-------------|---------|
| Resource Group | `{prefix}-rg` | Contains all resources |
| Log Analytics Workspace | `{prefix}-law` | Stores BPA assessment results and performance counter data |
| Data Collection Endpoint (DCE) | `{prefix}-dce` | Shared endpoint for all data uploads |
| BPA Data Collection Rule (DCR) | `{prefix}-bpa-dcr` | Ingests BPA CSV assessment results |
| Performance Counter DCR | `{prefix}-sql-perfcounters-dcr` | Collects 34 SQL Server performance counters |
| Azure VMs | `sql-bpa-01` through `sql-bpa-05` | SQL Server VMs with intentional misconfigurations for testing |
| VNet + Subnet | `{prefix}-vnet` / `{prefix}-sql-subnet` | Network isolation |
| Bastion | `{prefix}-bastion` | Secure RDP access without public IPs |
| Key Vault | `{prefix}-kv` | Stores admin credentials |
| Storage Account | `{prefix}scripts` | Hosts the SQL configuration script |

### Extensions & Agents on Azure VMs

| Agent / Extension | Purpose |
|-------------------|---------|
| **SQL IaaS Agent Extension** | Manages SQL Server on Azure VMs in Full mode |
| **Azure Monitor Agent (AMA)** | Collects performance counters and BPA CSV files |
| **CustomScriptExtension** | Runs `configure-sql.ps1` to set up databases and inject misconfigurations |

### Extensions & Agents on Arc-enabled Servers

| Agent / Extension | Purpose |
|-------------------|---------|
| **Azure Connected Machine Agent** | Connects the server to Azure Arc |
| **WindowsAgent.SqlServer** | Arc SQL extension – auto-provisioned after Arc onboarding |
| **Azure Monitor Agent (AMA)** | Collects performance counters and BPA CSV files |

## Data Flow

```
SQL Server VM/Arc Machine
  └─> BPA Assessment runs (scheduled or on-demand)
       └─> Writes CSV results to local disk
            └─> Azure Monitor Agent picks up CSV via DCR file_patterns
                 └─> Sends to DCE endpoint
                      └─> DCR transforms and routes to Log Analytics
                           └─> SqlAssessment_CL table (BPA results)
                           └─> Perf table (performance counters)
                                └─> Azure Workbook dashboards visualise data
```

## BPA CSV File Locations

The DCR monitors two paths for BPA result CSV files:

- **IaaS Agent path**: `C:\Windows\System32\config\systemprofile\AppData\Local\Microsoft SQL Server IaaS Agent\Assessment\*.csv`
- **Extension Agent path**: `C:\Windows\System32\config\systemprofile\AppData\Local\Microsoft SQL Server Extension Agent\Assessment\*.csv`

## Lab VM Configurations

| VM Name | VM Size | SQL Version | Intentional Misconfigurations |
|---------|---------|-------------|-------------------------------|
| sql-bpa-01 | Standard_B2ms | SQL 2022 | maxmem_default, maxdop_zero, ctp_default, tempdb_one_file, auto_shrink, tempdb_os_drive, no_adhoc_opt, filegrowth_pct, data_log_same_vol |
| sql-bpa-02 | Standard_D2s_v5 | SQL 2022 | maxmem_default, maxdop_zero, ctp_default, tempdb_one_file, filegrowth_pct, data_log_same_vol, no_adhoc_opt |
| sql-bpa-03 | Standard_E2s_v5 | SQL 2019 | maxmem_default, maxdop_zero, ctp_default, tempdb_one_file, auto_close, page_verify_none, tempdb_os_drive, no_adhoc_opt |
| sql-bpa-04 | Standard_D4s_v5 | SQL 2019 | baseline (correctly configured) |
| sql-bpa-05 | Standard_B4ms | SQL 2022 | maxmem_default, maxdop_zero, ctp_default, tempdb_one_file, auto_shrink, recovery_simple, filegrowth_pct, data_log_same_vol, no_adhoc_opt |
