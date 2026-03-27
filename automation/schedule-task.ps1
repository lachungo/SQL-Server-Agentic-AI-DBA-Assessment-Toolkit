
param(
    [string]$TaskName = "SQL Server Agentic AI DBA Assessment Toolkit",
    [string]$RunAllScriptPath = "C:\Path\To\SQL-Server-Agentic-AI-DBA-Assessment-Toolkit\automation\run-all.ps1",
    [string]$SqlInstance = "localhost",
    [string]$SqlUser = "sa",
    [string]$SqlPassword = "YourPassword",
    [string]$RunTime = "09:00"
)

if (-not (Test-Path $RunAllScriptPath)) {
    throw "run-all.ps1 not found at: $RunAllScriptPath"
}

$argument = "-ExecutionPolicy Bypass -File `"$RunAllScriptPath`" -SqlInstance `"$SqlInstance`" -SqlUser `"$SqlUser`" -SqlPassword `"$SqlPassword`""

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argument
$trigger = New-ScheduledTaskTrigger -Daily -At $RunTime

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -RunLevel Highest `
    -Force

Write-Host "Scheduled task created: $TaskName"
