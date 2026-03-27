# DBA Agent Technical Report Package

This package contains the PowerShell script and documentation for the technical SQL Server DBA operational report.

## Contents
- `DBA_Agent_Report_Technical_v4.ps1`
- `README.md`
- `RUN_COMMANDS.txt`
- `PREREQUISITES.md`
- `OUTPUTS.md`
- `TROUBLESHOOTING.md`

## What the report covers
- Immediate DBA attention items
- Backup compliance exceptions
- DBCC CHECKDB status
- Database state summary
- Blocking and concurrency snapshot
- Wait statistics analysis
- File and log space usage
- Query Store top regressions
- Index maintenance candidates
- Operational action queue

## Default output folders
The script writes to:
- `C:\Temp\DBA_Agent\Reports`
- `C:\Temp\DBA_Agent\Logs`
- `C:\Temp\DBA_Agent\Payloads`

## Main run example
See `RUN_COMMANDS.txt`.

## Notes
- This script expects the `DBA_Observability` database and its collection tables to exist.
- If no LLM endpoint is configured, the report still runs and skips the narrative section.
- The script supports `-SaveJsonPayload` and `-WriteActionQueue`.
