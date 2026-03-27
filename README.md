# SQL Server Best Practices Compliance Report Package

This package contains the PowerShell script and documentation for the SQL Server Best Practices Compliance report.

## Contents
- `DBA_BestPractices_Compliance_Report_v1_1.ps1`
- `README.md`
- `RUN_COMMANDS.txt`
- `PREREQUISITES.md`
- `OUTPUTS.md`
- `TROUBLESHOOTING.md`

## What the report covers
- Max server memory
- Min server memory
- MAXDOP
- Cost threshold for parallelism
- Optimize for ad hoc workloads
- Backup compression default
- TempDB data file count
- Database state
- PAGE_VERIFY
- AUTO_CREATE_STATS
- AUTO_UPDATE_STATS
- AUTO_UPDATE_STATS_ASYNC review
- Query Store enablement review
- Recovery model review
- DBCC CHECKDB recency

## Output location
- `C:\Temp\DBA_Agent\Reports`
- `C:\Temp\DBA_Agent\Logs`
