# SQL Server Agentic AI DBA Assessment Toolkit
## How To Run

### Prerequisite folder
Make sure this folder exists on the machine where you will run the toolkit:

```text
C:\Temp\DBA_Agent

Option 1: Basic Run (Recommended)
Runs all reports and prompts for the SQL password.

cd <repo-root>
.\automation\run-all.ps1

Option 2: Specify SQL Instance and Login

.\automation\run-all.ps1 `
  -SqlInstance "localhost" `
  -SqlUser "sa"

Option 3: Run with Email Automation
Sends generated reports via email.

.\automation\run-all.ps1 `
  -SqlInstance "localhost" `
  -SqlUser "sa" `
  -EnableEmail `
  -SmtpServer "smtp.office365.com" `
  -SmtpPort 587 `
  -SmtpFrom "you@company.com" `
  -SmtpTo "you@company.com,manager@company.com" `
  -SmtpUser "you@company.com"

You will be prompted for:

SQL password
SMTP password

Option 4: Enable AI Narrative Layer
Passes AI configuration to report scripts.

.\automation\run-all.ps1 `
  -SqlInstance "localhost" `
  -SqlUser "sa" `
  -EnableAINarrative `
  -OpenAIEndpoint "https://your-endpoint" `
  -OpenAIKey "your-api-key" `
  -OpenAIModel "gpt-4.1-mini"

Option 5: Full Run (Email + AI)

.\automation\run-all.ps1 `
  -SqlInstance "localhost" `
  -SqlUser "sa" `
  -EnableEmail `
  -SmtpServer "smtp.office365.com" `
  -SmtpPort 587 `
  -SmtpFrom "you@company.com" `
  -SmtpTo "you@company.com" `
  -SmtpUser "you@company.com" `
  -EnableAINarrative `
  -OpenAIEndpoint "https://your-endpoint" `
  -OpenAIKey "your-api-key"

Output Locations
After execution, outputs are saved under:

C:\Temp\DBA_Agent\

Reports
  Reports\
Logs
  Logs\
JSON Payloads
  Payloads\
Summary Report
  Toolkit_Run_Summary_<timestamp>.html


:: What the Toolkit Runs

This script executes:

:: DBA Agent Technical Report
  Performance
  Backup gaps
  Wait stats
  Jobs

::Best Practices Compliance Report
  Configuration validation
  Memory, MAXDOP, etc.

::Vulnerability Assessment Report
  Security risks
  Login exposure
  Surface area risks

:: Troubleshooting
Script not found

Ensure correct folder structure:
projects/
  ├── DBA-Agent-Technical-Report/
  ├── Best-Practices-Compliance-Report/
  ├── Vulnerability-Assessment-Report/
automation/
  └── run-all.ps1

Execution blocked
Run:

Set-ExecutionPolicy Bypass -Scope Process

SQL login issues

Verify:
  SQL Server allows SQL authentication
  Credentials are correct
  Email not sending
Check:
  SMTP server
  Port (587 typically)
  Credentials
  Firewall rules

AI narrative not showing
Ensure:
  -EnableAINarrative flag is used
  Endpoint and API key are valid
  Scripts support AI integration

Pro Tip (For Production Use)
You can schedule this via Task Scheduler:

SQL login issues

Verify:

SQL Server allows SQL authentication
Credentials are correct
Email not sending

Check:

SMTP server
Port (587 typically)
Credentials
Firewall rules
AI narrative not showing

Ensure:

-EnableAINarrative flag is used
Endpoint and API key are valid
Scripts support AI integration
Pro Tip (For Production Use)

You can schedule this via Task Scheduler:

powershell.exe -ExecutionPolicy Bypass -File "C:\path\to\run-all.ps1"

