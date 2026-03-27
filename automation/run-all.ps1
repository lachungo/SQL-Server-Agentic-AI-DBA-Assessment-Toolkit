
param(
    [string]$SqlInstance = "localhost",
    [string]$SqlUser = "sa",
    [string]$SqlPassword = "YourPassword",
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Write-Host "Starting SQL Server Agentic AI DBA Assessment Toolkit..."
Write-Host "Repo root: $RepoRoot"

$technicalScript = Join-Path $RepoRoot "projects\DBA-Agent-Technical-Report\scripts\DBA_Agent_Report_v4_Technical.ps1"
$bestPracticesScript = Join-Path $RepoRoot "projects\Best-Practices-Compliance-Report\scripts\DBA_BestPractices_Compliance_Report_v1_1.ps1"
$vulnerabilityScript = Join-Path $RepoRoot "projects\Vulnerability-Assessment-Report\scripts\DBA_Vulnerability_Assessment_Report_v1_3.ps1"

if (-not (Test-Path $technicalScript)) { throw "Technical report script not found: $technicalScript" }
if (-not (Test-Path $bestPracticesScript)) { throw "Best Practices script not found: $bestPracticesScript" }
if (-not (Test-Path $vulnerabilityScript)) { throw "Vulnerability script not found: $vulnerabilityScript" }

Write-Host "Running DBA Agent Technical Report..."
powershell.exe -ExecutionPolicy Bypass -File $technicalScript -SqlInstance $SqlInstance -SqlUser $SqlUser -SqlPassword $SqlPassword

Write-Host "Running Best Practices Compliance Report..."
powershell.exe -ExecutionPolicy Bypass -File $bestPracticesScript -SqlInstance $SqlInstance -SqlUser $SqlUser -SqlPassword $SqlPassword

Write-Host "Running Vulnerability Assessment Report..."
powershell.exe -ExecutionPolicy Bypass -File $vulnerabilityScript -SqlInstance $SqlInstance -SqlUser $SqlUser -SqlPassword $SqlPassword

Write-Host "All reports completed."
