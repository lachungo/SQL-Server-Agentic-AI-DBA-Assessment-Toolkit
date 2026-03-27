param(
    [string]$SqlInstance = "localhost",
    [string]$SqlUser = "sa",
    [SecureString]$SqlPassword,
    [string]$BaseDir = "C:\Temp\DBA_Agent",

    [switch]$EnableEmail,
    [string]$SmtpServer = "",
    [int]$SmtpPort = 587,
    [string]$SmtpFrom = "",
    [string]$SmtpTo = "",
    [string]$SmtpUser = "",
    [SecureString]$SmtpPassword,

    [switch]$EnableAINarrative,
    [string]$OpenAIEndpoint = "",
    [string]$OpenAIKey = "",
    [string]$OpenAIModel = "gpt-4.1-mini"
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Setup
# ------------------------------------------------------------
$RepoRoot = Split-Path -Parent $PSScriptRoot
$TimeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$ReportsDir = Join-Path $BaseDir "Reports"
$LogsDir = Join-Path $BaseDir "Logs"
$PayloadsDir = Join-Path $BaseDir "Payloads"

New-Item -ItemType Directory -Force -Path $ReportsDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
New-Item -ItemType Directory -Force -Path $PayloadsDir | Out-Null

$RunLog = Join-Path $LogsDir "run-all_$TimeStamp.log"

function Write-RunLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    $line | Tee-Object -FilePath $RunLog -Append
}

Write-Host "========================================="
Write-Host " SQL Server Agentic AI DBA Toolkit"
Write-Host "========================================="
Write-Host "Instance   : $SqlInstance"
Write-Host "Start Time : $(Get-Date)"
Write-Host ""

Write-RunLog "Toolkit run started."
Write-RunLog "SQL Instance: $SqlInstance"
Write-RunLog "BaseDir: $BaseDir"
Write-RunLog "Email Enabled: $EnableEmail"
Write-RunLog "AI Narrative Enabled: $EnableAINarrative"

# ------------------------------------------------------------
# Secure password handling
# ------------------------------------------------------------
if (-not $SqlPassword) {
    $SqlPassword = Read-Host "Enter SQL Password" -AsSecureString
}

$SqlBSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SqlPassword)
$PlainSqlPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($SqlBSTR)

if ($EnableEmail -and -not $SmtpPassword -and $SmtpUser) {
    $SmtpPassword = Read-Host "Enter SMTP Password" -AsSecureString
}

$PlainSmtpPassword = $null
$SmtpBSTR = $null
if ($SmtpPassword) {
    $SmtpBSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SmtpPassword)
    $PlainSmtpPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($SmtpBSTR)
}

# ------------------------------------------------------------
# AI environment variables for child scripts
# ------------------------------------------------------------
if ($EnableAINarrative) {
    if ([string]::IsNullOrWhiteSpace($OpenAIEndpoint) -or [string]::IsNullOrWhiteSpace($OpenAIKey)) {
        throw "AI narrative was enabled but OpenAIEndpoint or OpenAIKey was not supplied."
    }

    $env:OPENAI_ENDPOINT = $OpenAIEndpoint
    $env:OPENAI_API_KEY = $OpenAIKey
    $env:OPENAI_MODEL = $OpenAIModel
    Write-RunLog "AI environment variables set for child report scripts."
}

# ------------------------------------------------------------
# Script paths
# ------------------------------------------------------------
$TechnicalScript = Join-Path $RepoRoot "projects\DBA-Agent-Technical-Report\scripts\DBA_Agent_Report_v4_Technical.ps1"
$BestPracticesScript = Join-Path $RepoRoot "projects\Best-Practices-Compliance-Report\scripts\DBA_BestPractices_Compliance_Report_v1_1.ps1"
$VulnerabilityScript = Join-Path $RepoRoot "projects\Vulnerability-Assessment-Report\scripts\DBA_Vulnerability_Assessment_Report_v1_3.ps1"

foreach ($script in @($TechnicalScript, $BestPracticesScript, $VulnerabilityScript)) {
    if (-not (Test-Path $script)) {
        throw "Missing script: $script"
    }
}

# ------------------------------------------------------------
# Report execution helper
# ------------------------------------------------------------
$GeneratedReports = @()

function Get-LatestReportFile {
    param([string]$FolderPath, [datetime]$StartedAfter)

    if (-not (Test-Path $FolderPath)) {
        return $null
    }

    $files = Get-ChildItem -Path $FolderPath -Filter *.html -File |
        Where-Object { $_.LastWriteTime -ge $StartedAfter } |
        Sort-Object LastWriteTime -Descending

    if ($files.Count -gt 0) {
        return $files[0].FullName
    }

    return $null
}

function Run-Report {
    param(
        [string]$Name,
        [string]$ScriptPath
    )

    Write-Host "-----------------------------------------"
    Write-Host "Running: $Name"
    Write-Host "-----------------------------------------"

    Write-RunLog "Starting report: $Name"
    $startTime = Get-Date

    try {
        & powershell.exe -ExecutionPolicy Bypass -File $ScriptPath `
            -SqlInstance $SqlInstance `
            -SqlUser $SqlUser `
            -SqlPassword $PlainSqlPassword `
            -BaseDir $BaseDir `
            -SaveJsonPayload

        $latestReport = Get-LatestReportFile -FolderPath $ReportsDir -StartedAfter $startTime
        if ($latestReport) {
            $script:GeneratedReports += [PSCustomObject]@{
                Name = $Name
                ReportPath = $latestReport
            }
            Write-RunLog "Completed report: $Name"
            Write-RunLog "Report file: $latestReport"
            Write-Host "SUCCESS: $Name completed"
            Write-Host "Output : $latestReport"
        }
        else {
            Write-RunLog "Completed report: $Name, but no new HTML file was detected." "WARN"
            Write-Host "SUCCESS: $Name completed"
            Write-Host "Output : No HTML file detected"
        }
    }
    catch {
        Write-RunLog "ERROR running $Name - $($_.Exception.Message)" "ERROR"
        Write-Host "ERROR: $Name failed"
        Write-Host $_.Exception.Message
    }

    Write-Host ""
}

# ------------------------------------------------------------
# Run all reports
# ------------------------------------------------------------
Run-Report -Name "DBA Agent Technical Report" -ScriptPath $TechnicalScript
Run-Report -Name "Best Practices Compliance Report" -ScriptPath $BestPracticesScript
Run-Report -Name "Vulnerability Assessment Report" -ScriptPath $VulnerabilityScript

# ------------------------------------------------------------
# Build summary HTML for email / archive
# ------------------------------------------------------------
$SummaryHtmlPath = Join-Path $ReportsDir "Toolkit_Run_Summary_$TimeStamp.html"

$summaryRows = ""
foreach ($item in $GeneratedReports) {
    $summaryRows += "<tr><td>$($item.Name)</td><td>$($item.ReportPath)</td></tr>"
}

if ([string]::IsNullOrWhiteSpace($summaryRows)) {
    $summaryRows = "<tr><td colspan='2'>No reports were detected.</td></tr>"
}

$SummaryHtml = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<title>SQL Server Agentic AI DBA Toolkit Summary</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; color: #222; }
h1 { color: #1f4e79; }
table { border-collapse: collapse; width: 100%; margin-top: 12px; }
th, td { border: 1px solid #d9d9d9; padding: 8px; text-align: left; }
th { background: #f2f2f2; }
</style>
</head>
<body>
<h1>SQL Server Agentic AI DBA Toolkit Run Summary</h1>
<p><b>Instance:</b> $SqlInstance</p>
<p><b>Generated:</b> $(Get-Date)</p>
<p><b>Run Log:</b> $RunLog</p>

<table>
<tr><th>Report</th><th>Output Path</th></tr>
$summaryRows
</table>
</body>
</html>
"@

$SummaryHtml | Out-File -FilePath $SummaryHtmlPath -Encoding UTF8
Write-RunLog "Summary HTML created: $SummaryHtmlPath"

# ------------------------------------------------------------
# Email automation
# ------------------------------------------------------------
function Send-ToolkitEmail {
    param(
        [string]$Subject,
        [string]$BodyHtml,
        [string[]]$Attachments
    )

    if ([string]::IsNullOrWhiteSpace($SmtpServer) -or
        [string]::IsNullOrWhiteSpace($SmtpFrom) -or
        [string]::IsNullOrWhiteSpace($SmtpTo)) {
        throw "Email enabled, but SmtpServer, SmtpFrom, or SmtpTo was not supplied."
    }

    $mail = New-Object System.Net.Mail.MailMessage
    $mail.From = $SmtpFrom
    foreach ($addr in ($SmtpTo -split ",")) {
        if (-not [string]::IsNullOrWhiteSpace($addr.Trim())) {
            [void]$mail.To.Add($addr.Trim())
        }
    }

    $mail.Subject = $Subject
    $mail.Body = $BodyHtml
    $mail.IsBodyHtml = $true

    foreach ($file in $Attachments) {
        if (Test-Path $file) {
            $attachment = New-Object System.Net.Mail.Attachment($file)
            [void]$mail.Attachments.Add($attachment)
        }
    }

    $smtp = New-Object System.Net.Mail.SmtpClient($SmtpServer, $SmtpPort)
    $smtp.EnableSsl = $true

    if (-not [string]::IsNullOrWhiteSpace($SmtpUser) -and -not [string]::IsNullOrWhiteSpace($PlainSmtpPassword)) {
        $smtp.Credentials = New-Object System.Net.NetworkCredential($SmtpUser, $PlainSmtpPassword)
    }

    $smtp.Send($mail)
    $mail.Dispose()
}

if ($EnableEmail) {
    try {
        $emailBody = @"
<h2>SQL Server Agentic AI DBA Toolkit</h2>
<p><b>Instance:</b> $SqlInstance</p>
<p><b>Run Time:</b> $(Get-Date)</p>
<p>The attached files include the generated SQL Server assessment reports.</p>
<ul>
<li>DBA Agent Technical Report</li>
<li>Best Practices Compliance Report</li>
<li>Vulnerability Assessment Report</li>
<li>Toolkit Run Summary</li>
</ul>
"@

        $attachments = @($SummaryHtmlPath)
        foreach ($item in $GeneratedReports) {
            $attachments += $item.ReportPath
        }

        Send-ToolkitEmail `
            -Subject "SQL Server Agentic AI DBA Toolkit Reports - $SqlInstance - $TimeStamp" `
            -BodyHtml $emailBody `
            -Attachments $attachments

        Write-RunLog "Email sent successfully."
        Write-Host "Email automation completed successfully."
    }
    catch {
        Write-RunLog "Email automation failed: $($_.Exception.Message)" "ERROR"
        Write-Host "Email automation failed."
        Write-Host $_.Exception.Message
    }
}

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($SqlBSTR)
if ($SmtpBSTR) {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($SmtpBSTR)
}

Write-RunLog "Toolkit run completed."
Write-Host "========================================="
Write-Host "All reports completed"
Write-Host "End Time : $(Get-Date)"
Write-Host "Run Log  : $RunLog"
Write-Host "Summary  : $SummaryHtmlPath"
Write-Host "========================================="
