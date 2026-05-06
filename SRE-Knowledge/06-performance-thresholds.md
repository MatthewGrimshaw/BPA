# Performance Counter Thresholds and Alerting

This document defines the critical performance counter thresholds collected from SQL Servers and the recommended alert rules for proactive monitoring.

---

## Collected Counters and Thresholds

### Critical Metrics

| Counter | Object | Healthy | Warning | Critical | Notes |
|---------|--------|---------|---------|----------|-------|
| Buffer cache hit ratio | SQLServer:Buffer Manager | > 97% | 95-97% | < 95% | Low ratio = memory pressure |
| Page life expectancy | SQLServer:Buffer Manager | > 1000s | 300-1000s | < 300s | Pages evicted too fast |
| Number of Deadlocks/sec | SQLServer:Locks | 0 | > 0 | > 1 | Any deadlocks need investigation |
| % Processor Time (_Total) | Processor | < 70% | 70-85% | > 85% | Sustained high CPU |

### Important Metrics

| Counter | Object | Healthy | Warning | Critical | Notes |
|---------|--------|---------|---------|----------|-------|
| Batch Requests/sec | SQLServer:SQL Statistics | Baseline | >2× baseline | >3× baseline | Throughput spike |
| SQL Compilations/sec | SQLServer:SQL Statistics | < 100 | 100-500 | > 500 | Excessive plan compilation |
| SQL Re-Compilations/sec | SQLServer:SQL Statistics | < 10 | 10-50 | > 50 | Frequent recompiles |
| Lock Waits/sec | SQLServer:Locks | < 1 | 1-10 | > 10 | Blocking occurring |
| Full Scans/sec | SQLServer:Access Methods | < 10 | 10-100 | > 100 | Missing indexes likely |
| Processes blocked | SQLServer:General Statistics | 0 | 1-5 | > 5 | Active blocking chains |
| Available MBytes | Memory | > 2048 | 512-2048 | < 512 | OS memory pressure |
| Avg. Disk sec/Read | PhysicalDisk | < 5ms | 5-15ms | > 15ms | Storage latency |
| Avg. Disk sec/Write | PhysicalDisk | < 5ms | 5-15ms | > 15ms | Storage latency |

---

## Alert Configuration

Alerts are configured as Azure Monitor Scheduled Query Rules against the Log Analytics workspace.

### Severity 1 (Critical) Alerts

- **Page Life Expectancy Critical**: PLE < 300 for 5+ minutes
- **Deadlocks Detected**: Any deadlocks in a 5-minute window
- **CPU Critical**: Sustained > 90% for 10+ minutes
- **Disk Latency Critical**: Read or write latency > 20ms for 10+ minutes

### Severity 2 (Warning) Alerts

- **Buffer Cache Hit Ratio Low**: < 95% for 15+ minutes
- **High CPU**: Sustained > 80% for 15+ minutes
- **High SQL Compilations**: > 200/sec for 15+ minutes
- **Blocking Detected**: > 3 blocked processes for 10+ minutes
- **Memory Pressure**: Available MBytes < 1024 for 15+ minutes

See `docs/CREATING-ALERTS.md` for full alert rule definitions and Azure CLI commands.
