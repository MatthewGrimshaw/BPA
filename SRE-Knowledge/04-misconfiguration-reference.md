# SQL Server Misconfiguration Reference

This document lists the SQL Server misconfigurations that BPA detects and how to identify and remediate each one. These are the same misconfigurations intentionally injected into the lab environment for testing.

---

## Misconfiguration: maxmem_default

**What it means**: SQL Server `max server memory` is left at the default value (2,147,483,647 MB), meaning SQL Server can consume all available system memory, starving the OS and other processes.

**BPA rule**: "Max server memory option should be set to reduce the risk of memory pressure."

**How to detect**:
```sql
SELECT name, value_in_use FROM sys.configurations WHERE name = 'max server memory (MB)';
-- If value_in_use = 2147483647, it's at default
```

**Remediation**: Set max memory to ~80% of total physical memory (leave at least 4 GB for the OS):
```sql
EXEC sp_configure 'max server memory (MB)', <value>;
RECONFIGURE;
```

---

## Misconfiguration: maxdop_zero

**What it means**: `max degree of parallelism` is set to 0, allowing SQL Server to use all available processors for parallel queries, which can cause excessive CXPACKET waits.

**BPA rule**: "Configure max degree of parallelism to improve performance."

**How to detect**:
```sql
SELECT name, value_in_use FROM sys.configurations WHERE name = 'max degree of parallelism';
-- If value_in_use = 0, it uses all processors
```

**Remediation**: Set MAXDOP based on the number of NUMA nodes and cores (Microsoft recommendation: 8 or fewer):
```sql
EXEC sp_configure 'max degree of parallelism', 4; -- adjust based on CPU cores
RECONFIGURE;
```

---

## Misconfiguration: ctp_default

**What it means**: `cost threshold for parallelism` is at the default value of 5, which is too low for most workloads, causing queries that could run faster serially to use parallelism unnecessarily.

**BPA rule**: "Consider increasing the cost threshold for parallelism."

**How to detect**:
```sql
SELECT name, value_in_use FROM sys.configurations WHERE name = 'cost threshold for parallelism';
-- Default = 5, recommendation = 25-50
```

**Remediation**:
```sql
EXEC sp_configure 'cost threshold for parallelism', 50;
RECONFIGURE;
```

---

## Misconfiguration: tempdb_one_file

**What it means**: TempDB has only one data file. Multiple TempDB files (one per CPU core up to 8) reduce allocation contention.

**BPA rule**: "TempDB should have multiple data files for better performance."

**How to detect**:
```sql
SELECT COUNT(*) AS FileCount FROM sys.master_files WHERE database_id = 2 AND type = 0;
-- If FileCount = 1, only one data file
```

**Remediation**: Add TempDB data files (equal size, same growth settings):
```sql
ALTER DATABASE tempdb ADD FILE (NAME = N'tempdev2', FILENAME = N'T:\tempdb\tempdev2.ndf', SIZE = 256MB, FILEGROWTH = 64MB);
-- Repeat for each additional file
```

---

## Misconfiguration: auto_shrink

**What it means**: `AUTO_SHRINK` is enabled on one or more databases. This causes frequent shrink/grow cycles leading to fragmentation and I/O overhead.

**BPA rule**: "Disable auto shrink on user and model databases."

**How to detect**:
```sql
SELECT name, is_auto_shrink_on FROM sys.databases WHERE is_auto_shrink_on = 1;
```

**Remediation**:
```sql
ALTER DATABASE [<database_name>] SET AUTO_SHRINK OFF;
```

---

## Misconfiguration: auto_close

**What it means**: `AUTO_CLOSE` is enabled, causing the database to be closed and resources freed when the last user disconnects. This adds overhead when the next connection opens the database.

**BPA rule**: "Disable auto close on user databases."

**How to detect**:
```sql
SELECT name, is_auto_close_on FROM sys.databases WHERE is_auto_close_on = 1;
```

**Remediation**:
```sql
ALTER DATABASE [<database_name>] SET AUTO_CLOSE OFF;
```

---

## Misconfiguration: page_verify_none

**What it means**: Page verification is set to `NONE` instead of `CHECKSUM`, meaning SQL Server cannot detect silent data corruption from I/O subsystem errors.

**BPA rule**: "Set PAGE_VERIFY to CHECKSUM for all databases."

**How to detect**:
```sql
SELECT name, page_verify_option_desc FROM sys.databases WHERE page_verify_option_desc != 'CHECKSUM';
```

**Remediation**:
```sql
ALTER DATABASE [<database_name>] SET PAGE_VERIFY CHECKSUM;
```

---

## Misconfiguration: tempdb_os_drive

**What it means**: TempDB data files are located on the OS drive (C:), which competes with the operating system for I/O and can fill the system drive.

**BPA rule**: "Move TempDB files to a dedicated drive."

**How to detect**:
```sql
SELECT name, physical_name FROM sys.master_files WHERE database_id = 2 AND physical_name LIKE 'C:%';
```

**Remediation**: Move TempDB files to a dedicated data disk:
```sql
ALTER DATABASE tempdb MODIFY FILE (NAME = 'tempdev', FILENAME = 'T:\tempdb\tempdev.mdf');
ALTER DATABASE tempdb MODIFY FILE (NAME = 'templog', FILENAME = 'T:\tempdb\templog.ldf');
-- Restart SQL Server for the change to take effect
```

---

## Misconfiguration: no_adhoc_opt

**What it means**: `optimize for ad hoc workloads` is not enabled. Without this, single-use query plans consume plan cache memory unnecessarily.

**BPA rule**: "Enable optimize for ad hoc workloads."

**How to detect**:
```sql
SELECT name, value_in_use FROM sys.configurations WHERE name = 'optimize for ad hoc workloads';
-- If value_in_use = 0, it's disabled
```

**Remediation**:
```sql
EXEC sp_configure 'optimize for ad hoc workloads', 1;
RECONFIGURE;
```

---

## Misconfiguration: filegrowth_pct

**What it means**: Database file autogrowth is set to a percentage rather than a fixed size in MB. Percentage-based growth leads to progressively larger growth events and VLF fragmentation.

**BPA rule**: "Use fixed-size autogrowth in MB rather than percentage."

**How to detect**:
```sql
SELECT db_name(database_id), name, is_percent_growth, growth
FROM sys.master_files WHERE is_percent_growth = 1;
```

**Remediation**:
```sql
ALTER DATABASE [<database_name>] MODIFY FILE (NAME = '<logical_name>', FILEGROWTH = 256MB);
```

---

## Misconfiguration: data_log_same_vol

**What it means**: Data files and log files are on the same disk volume. Log writes are sequential; data reads are random. Mixing them on the same disk degrades performance.

**BPA rule**: "Place data and log files on separate volumes."

**How to detect**:
```sql
SELECT db_name(database_id), name, type_desc, physical_name FROM sys.master_files ORDER BY database_id, type;
-- Check if data (type=0) and log (type=1) files share the same drive letter
```

**Remediation**: Move log files to a separate volume.

---

## Misconfiguration: recovery_simple

**What it means**: The recovery model is set to `SIMPLE`, which prevents point-in-time restore. Acceptable for non-production databases but risky for production data.

**BPA rule**: "Consider using FULL recovery model for production databases."

**How to detect**:
```sql
SELECT name, recovery_model_desc FROM sys.databases WHERE recovery_model_desc = 'SIMPLE' AND name NOT IN ('master','msdb','tempdb');
```

**Remediation**:
```sql
ALTER DATABASE [<database_name>] SET RECOVERY FULL;
-- Take a full backup immediately after changing recovery model
```

---

## Baseline Configuration (sql-bpa-04)

The VM `sql-bpa-04` uses `misconfigs = "baseline"`, meaning it is correctly configured. It serves as a reference for comparison. A correctly configured SQL Server should show zero or minimal BPA findings.
