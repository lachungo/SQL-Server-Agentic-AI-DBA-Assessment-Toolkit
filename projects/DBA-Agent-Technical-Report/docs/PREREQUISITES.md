# Prerequisites

## SQL Server requirements
- SQL Server 2022 (script is designed around your current environment)
- SQL authentication enabled if using `sa`
- User must have permission to read:
  - `DBA_Observability`
  - `sys.*` DMVs and catalog views
  - `msdb` job and backup metadata
  - Query Store views where enabled

## Required database
The script expects a database named `DBA_Observability` with the collection tables populated by earlier jobs/procedures.

## Optional AI configuration
Set these environment variables if you want AI narrative support:
- `OPENAI_ENDPOINT`
- `OPENAI_API_KEY`

## OS requirements
- Windows PowerShell
- Write access to `C:\Temp\DBA_Agent`
