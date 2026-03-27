param(
    [string]$SqlInstance = "localhost",
    [string]$SqlUser = "sa",
    [string]$SqlPassword,
    [string]$BaseDir = "C:\Temp\DBA_Agent"
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Setup
# ------------------------------------------------------------
$ReportsDir = Join-Path $BaseDir "Reports"
$LogsDir    = Join-Path $BaseDir "Logs"

New-Item -ItemType Directory -Force -Path $ReportsDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogsDir    | Out-Null

$TimeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile   = Join-Path $LogsDir "BestPractices_$TimeStamp.log"

function Write-Log {
    param([string]$Message)
    "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) [INFO] $Message" | Tee-Object -FilePath $LogFile -Append
}

function Convert-ToSafeHtml {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return "" }

    $encoded = [string]$Text
    $encoded = $encoded.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
    $encoded = $encoded.Replace('"', "&quot;")
    $encoded = $encoded.Replace("`r`n", "<br/>").Replace("`n", "<br/>")
    return $encoded
}

if ([string]::IsNullOrWhiteSpace($SqlPassword)) {
    throw "SqlPassword is required."
}

# ------------------------------------------------------------
# SQL Executor
# ------------------------------------------------------------
function Invoke-Sql {
    param([string]$Query)

    $conn = New-Object System.Data.SqlClient.SqlConnection
    $conn.ConnectionString = "Server=$SqlInstance;Database=master;User ID=$SqlUser;Password=$SqlPassword;TrustServerCertificate=True;"
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $Query
    $cmd.CommandTimeout = 120

    $dt = New-Object System.Data.DataTable

    try {
        $conn.Open()
        $reader = $cmd.ExecuteReader()
        $dt.Load($reader)
        $reader.Close()
        return ,$dt
    }
    finally {
        if ($conn.State -eq [System.Data.ConnectionState]::Open) {
            $conn.Close()
        }
        $conn.Dispose()
    }
}

function Get-ConfigValue {
    param(
        [System.Data.DataTable]$ConfigTable,
        [string]$Name
    )

    $match = $ConfigTable.Rows | Where-Object { $_["name"] -eq $Name } | Select-Object -First 1
    if ($null -eq $match) { return $null }
    return $match["value_in_use"]
}

function Add-Result {
    param(
        [string]$Check,
        [string]$Current,
        [string]$Expected,
        [string]$Status,
        [string]$Severity,
        [string]$Details,
        [string]$Fix
    )

    $script:results += [PSCustomObject]@{
        Check    = $Check
        Current  = $Current
        Expected = $Expected
        Status   = $Status
        Severity = $Severity
        Details  = $Details
        Fix      = $Fix
    }
}

# ------------------------------------------------------------
# Collect Data
# ------------------------------------------------------------
Write-Log "Collecting configuration data..."

$config = Invoke-Sql @"
SELECT name, value_in_use
FROM sys.configurations
ORDER BY name;
"@

$dbs = Invoke-Sql @"
SELECT 
    name,
    state_desc,
    recovery_model_desc,
    page_verify_option_desc,
    is_auto_create_stats_on,
    is_auto_update_stats_on,
    is_auto_update_stats_async_on,
    CASE 
        WHEN database_id = 2 THEN 1
        ELSE CAST(DATABASEPROPERTYEX(name, 'IsQueryStoreOn') AS int)
    END AS is_query_store_on
FROM sys.databases
ORDER BY name;
"@

$tempdbFiles = Invoke-Sql @"
SELECT COUNT(*) AS FileCount
FROM tempdb.sys.database_files
WHERE type_desc = 'ROWS';
"@

$serverInfo = Invoke-Sql @"
SELECT
    @@SERVERNAME AS ServerName,
    SERVERPROPERTY('Edition') AS Edition,
    SERVERPROPERTY('ProductVersion') AS ProductVersion,
    SERVERPROPERTY('ProductLevel') AS ProductLevel,
    SERVERPROPERTY('ProductUpdateLevel') AS ProductUpdateLevel,
    sqlserver_start_time AS SqlServerStartTime,
    DATEDIFF(hour, sqlserver_start_time, SYSDATETIME()) AS UptimeHours
FROM sys.dm_os_sys_info;
"@

$dbcc = Invoke-Sql @"
IF OBJECT_ID('tempdb..#dbccinfo') IS NOT NULL
    DROP TABLE #dbccinfo;

CREATE TABLE #dbccinfo
(
    ParentObject varchar(255) NULL,
    ObjectName   varchar(255) NULL,
    FieldName    varchar(255) NULL,
    ValueText    varchar(255) NULL
);

INSERT INTO #dbccinfo
EXEC ('DBCC DBINFO WITH TABLERESULTS');

SELECT
    DB_NAME() AS DatabaseName,
    MAX(CASE WHEN FieldName = 'dbi_dbccLastKnownGood' THEN ValueText END) AS LastKnownGood
FROM #dbccinfo;
"@

# ------------------------------------------------------------
# Evaluate Checks
# ------------------------------------------------------------
Write-Log "Evaluating best practice checks..."
$results = @()

$maxMem = Get-ConfigValue -ConfigTable $config -Name "max server memory (MB)"
if ($null -ne $maxMem -and [int64]$maxMem -gt 0 -and [int64]$maxMem -lt 2147483647) {
    Add-Result "Max Server Memory" "$maxMem MB" "Configured to finite value" "Pass" "High" "Max server memory is explicitly configured." ""
}
else {
    Add-Result "Max Server Memory" "$maxMem" "Configured to finite value" "Fail" "Critical" "Unlimited or default memory configuration can create OS memory pressure." "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'max server memory (MB)', <recommended_value>; RECONFIGURE;"
}

$minMem = Get-ConfigValue -ConfigTable $config -Name "min server memory (MB)"
if ($null -ne $minMem -and [int64]$minMem -ge 0) {
    Add-Result "Min Server Memory" "$minMem MB" "0 or workload-based reviewed value" "Review" "Low" "Minimum memory may be acceptable but should align with workload expectations." "Review current min server memory setting and adjust only if justified."
}

$maxdop = Get-ConfigValue -ConfigTable $config -Name "max degree of parallelism"
if ($null -ne $maxdop -and [int64]$maxdop -ge 1 -and [int64]$maxdop -le 8) {
    Add-Result "MAXDOP" "$maxdop" "Typically 1-8 depending on NUMA/core layout" "Pass" "Medium" "MAXDOP is within a generally acceptable range." ""
}
else {
    Add-Result "MAXDOP" "$maxdop" "Typically 1-8 depending on NUMA/core layout" "Review" "Medium" "MAXDOP is workload-dependent and should be validated against Microsoft guidance and server topology." "Review MAXDOP against CPU topology and workload characteristics."
}

$ctp = Get-ConfigValue -ConfigTable $config -Name "cost threshold for parallelism"
if ($null -ne $ctp -and [int64]$ctp -ge 20) {
    Add-Result "Cost Threshold for Parallelism" "$ctp" ">= 20 for most modern workloads" "Pass" "Medium" "Cost threshold is above the legacy default and better aligned with modern systems." ""
}
else {
    Add-Result "Cost Threshold for Parallelism" "$ctp" ">= 20 for most modern workloads" "Fail" "High" "Low cost threshold may cause excessive parallel plan selection." "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'cost threshold for parallelism', 25; RECONFIGURE;"
}

$adhoc = Get-ConfigValue -ConfigTable $config -Name "optimize for ad hoc workloads"
if ($adhoc -eq 1) {
    Add-Result "Optimize for Ad Hoc Workloads" "$adhoc" "Enabled" "Pass" "Low" "Enabled, which helps reduce single-use plan cache bloat." ""
}
else {
    Add-Result "Optimize for Ad Hoc Workloads" "$adhoc" "Enabled" "Fail" "Medium" "Disabled, which may increase plan cache pressure in ad hoc workloads." "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'optimize for ad hoc workloads', 1; RECONFIGURE;"
}

$backupCompression = Get-ConfigValue -ConfigTable $config -Name "backup compression default"
if ($backupCompression -eq 1) {
    Add-Result "Backup Compression Default" "$backupCompression" "Enabled" "Pass" "Low" "Backup compression is enabled by default." ""
}
else {
    Add-Result "Backup Compression Default" "$backupCompression" "Enabled" "Review" "Low" "Compression may still be applied explicitly in jobs, but default is disabled." "Consider enabling backup compression default if aligned with standards."
}

$tempCount = [int]$tempdbFiles.Rows[0]["FileCount"]
if ($tempCount -ge 4) {
    Add-Result "TempDB Data File Count" "$tempCount" "Typically >= 4 and balanced by workload/core contention" "Pass" "Medium" "TempDB has at least four data files." ""
}
else {
    Add-Result "TempDB Data File Count" "$tempCount" "Typically >= 4 and balanced by workload/core contention" "Fail" "High" "Low TempDB file count may contribute to allocation contention." "Review TempDB file layout and add data files if needed."
}

foreach ($db in $dbs.Rows) {
    $dbName = [string]$db["name"]
    $stateDesc = [string]$db["state_desc"]
    $recoveryModel = [string]$db["recovery_model_desc"]
    $pageVerify = [string]$db["page_verify_option_desc"]
    $autoCreateStats = [string]$db["is_auto_create_stats_on"]
    $autoUpdateStats = [string]$db["is_auto_update_stats_on"]
    $asyncStats = [string]$db["is_auto_update_stats_async_on"]
    $queryStoreOn = [string]$db["is_query_store_on"]

    if ($stateDesc -eq "ONLINE") {
        Add-Result "Database State ($dbName)" $stateDesc "ONLINE" "Pass" "High" "Database is online." ""
    }
    else {
        Add-Result "Database State ($dbName)" $stateDesc "ONLINE" "Fail" "Critical" "Database is not online." "Investigate database state and recovery condition."
    }

    if ($pageVerify -eq "CHECKSUM") {
        Add-Result "PAGE_VERIFY ($dbName)" $pageVerify "CHECKSUM" "Pass" "High" "PAGE_VERIFY is configured to CHECKSUM." ""
    }
    else {
        Add-Result "PAGE_VERIFY ($dbName)" $pageVerify "CHECKSUM" "Fail" "High" "Database is not using CHECKSUM page verification." "ALTER DATABASE [$dbName] SET PAGE_VERIFY CHECKSUM;"
    }

    if ($autoCreateStats -eq "True") {
        Add-Result "AUTO_CREATE_STATS ($dbName)" $autoCreateStats "True" "Pass" "Medium" "AUTO_CREATE_STATS is enabled." ""
    }
    else {
        Add-Result "AUTO_CREATE_STATS ($dbName)" $autoCreateStats "True" "Fail" "Medium" "AUTO_CREATE_STATS is disabled." "ALTER DATABASE [$dbName] SET AUTO_CREATE_STATISTICS ON;"
    }

    if ($autoUpdateStats -eq "True") {
        Add-Result "AUTO_UPDATE_STATS ($dbName)" $autoUpdateStats "True" "Pass" "Medium" "AUTO_UPDATE_STATS is enabled." ""
    }
    else {
        Add-Result "AUTO_UPDATE_STATS ($dbName)" $autoUpdateStats "True" "Fail" "High" "AUTO_UPDATE_STATS is disabled." "ALTER DATABASE [$dbName] SET AUTO_UPDATE_STATISTICS ON;"
    }

    if ($dbName -notin @("master","model","msdb","tempdb")) {
        if ($asyncStats -eq "True") {
            Add-Result "AUTO_UPDATE_STATS_ASYNC ($dbName)" $asyncStats "Workload-based review" "Review" "Low" "Async stats can be useful depending on workload pattern." "Validate whether async stats aligns with workload requirements."
        }
        else {
            Add-Result "AUTO_UPDATE_STATS_ASYNC ($dbName)" $asyncStats "Workload-based review" "Review" "Low" "Synchronous stats updates may be fine depending on workload." "Validate whether async stats should be enabled for this workload."
        }

        if ($queryStoreOn -eq "1") {
            Add-Result "Query Store ($dbName)" $queryStoreOn "Enabled for user databases" "Pass" "Medium" "Query Store is enabled." ""
        }
        else {
            Add-Result "Query Store ($dbName)" $queryStoreOn "Enabled for user databases" "Review" "Medium" "Query Store is not enabled." "Consider enabling Query Store for performance troubleshooting and regression tracking."
        }

        if ($recoveryModel -eq "SIMPLE") {
            Add-Result "Recovery Model ($dbName)" $recoveryModel "Workload / business requirement aligned" "Review" "Low" "Recovery model should align with RPO/RTO requirements." "Review recovery model against business recovery expectations."
        }
        else {
            Add-Result "Recovery Model ($dbName)" $recoveryModel "Workload / business requirement aligned" "Pass" "Low" "Recovery model requires validation against business requirements but is not inherently non-compliant." ""
        }
    }
}

foreach ($row in $dbcc.Rows) {
    $dbName = [string]$row["DatabaseName"]
    $lastKnownGood = [string]$row["LastKnownGood"]

    if ([string]::IsNullOrWhiteSpace($lastKnownGood)) {
        Add-Result "DBCC CHECKDB ($dbName)" "Never / Unknown" "Recent successful CHECKDB" "Fail" "Critical" "No DBCC last known good value found." "Run DBCC CHECKDB([$dbName]) and establish regular integrity checks."
    }
    else {
        $ageDays = $null
        try {
            $ageDays = [math]::Round(((Get-Date) - [datetime]$lastKnownGood).TotalDays, 1)
        }
        catch {
            $ageDays = $null
        }

        if ($null -ne $ageDays -and $ageDays -le 14) {
            Add-Result "DBCC CHECKDB ($dbName)" $lastKnownGood "<= 14 days" "Pass" "High" "Integrity check recency is within threshold." ""
        }
        elseif ($null -ne $ageDays -and $ageDays -le 30) {
            Add-Result "DBCC CHECKDB ($dbName)" $lastKnownGood "<= 14 days" "Review" "Medium" "Integrity check is older than preferred threshold." "Review CHECKDB cadence and tighten schedule if needed."
        }
        else {
            Add-Result "DBCC CHECKDB ($dbName)" $lastKnownGood "<= 14 days" "Fail" "High" "Integrity check appears stale." "Run DBCC CHECKDB([$dbName]) and validate maintenance schedule."
        }
    }
}

$critical = @($results | Where-Object { $_.Severity -eq "Critical" }).Count
$high     = @($results | Where-Object { $_.Severity -eq "High" }).Count
$medium   = @($results | Where-Object { $_.Severity -eq "Medium" }).Count
$low      = @($results | Where-Object { $_.Severity -eq "Low" }).Count
$passed   = @($results | Where-Object { $_.Status -eq "Pass" }).Count
$failed   = @($results | Where-Object { $_.Status -eq "Fail" }).Count
$review   = @($results | Where-Object { $_.Status -eq "Review" }).Count

$report = Join-Path $ReportsDir "BestPractices_$TimeStamp.html"

$html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<title>SQL Server Best Practices Compliance Report</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; color: #222; }
h1 { color: #1f4e79; }
h2 { color: #2f75b5; margin-top: 24px; }
table { border-collapse: collapse; width: 100%; margin-top: 12px; }
th, td { border: 1px solid #d9d9d9; padding: 8px; text-align: left; vertical-align: top; }
th { background: #f2f2f2; }
.cards { display: flex; flex-wrap: wrap; gap: 12px; margin: 12px 0 20px 0; }
.card { min-width: 150px; padding: 14px; border-radius: 10px; border: 1px solid #dde3ea; background: #f8f9fb; }
.label { font-size: 12px; color: #555; text-transform: uppercase; margin-bottom: 6px; }
.value { font-size: 24px; font-weight: 600; }
.critical { background: #fdeaea; border-color: #e6a8a8; }
.high { background: #fff2e6; border-color: #efc08f; }
.medium { background: #fff9e6; border-color: #e2cf7a; }
.low { background: #eef8ee; border-color: #9fd19f; }
.pass { color: #1b5e20; font-weight: 600; }
.fail { color: #b71c1c; font-weight: 600; }
.review { color: #8a6d1d; font-weight: 600; }
pre { white-space: pre-wrap; margin: 0; font-family: Consolas, monospace; }
</style>
</head>
<body>

<h1>SQL Server Best Practices Compliance Report</h1>
<p><b>Instance:</b> $(Convert-ToSafeHtml -Text $SqlInstance)</p>
<p><b>Generated:</b> $(Get-Date)</p>
<p><b>Log File:</b> $(Convert-ToSafeHtml -Text $LogFile)</p>

<h2>Compliance Dashboard</h2>
<div class="cards">
    <div class="card critical"><div class="label">Critical</div><div class="value">$critical</div></div>
    <div class="card high"><div class="label">High</div><div class="value">$high</div></div>
    <div class="card medium"><div class="label">Medium</div><div class="value">$medium</div></div>
    <div class="card low"><div class="label">Low</div><div class="value">$low</div></div>
    <div class="card"><div class="label">Passed</div><div class="value">$passed</div></div>
    <div class="card"><div class="label">Failed</div><div class="value">$failed</div></div>
    <div class="card"><div class="label">Review</div><div class="value">$review</div></div>
</div>

<h2>Findings</h2>
<table>
<tr>
<th>Check</th>
<th>Current</th>
<th>Expected</th>
<th>Status</th>
<th>Severity</th>
<th>Details</th>
<th>Fix</th>
</tr>
"@

foreach ($r in $results) {
    $statusClass = switch ($r.Status) {
        "Pass"   { "pass" }
        "Fail"   { "fail" }
        "Review" { "review" }
        default  { "" }
    }

    $html += @"
<tr>
<td>$(Convert-ToSafeHtml -Text $r.Check)</td>
<td>$(Convert-ToSafeHtml -Text $r.Current)</td>
<td>$(Convert-ToSafeHtml -Text $r.Expected)</td>
<td class="$statusClass">$(Convert-ToSafeHtml -Text $r.Status)</td>
<td>$(Convert-ToSafeHtml -Text $r.Severity)</td>
<td>$(Convert-ToSafeHtml -Text $r.Details)</td>
<td><pre>$(Convert-ToSafeHtml -Text $r.Fix)</pre></td>
</tr>
"@
}

$html += @"
</table>
</body>
</html>
"@

$html | Out-File -FilePath $report -Encoding UTF8

Write-Log "Report generated: $report"
Write-Host "Report created: $report"
