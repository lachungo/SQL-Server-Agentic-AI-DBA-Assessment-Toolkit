param(
    [string]$SqlInstance    = "localhost",
    [string]$Database       = "DBA_Observability",
    [string]$SqlUser        = "sa",
    [string]$SqlPassword,
    [string]$BaseDir        = "C:\Temp\DBA_Agent",
    [string]$OpenAIEndpoint = $env:OPENAI_ENDPOINT,
    [string]$OpenAIKey      = $env:OPENAI_API_KEY,
    [string]$Model          = "gpt-4.1-mini",
    [switch]$SaveJsonPayload,
    [switch]$WriteActionQueue
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Folder setup
# ------------------------------------------------------------
$ReportsDir = Join-Path $BaseDir "Reports"
$LogsDir    = Join-Path $BaseDir "Logs"
$JsonDir    = Join-Path $BaseDir "Payloads"

New-Item -ItemType Directory -Force -Path $BaseDir    | Out-Null
New-Item -ItemType Directory -Force -Path $ReportsDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogsDir    | Out-Null
New-Item -ItemType Directory -Force -Path $JsonDir    | Out-Null

$TimeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile   = Join-Path $LogsDir "DBA_Agent_$TimeStamp.log"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    $line | Tee-Object -FilePath $LogFile -Append
}

Write-Log "Starting DBA Agent Technical v4 report generation."
Write-Log "SQL Instance: $SqlInstance"
Write-Log "Database: $Database"
Write-Log "Base directory: $BaseDir"
Write-Log "SQL User: $SqlUser"
Write-Log "SQL Password supplied: $(if ([string]::IsNullOrWhiteSpace($SqlPassword)) { 'No' } else { 'Yes' })"

if ([string]::IsNullOrWhiteSpace($SqlPassword)) {
    throw "SqlPassword was not supplied. Pass -SqlPassword `"YourPassword`"."
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

function Convert-NullableValue {
    param($Value)

    if ($null -eq $Value -or $Value -eq [System.DBNull]::Value) {
        return $null
    }
    return $Value
}

function Ensure-Array {
    param($InputObject)
    if ($null -eq $InputObject) { return @() }
    return @($InputObject)
}

function Get-SeverityClass {
    param([string]$Severity)

    switch ($Severity) {
        "Critical" { "sev-critical" }
        "High"     { "sev-high" }
        "Medium"   { "sev-medium" }
        "Low"      { "sev-low" }
        default    { "sev-info" }
    }
}

function New-SeverityBadge {
    param([string]$Severity)
    $cssClass = Get-SeverityClass -Severity $Severity
    return "<span class='sev-badge $cssClass'>$(Convert-ToSafeHtml -Text $Severity)</span>"
}

function Invoke-SqlQ {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    $connString = "Server=$SqlInstance;Database=$Database;User ID=$SqlUser;Password=$SqlPassword;TrustServerCertificate=True;"
    $conn = New-Object System.Data.SqlClient.SqlConnection $connString
    $cmd  = $conn.CreateCommand()
    $cmd.CommandText = $Query
    $cmd.CommandTimeout = 180

    $dt = New-Object System.Data.DataTable

    try {
        $conn.Open()
        $reader = $cmd.ExecuteReader()
        $dt.Load($reader)
        $reader.Close()
        Write-Log "Query succeeded. Rows returned: $($dt.Rows.Count)"
        return ,$dt
    }
    catch {
        Write-Log "SQL query failed. $($_.Exception.Message)" "ERROR"
        throw
    }
    finally {
        if ($conn.State -eq [System.Data.ConnectionState]::Open) { $conn.Close() }
        $conn.Dispose()
    }
}

function Invoke-SqlNonQuery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandText
    )

    $connString = "Server=$SqlInstance;Database=$Database;User ID=$SqlUser;Password=$SqlPassword;TrustServerCertificate=True;"
    $conn = New-Object System.Data.SqlClient.SqlConnection $connString
    $cmd  = $conn.CreateCommand()
    $cmd.CommandText = $CommandText
    $cmd.CommandTimeout = 180

    try {
        $conn.Open()
        $rows = $cmd.ExecuteNonQuery()
        Write-Log "Non-query executed. Rows affected: $rows"
        return $rows
    }
    catch {
        Write-Log "SQL non-query failed. $($_.Exception.Message)" "ERROR"
        throw
    }
    finally {
        if ($conn.State -eq [System.Data.ConnectionState]::Open) { $conn.Close() }
        $conn.Dispose()
    }
}

function Convert-QueryResultToObjects {
    param($InputObject)

    $result = @()

    if ($null -eq $InputObject) { return $result }

    if ($InputObject -is [System.Data.DataTable]) {
        foreach ($row in $InputObject.Rows) {
            $obj = [ordered]@{}
            foreach ($col in $InputObject.Columns) {
                $obj[$col.ColumnName] = Convert-NullableValue -Value $row[$col.ColumnName]
            }
            $result += [PSCustomObject]$obj
        }
        return $result
    }

    if ($InputObject -is [System.Data.DataRow]) {
        $obj = [ordered]@{}
        foreach ($col in $InputObject.Table.Columns) {
            $obj[$col.ColumnName] = Convert-NullableValue -Value $InputObject[$col.ColumnName]
        }
        $result += [PSCustomObject]$obj
        return $result
    }

    if ($InputObject -is [System.Array]) {
        foreach ($item in $InputObject) {
            $result += Convert-QueryResultToObjects -InputObject $item
        }
        return $result
    }

    return $result
}

function Convert-ObjectsToHtmlTable {
    param(
        [AllowNull()][array]$Rows,
        [Parameter(Mandatory = $true)][string[]]$Columns,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$EmptyMessage = "No rows returned."
    )

    $Rows = Ensure-Array -InputObject $Rows
    $html = "<h2>$(Convert-ToSafeHtml -Text $Title)</h2>"

    if ($Rows.Count -eq 0) {
        return $html + "<p class='empty'>$(Convert-ToSafeHtml -Text $EmptyMessage)</p>"
    }

    $html += "<table><thead><tr>"
    foreach ($col in $Columns) {
        $html += "<th>$(Convert-ToSafeHtml -Text $col)</th>"
    }
    $html += "</tr></thead><tbody>"

    foreach ($row in $Rows) {
        $html += "<tr>"
        foreach ($col in $Columns) {
            $value = $null
            if ($null -ne $row -and $row.PSObject.Properties.Name -contains $col) {
                $value = $row.$col
            }
            if ($value -is [datetime]) { $value = $value.ToString("yyyy-MM-dd HH:mm:ss") }
            if ($null -eq $value) { $value = "" }
            $html += "<td>$(Convert-ToSafeHtml -Text ([string]$value))</td>"
        }
        $html += "</tr>"
    }

    $html += "</tbody></table>"
    return $html
}

function Get-BackupGapSeverity {
    param($Row)

    if ($null -eq $Row.LastFullBackup) { return "Critical" }
    if ($Row.RecoveryModel -eq "FULL" -and $null -eq $Row.LastLogBackup) { return "Critical" }

    try {
        $hoursSinceFull = ((Get-Date) - [datetime]$Row.LastFullBackup).TotalHours
        if ($hoursSinceFull -ge 48) { return "High" }
    } catch {}

    try {
        if ($Row.RecoveryModel -eq "FULL" -and $null -ne $Row.LastLogBackup) {
            $hoursSinceLog = ((Get-Date) - [datetime]$Row.LastLogBackup).TotalHours
            if ($hoursSinceLog -ge 6) { return "High" }
            if ($hoursSinceLog -ge 2) { return "Medium" }
        }
    } catch {}

    "Medium"
}

function Get-JobFailureSeverity { param($Row) "High" }

function Get-WaitSeverity {
    param($Row)

    $highWaits   = @("RESOURCE_SEMAPHORE","THREADPOOL","PAGELATCH_EX","PAGELATCH_UP","WRITELOG")
    $mediumWaits = @("CXPACKET","CXCONSUMER","LCK_M_X","LCK_M_S","PAGEIOLATCH_SH","PAGEIOLATCH_EX","SOS_SCHEDULER_YIELD")

    if ($highWaits -contains $Row.WaitType) { return "High" }
    if ($mediumWaits -contains $Row.WaitType) { return "Medium" }
    "Low"
}

function Get-FragmentationSeverity {
    param($Row)
    if ($Row.PageCount -ge 10000 -and $Row.AvgFragmentationPct -ge 50) { return "High" }
    if ($Row.PageCount -ge 1000 -and $Row.AvgFragmentationPct -ge 30) { return "Medium" }
    "Low"
}

function Get-DbccSeverity {
    param($Row)

    if ($null -eq $Row.LastKnownGood) { return "High" }

    try {
        $daysOld = ((Get-Date) - [datetime]$Row.LastKnownGood).TotalDays
        if ($daysOld -ge 30) { return "High" }
        if ($daysOld -ge 14) { return "Medium" }
    } catch {}

    "Low"
}

function Get-DatabaseStateSeverity {
    param($Row)

    if ($Row.state_desc -in @("SUSPECT","RECOVERY_PENDING","EMERGENCY")) { return "Critical" }
    if ($Row.state_desc -ne "ONLINE") { return "High" }
    "Low"
}

function Get-BlockingSeverity {
    param($Row)

    try {
        $waitMs = [int64]$Row.wait_duration_ms
        if ($waitMs -ge 300000) { return "High" }
        if ($waitMs -ge 60000)  { return "Medium" }
    } catch {}

    "Low"
}

function Get-FileSpaceSeverity {
    param($Row)

    try {
        $freePct = [double]$Row.FreePct
        if ($freePct -le 10) { return "High" }
        if ($freePct -le 20) { return "Medium" }
    } catch {}

    "Low"
}

function Get-QueryStoreSeverity {
    param($Row)

    try {
        $ratio = [double]$Row.DurationRegressionPct
        if ($ratio -ge 200) { return "High" }
        if ($ratio -ge 100) { return "Medium" }
    } catch {}

    "Low"
}

try {
    Write-Log "Collecting prior observability snapshots."
    $health = Invoke-SqlQ @"
SELECT TOP 1 *
FROM dbo.InstanceHealthSnapshot
ORDER BY SnapshotTime DESC;
"@

    $backupGaps = Invoke-SqlQ @"
SELECT TOP 50
    DatabaseName,
    RecoveryModel,
    LastFullBackup,
    LastDiffBackup,
    LastLogBackup
FROM dbo.BackupStatus
WHERE (LastFullBackup IS NULL OR LastFullBackup < DATEADD(DAY, -1, SYSDATETIME()))
   OR (RecoveryModel = 'FULL' AND (LastLogBackup IS NULL OR LastLogBackup < DATEADD(HOUR, -2, SYSDATETIME())))
ORDER BY DatabaseName;
"@

    $jobFails = Invoke-SqlQ @"
SELECT TOP 50
    JobName,
    LastRunDateTime,
    LastRunOutcome,
    LEFT(Message, 500) AS Message
FROM dbo.JobFailures
WHERE SnapshotTime >= DATEADD(DAY, -1, SYSDATETIME())
ORDER BY LastRunDateTime DESC;
"@

    $topWaits = Invoke-SqlQ @"
SELECT TOP 15
    WaitType,
    WaitTimeMs,
    SignalWaitTimeMs
FROM dbo.WaitStatsDaily
WHERE SnapshotTime = (SELECT MAX(SnapshotTime) FROM dbo.WaitStatsDaily)
ORDER BY WaitTimeMs DESC;
"@

    $frag = Invoke-SqlQ @"
SELECT TOP 30
    DatabaseName,
    SchemaName,
    TableName,
    IndexName,
    AvgFragmentationPct,
    PageCount
FROM dbo.IndexHealth
WHERE SnapshotTime >= DATEADD(DAY, -2, SYSDATETIME())
  AND AvgFragmentationPct >= 30
ORDER BY AvgFragmentationPct DESC, PageCount DESC;
"@

    Write-Log "Collecting live server metrics."
    $serverInfo = Invoke-SqlQ @"
SELECT
    @@SERVERNAME AS ServerName,
    SERVERPROPERTY('MachineName') AS MachineName,
    SERVERPROPERTY('ServerName') AS ServerPropertyServerName,
    SERVERPROPERTY('Edition') AS Edition,
    SERVERPROPERTY('ProductVersion') AS ProductVersion,
    SERVERPROPERTY('ProductLevel') AS ProductLevel,
    SERVERPROPERTY('ProductUpdateLevel') AS ProductUpdateLevel,
    sqlserver_start_time AS SqlServerStartTime,
    DATEDIFF(hour, sqlserver_start_time, SYSDATETIME()) AS UptimeHours
FROM sys.dm_os_sys_info;
"@

    $configSnapshot = Invoke-SqlQ @"
SELECT name, value_in_use
FROM sys.configurations
WHERE name IN
(
    'max server memory (MB)',
    'min server memory (MB)',
    'max degree of parallelism',
    'cost threshold for parallelism',
    'optimize for ad hoc workloads',
    'backup compression default',
    'clr enabled'
)
ORDER BY name;
"@

    $databaseStates = Invoke-SqlQ @"
SELECT
    name,
    state_desc,
    recovery_model_desc,
    user_access_desc,
    page_verify_option_desc,
    is_auto_create_stats_on,
    is_auto_update_stats_on,
    is_auto_update_stats_async_on,
    is_query_store_on = CAST(DATABASEPROPERTYEX(name, 'IsQueryStoreOn') AS int)
FROM sys.databases
ORDER BY name;
"@

    $dbccStatus = Invoke-SqlQ @"
IF OBJECT_ID('tempdb..#DBCC') IS NOT NULL DROP TABLE #DBCC;
CREATE TABLE #DBCC
(
    ParentObject varchar(255),
    [Object] varchar(255),
    Field varchar(255),
    Value varchar(255)
);

INSERT INTO #DBCC
EXEC ('DBCC DBINFO WITH TABLERESULTS');

SELECT
    DB_NAME() AS DatabaseName,
    MAX(CASE WHEN Field = 'dbi_dbccLastKnownGood' THEN Value END) AS LastKnownGood
FROM #DBCC;
"@

    $blockingSnapshot = Invoke-SqlQ @"
SELECT TOP (20)
    er.session_id,
    er.blocking_session_id,
    er.wait_type,
    er.wait_time AS wait_duration_ms,
    er.status,
    DB_NAME(er.database_id) AS DatabaseName,
    es.login_name,
    es.host_name,
    es.program_name,
    LEFT(st.text, 4000) AS SqlText
FROM sys.dm_exec_requests er
JOIN sys.dm_exec_sessions es
    ON er.session_id = es.session_id
OUTER APPLY sys.dm_exec_sql_text(er.sql_handle) st
WHERE er.blocking_session_id <> 0
   OR EXISTS
   (
       SELECT 1
       FROM sys.dm_exec_requests er2
       WHERE er2.blocking_session_id = er.session_id
   )
ORDER BY er.wait_time DESC;
"@

    $fileSpace = Invoke-SqlQ @"
;WITH FileStats AS
(
    SELECT
        DB_NAME() AS DatabaseName,
        df.name AS LogicalFileName,
        df.type_desc,
        CAST(df.size / 128.0 AS decimal(18,2)) AS FileSizeMB,
        CAST(FILEPROPERTY(df.name, 'SpaceUsed') / 128.0 AS decimal(18,2)) AS SpaceUsedMB
    FROM sys.database_files df
)
SELECT
    DatabaseName,
    LogicalFileName,
    type_desc,
    FileSizeMB,
    SpaceUsedMB,
    CAST(FileSizeMB - SpaceUsedMB AS decimal(18,2)) AS FreeMB,
    CAST(CASE WHEN FileSizeMB = 0 THEN 0 ELSE ((FileSizeMB - SpaceUsedMB) / FileSizeMB) * 100 END AS decimal(18,2)) AS FreePct
FROM FileStats
ORDER BY type_desc, LogicalFileName;
"@

    $queryStoreRegressions = Invoke-SqlQ @"
IF EXISTS (SELECT 1 FROM sys.database_query_store_options WHERE actual_state_desc IN ('READ_WRITE','READ_ONLY'))
BEGIN
    ;WITH q AS
    (
        SELECT TOP (15)
            qsq.query_id,
            qsp.plan_id,
            rs.avg_duration,
            rs.count_executions,
            CAST(AVG(rs.avg_duration) OVER (PARTITION BY qsq.query_id) AS decimal(18,2)) AS QueryAvgDuration,
            CAST(
                CASE 
                    WHEN AVG(rs.avg_duration) OVER (PARTITION BY qsq.query_id) = 0 THEN 0
                    ELSE ((rs.avg_duration - AVG(rs.avg_duration) OVER (PARTITION BY qsq.query_id))
                         / AVG(rs.avg_duration) OVER (PARTITION BY qsq.query_id)) * 100
                END AS decimal(18,2)
            ) AS DurationRegressionPct,
            LEFT(qt.query_sql_text, 1000) AS QueryText
        FROM sys.query_store_runtime_stats rs
        JOIN sys.query_store_plan qsp
            ON rs.plan_id = qsp.plan_id
        JOIN sys.query_store_query qsq
            ON qsp.query_id = qsq.query_id
        JOIN sys.query_store_query_text qt
            ON qsq.query_text_id = qt.query_text_id
        ORDER BY DurationRegressionPct DESC, rs.avg_duration DESC
    )
    SELECT *
    FROM q
    WHERE DurationRegressionPct > 0
    ORDER BY DurationRegressionPct DESC, avg_duration DESC;
END
ELSE
BEGIN
    SELECT
        CAST(NULL AS int) AS query_id,
        CAST(NULL AS int) AS plan_id,
        CAST(NULL AS decimal(18,2)) AS avg_duration,
        CAST(NULL AS bigint) AS count_executions,
        CAST(NULL AS decimal(18,2)) AS QueryAvgDuration,
        CAST(NULL AS decimal(18,2)) AS DurationRegressionPct,
        CAST('Query Store is not enabled for this database.' AS nvarchar(1000)) AS QueryText
    WHERE 1 = 0;
END
"@
}
catch {
    Write-Log "Metric collection failed. $($_.Exception.Message)" "ERROR"
    throw
}

$healthObjects             = Ensure-Array -InputObject (Convert-QueryResultToObjects -InputObject $health)
$backupGapObjects          = Ensure-Array -InputObject (Convert-QueryResultToObjects -InputObject $backupGaps)
$jobFailObjects            = Ensure-Array -InputObject (Convert-QueryResultToObjects -InputObject $jobFails)
$topWaitObjects            = Ensure-Array -InputObject (Convert-QueryResultToObjects -InputObject $topWaits)
$fragObjects               = Ensure-Array -InputObject (Convert-QueryResultToObjects -InputObject $frag)
$serverInfoObjects         = Ensure-Array -InputObject (Convert-QueryResultToObjects -InputObject $serverInfo)
$configSnapshotObjects     = Ensure-Array -InputObject (Convert-QueryResultToObjects -InputObject $configSnapshot)
$databaseStateObjects      = Ensure-Array -InputObject (Convert-QueryResultToObjects -InputObject $databaseStates)
$dbccStatusObjects         = Ensure-Array -InputObject (Convert-QueryResultToObjects -InputObject $dbccStatus)
$blockingObjects           = Ensure-Array -InputObject (Convert-QueryResultToObjects -InputObject $blockingSnapshot)
$fileSpaceObjects          = Ensure-Array -InputObject (Convert-QueryResultToObjects -InputObject $fileSpace)
$queryStoreObjects         = Ensure-Array -InputObject (Convert-QueryResultToObjects -InputObject $queryStoreRegressions)

$backupGapDisplay = @(
    foreach ($row in $backupGapObjects) {
        [PSCustomObject]@{
            Severity       = Get-BackupGapSeverity -Row $row
            DatabaseName   = $row.DatabaseName
            RecoveryModel  = $row.RecoveryModel
            LastFullBackup = $row.LastFullBackup
            LastDiffBackup = $row.LastDiffBackup
            LastLogBackup  = $row.LastLogBackup
        }
    }
)

$jobFailDisplay = @(
    foreach ($row in $jobFailObjects) {
        [PSCustomObject]@{
            Severity        = Get-JobFailureSeverity -Row $row
            JobName         = $row.JobName
            LastRunDateTime = $row.LastRunDateTime
            LastRunOutcome  = $row.LastRunOutcome
            Message         = $row.Message
        }
    }
)

$topWaitDisplay = @(
    foreach ($row in $topWaitObjects) {
        [PSCustomObject]@{
            Severity         = Get-WaitSeverity -Row $row
            WaitType         = $row.WaitType
            WaitTimeMs       = $row.WaitTimeMs
            SignalWaitTimeMs = $row.SignalWaitTimeMs
        }
    }
)

$fragDisplay = @(
    foreach ($row in $fragObjects) {
        [PSCustomObject]@{
            Severity            = Get-FragmentationSeverity -Row $row
            DatabaseName        = $row.DatabaseName
            SchemaName          = $row.SchemaName
            TableName           = $row.TableName
            IndexName           = $row.IndexName
            AvgFragmentationPct = $row.AvgFragmentationPct
            PageCount           = $row.PageCount
        }
    }
)

$databaseStateDisplay = @(
    foreach ($row in $databaseStateObjects) {
        [PSCustomObject]@{
            Severity                  = Get-DatabaseStateSeverity -Row $row
            name                      = $row.name
            state_desc                = $row.state_desc
            recovery_model_desc       = $row.recovery_model_desc
            user_access_desc          = $row.user_access_desc
            page_verify_option_desc   = $row.page_verify_option_desc
            is_auto_create_stats_on   = $row.is_auto_create_stats_on
            is_auto_update_stats_on   = $row.is_auto_update_stats_on
            is_auto_update_stats_async_on = $row.is_auto_update_stats_async_on
            is_query_store_on         = $row.is_query_store_on
        }
    }
)

$dbccDisplay = @(
    foreach ($row in $dbccStatusObjects) {
        [PSCustomObject]@{
            Severity     = Get-DbccSeverity -Row $row
            DatabaseName = $row.DatabaseName
            LastKnownGood = $row.LastKnownGood
        }
    }
)

$blockingDisplay = @(
    foreach ($row in $blockingObjects) {
        [PSCustomObject]@{
            Severity            = Get-BlockingSeverity -Row $row
            session_id          = $row.session_id
            blocking_session_id = $row.blocking_session_id
            wait_type           = $row.wait_type
            wait_duration_ms    = $row.wait_duration_ms
            status              = $row.status
            DatabaseName        = $row.DatabaseName
            login_name          = $row.login_name
            host_name           = $row.host_name
            program_name        = $row.program_name
            SqlText             = $row.SqlText
        }
    }
)

$fileSpaceDisplay = @(
    foreach ($row in $fileSpaceObjects) {
        [PSCustomObject]@{
            Severity        = Get-FileSpaceSeverity -Row $row
            DatabaseName    = $row.DatabaseName
            LogicalFileName = $row.LogicalFileName
            type_desc       = $row.type_desc
            FileSizeMB      = $row.FileSizeMB
            SpaceUsedMB     = $row.SpaceUsedMB
            FreeMB          = $row.FreeMB
            FreePct         = $row.FreePct
        }
    }
)

$queryStoreDisplay = @(
    foreach ($row in $queryStoreObjects) {
        [PSCustomObject]@{
            Severity              = Get-QueryStoreSeverity -Row $row
            query_id              = $row.query_id
            plan_id               = $row.plan_id
            avg_duration          = $row.avg_duration
            count_executions      = $row.count_executions
            QueryAvgDuration      = $row.QueryAvgDuration
            DurationRegressionPct = $row.DurationRegressionPct
            QueryText             = $row.QueryText
        }
    }
)

$criticalCount = @(
    $backupGapDisplay     | Where-Object { $_.Severity -eq "Critical" }
    $databaseStateDisplay | Where-Object { $_.Severity -eq "Critical" }
).Count

$highCount = @(
    $backupGapDisplay     | Where-Object { $_.Severity -eq "High" }
    $jobFailDisplay       | Where-Object { $_.Severity -eq "High" }
    $topWaitDisplay       | Where-Object { $_.Severity -eq "High" }
    $fragDisplay          | Where-Object { $_.Severity -eq "High" }
    $dbccDisplay          | Where-Object { $_.Severity -eq "High" }
    $databaseStateDisplay | Where-Object { $_.Severity -eq "High" }
    $blockingDisplay      | Where-Object { $_.Severity -eq "High" }
    $fileSpaceDisplay     | Where-Object { $_.Severity -eq "High" }
    $queryStoreDisplay    | Where-Object { $_.Severity -eq "High" }
).Count

$mediumCount = @(
    $backupGapDisplay  | Where-Object { $_.Severity -eq "Medium" }
    $topWaitDisplay    | Where-Object { $_.Severity -eq "Medium" }
    $fragDisplay       | Where-Object { $_.Severity -eq "Medium" }
    $dbccDisplay       | Where-Object { $_.Severity -eq "Medium" }
    $blockingDisplay   | Where-Object { $_.Severity -eq "Medium" }
    $fileSpaceDisplay  | Where-Object { $_.Severity -eq "Medium" }
    $queryStoreDisplay | Where-Object { $_.Severity -eq "Medium" }
).Count

$lowCount = @(
    $topWaitDisplay       | Where-Object { $_.Severity -eq "Low" }
    $fragDisplay          | Where-Object { $_.Severity -eq "Low" }
    $dbccDisplay          | Where-Object { $_.Severity -eq "Low" }
    $databaseStateDisplay | Where-Object { $_.Severity -eq "Low" }
    $blockingDisplay      | Where-Object { $_.Severity -eq "Low" }
    $fileSpaceDisplay     | Where-Object { $_.Severity -eq "Low" }
    $queryStoreDisplay    | Where-Object { $_.Severity -eq "Low" }
).Count

$immediateAttention = @()

foreach ($row in ($backupGapDisplay | Where-Object { $_.Severity -in @("Critical","High") })) {
    $immediateAttention += [PSCustomObject]@{
        Severity = $row.Severity
        Category = "Backup Compliance Exception"
        Target   = $row.DatabaseName
        Detail   = "Backup currency is outside threshold or missing."
    }
}

foreach ($row in ($jobFailDisplay | Select-Object -First 10)) {
    $immediateAttention += [PSCustomObject]@{
        Severity = $row.Severity
        Category = "SQL Agent Failure"
        Target   = $row.JobName
        Detail   = "Recent job failure detected."
    }
}

foreach ($row in ($databaseStateDisplay | Where-Object { $_.Severity -in @("Critical","High") })) {
    $immediateAttention += [PSCustomObject]@{
        Severity = $row.Severity
        Category = "Database State"
        Target   = $row.name
        Detail   = "Database state is $($row.state_desc)."
    }
}

foreach ($row in ($dbccDisplay | Where-Object { $_.Severity -in @("High","Medium") })) {
    $immediateAttention += [PSCustomObject]@{
        Severity = $row.Severity
        Category = "DBCC CHECKDB"
        Target   = $row.DatabaseName
        Detail   = if ($null -eq $row.LastKnownGood -or $row.LastKnownGood -eq "") { "No DBCC last known good value found." } else { "DBCC last known good is $($row.LastKnownGood)." }
    }
}

foreach ($row in ($blockingDisplay | Where-Object { $_.Severity -in @("High","Medium") } | Select-Object -First 10)) {
    $immediateAttention += [PSCustomObject]@{
        Severity = $row.Severity
        Category = "Blocking"
        Target   = "SPID $($row.session_id)"
        Detail   = "Blocked by SPID $($row.blocking_session_id), wait $($row.wait_duration_ms) ms, wait type $($row.wait_type)."
    }
}

foreach ($row in ($fileSpaceDisplay | Where-Object { $_.Severity -in @("High","Medium") } | Select-Object -First 10)) {
    $immediateAttention += [PSCustomObject]@{
        Severity = $row.Severity
        Category = "File Space Pressure"
        Target   = "$($row.DatabaseName) / $($row.LogicalFileName)"
        Detail   = "Free space is $($row.FreePct)%."
    }
}

$immediateAttention = @($immediateAttention | Sort-Object Severity, Category, Target -Unique)

$actionQueue = @()

foreach ($row in $backupGapDisplay) {
    $actionQueue += [PSCustomObject]@{
        Severity = $row.Severity
        Category = "Backup"
        Target   = $row.DatabaseName
        Recommendation = if ($row.RecoveryModel -eq "FULL") {
            "Validate backup chain and confirm recent log backup execution."
        } else {
            "Validate full backup schedule and retention."
        }
        TSqlSnippet = @"
SELECT database_name, type, backup_start_date, backup_finish_date
FROM msdb.dbo.backupset
WHERE database_name = '$($row.DatabaseName)'
ORDER BY backup_finish_date DESC;
"@
    }
}

foreach ($row in $jobFailDisplay) {
    $actionQueue += [PSCustomObject]@{
        Severity = $row.Severity
        Category = "SQL Agent"
        Target   = $row.JobName
        Recommendation = "Review recent job history, dependent objects, and downstream impact."
        TSqlSnippet = @"
EXEC msdb.dbo.sp_help_jobhistory @job_name = N'$($row.JobName)';
"@
    }
}

foreach ($row in ($blockingDisplay | Where-Object { $_.Severity -in @("High","Medium") })) {
    $actionQueue += [PSCustomObject]@{
        Severity = $row.Severity
        Category = "Blocking"
        Target   = "SPID $($row.session_id)"
        Recommendation = "Investigate head blocker, transaction duration, and workload source."
        TSqlSnippet = @"
SELECT session_id, blocking_session_id, wait_type, wait_time, status
FROM sys.dm_exec_requests
WHERE session_id = $($row.session_id) OR session_id = $($row.blocking_session_id);
"@
    }
}

foreach ($row in ($queryStoreDisplay | Where-Object { $_.Severity -in @("High","Medium") } | Select-Object -First 10)) {
    $actionQueue += [PSCustomObject]@{
        Severity = $row.Severity
        Category = "Query Store Regression"
        Target   = "QueryId $($row.query_id)"
        Recommendation = "Review plan changes and top regressed query execution patterns."
        TSqlSnippet = @"
SELECT TOP (20)
    qsq.query_id,
    qsp.plan_id,
    rs.avg_duration,
    rs.avg_cpu_time,
    rs.count_executions
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_plan qsp ON rs.plan_id = qsp.plan_id
JOIN sys.query_store_query qsq ON qsp.query_id = qsq.query_id
WHERE qsq.query_id = $($row.query_id)
ORDER BY rs.avg_duration DESC;
"@
    }
}

foreach ($row in ($fragDisplay | Where-Object { $_.Severity -in @("High","Medium") })) {
    $actionQueue += [PSCustomObject]@{
        Severity = $row.Severity
        Category = "Index Maintenance"
        Target   = "$($row.DatabaseName).$($row.SchemaName).$($row.TableName).$($row.IndexName)"
        Recommendation = "Review fragmentation and page count, then schedule maintenance during non-business hours."
        TSqlSnippet = @"
-- Review before maintenance
-- ALTER INDEX [$($row.IndexName)] ON [$($row.SchemaName)].[$($row.TableName)] REORGANIZE;
-- ALTER INDEX [$($row.IndexName)] ON [$($row.SchemaName)].[$($row.TableName)] REBUILD;
"@
    }
}

$actionQueue = @($actionQueue | Sort-Object Severity, Category, Target -Unique)

if ($WriteActionQueue) {
    try {
        Write-Log "Ensuring AgentActions table exists."
        Invoke-SqlNonQuery @"
IF OBJECT_ID('dbo.AgentActions', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AgentActions
    (
        ActionId INT IDENTITY(1,1) PRIMARY KEY,
        CreatedAt DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
        Severity VARCHAR(20) NOT NULL,
        Category VARCHAR(80) NOT NULL,
        TargetObject NVARCHAR(300) NOT NULL,
        Recommendation NVARCHAR(MAX) NOT NULL,
        TSqlSnippet NVARCHAR(MAX) NULL,
        Status VARCHAR(20) NOT NULL DEFAULT 'Proposed'
    );
END
"@ | Out-Null

        foreach ($action in $actionQueue) {
            $severity       = ([string]$action.Severity).Replace("'", "''")
            $category       = ([string]$action.Category).Replace("'", "''")
            $target         = ([string]$action.Target).Replace("'", "''")
            $recommendation = ([string]$action.Recommendation).Replace("'", "''")
            $snippet        = ([string]$action.TSqlSnippet).Replace("'", "''")

            Invoke-SqlNonQuery @"
INSERT INTO dbo.AgentActions
(
    Severity, Category, TargetObject, Recommendation, TSqlSnippet, Status
)
VALUES
(
    '$severity', '$category', '$target', '$recommendation', '$snippet', 'Proposed'
);
"@ | Out-Null
        }

        Write-Log "Action queue items written: $($actionQueue.Count)"
    }
    catch {
        Write-Log "Failed writing action queue. $($_.Exception.Message)" "ERROR"
    }
}

$payloadObject = [ordered]@{
    collected_at         = (Get-Date).ToString("s")
    instance             = $SqlInstance
    database             = $Database
    counts               = @{
        backup_gaps          = $backupGapDisplay.Count
        job_failures         = $jobFailDisplay.Count
        top_waits            = $topWaitDisplay.Count
        fragmentation        = $fragDisplay.Count
        dbcc_status          = $dbccDisplay.Count
        database_states      = $databaseStateDisplay.Count
        blocking             = $blockingDisplay.Count
        file_space           = $fileSpaceDisplay.Count
        query_regressions    = $queryStoreDisplay.Count
        critical             = $criticalCount
        high                 = $highCount
        medium               = $mediumCount
        low                  = $lowCount
    }
    server_info          = $serverInfoObjects
    config_snapshot      = $configSnapshotObjects
    health               = $healthObjects
    backup_gaps          = $backupGapDisplay
    job_failures         = $jobFailDisplay
    top_waits            = $topWaitDisplay
    fragmentation        = $fragDisplay
    database_states      = $databaseStateDisplay
    dbcc_status          = $dbccDisplay
    blocking             = $blockingDisplay
    file_space           = $fileSpaceDisplay
    query_regressions    = $queryStoreDisplay
    immediate_attention  = $immediateAttention
    action_queue         = $actionQueue
}

$payloadJson = $payloadObject | ConvertTo-Json -Depth 12

if ($SaveJsonPayload) {
    $jsonFile = Join-Path $JsonDir "DBA_Agent_Payload_$TimeStamp.json"
    $payloadJson | Out-File -FilePath $jsonFile -Encoding UTF8
    Write-Log "JSON payload written to: $jsonFile"
}

function Invoke-LLM {
    param(
        [Parameter(Mandatory = $true)][string]$SystemPrompt,
        [Parameter(Mandatory = $true)][string]$UserPrompt
    )

    if ([string]::IsNullOrWhiteSpace($OpenAIEndpoint) -or [string]::IsNullOrWhiteSpace($OpenAIKey)) {
        Write-Log "LLM endpoint or API key not configured. Skipping operational analysis." "WARN"
        return "<p class='empty'>Operational analysis skipped because OPENAI_ENDPOINT and/or OPENAI_API_KEY are not configured.</p>"
    }

    $requestBody = @{
        model       = $Model
        messages    = @(
            @{ role = "system"; content = $SystemPrompt },
            @{ role = "user"; content = $UserPrompt }
        )
        temperature = 0.2
    } | ConvertTo-Json -Depth 12

    $headers = @{
        Authorization = "Bearer $OpenAIKey"
        "Content-Type" = "application/json"
    }

    try {
        Write-Log "Sending payload to LLM."
        $response = Invoke-RestMethod -Method Post -Uri $OpenAIEndpoint -Headers $headers -Body $requestBody -TimeoutSec 180
        $content = $response.choices[0].message.content
        if ([string]::IsNullOrWhiteSpace($content)) { throw "LLM returned empty content." }
        Write-Log "LLM response received successfully."
        return $content
    }
    catch {
        Write-Log "LLM call failed. $($_.Exception.Message)" "ERROR"
        return "<p class='empty'>Operational analysis failed. See log file for details.</p>"
    }
}

$systemPrompt = @"
You are a senior SQL Server 2022 DBA operations assistant.
Produce a concise technical operations analysis.
Do not claim any action has been executed.
Prioritize: recoverability, integrity, blocking, regressions, failed jobs, and space pressure.
Return HTML body only.
"@

$userPrompt = @"
Create:
1. Immediate technical risk summary
2. Most likely operational concerns
3. Recommended next investigative steps
4. Monitoring focus for next 24 hours

Payload:
$payloadJson
"@

$operationalAnalysis = Invoke-LLM -SystemPrompt $systemPrompt -UserPrompt $userPrompt

$summaryItems = @()

if ($immediateAttention.Count -gt 0) {
    $summaryItems += "Detected $($immediateAttention.Count) immediate attention item(s) across backup, job, blocking, integrity, or space categories."
}
if ($backupGapDisplay.Count -gt 0) {
    $summaryItems += "Backup compliance exceptions detected for $($backupGapDisplay.Count) database(s)."
}
if ($jobFailDisplay.Count -gt 0) {
    $summaryItems += "Detected $($jobFailDisplay.Count) failed SQL Agent job(s) in the last 24 hours."
}
if ($blockingDisplay.Count -gt 0) {
    $summaryItems += "Active blocking activity detected: $($blockingDisplay.Count) row(s) captured."
}
if ($queryStoreDisplay.Count -gt 0) {
    $summaryItems += "Query Store regression candidates detected: $($queryStoreDisplay.Count)."
}
if ($summaryItems.Count -eq 0) {
    $summaryItems += "No major exceptions detected in the current collection set."
}

$dashboardSection = @"
<h2>Issue Dashboard</h2>
<div class='cards'>
    <div class='card sev-critical'><div class='label'>Critical</div><div class='value'>$criticalCount</div></div>
    <div class='card sev-high'><div class='label'>High</div><div class='value'>$highCount</div></div>
    <div class='card sev-medium'><div class='label'>Medium</div><div class='value'>$mediumCount</div></div>
    <div class='card sev-low'><div class='label'>Low</div><div class='value'>$lowCount</div></div>
    <div class='card'><div class='label'>Backup Exceptions</div><div class='value'>$($backupGapDisplay.Count)</div></div>
    <div class='card'><div class='label'>Job Failures</div><div class='value'>$($jobFailDisplay.Count)</div></div>
    <div class='card'><div class='label'>Blocking</div><div class='value'>$($blockingDisplay.Count)</div></div>
    <div class='card'><div class='label'>Regressions</div><div class='value'>$($queryStoreDisplay.Count)</div></div>
</div>
"@

$summarySection = "<h2>Technical Summary</h2><ul>"
foreach ($item in $summaryItems) {
    $summarySection += "<li>$(Convert-ToSafeHtml -Text $item)</li>"
}
$summarySection += "</ul>"

$attentionSection = "<h2>Immediate DBA Attention Required</h2>"
if ($immediateAttention.Count -eq 0) {
    $attentionSection += "<p class='empty'>No immediate attention items identified.</p>"
} else {
    foreach ($row in $immediateAttention) {
        $attentionSection += @"
<div class='action-item'>
    <div class='action-header'>$(New-SeverityBadge -Severity $row.Severity) <span class='action-category'>$(Convert-ToSafeHtml -Text $row.Category)</span></div>
    <div><b>Target:</b> $(Convert-ToSafeHtml -Text $row.Target)</div>
    <div><b>Detail:</b> $(Convert-ToSafeHtml -Text $row.Detail)</div>
</div>
"@
    }
}

$serverSection = "<h2>Server Information</h2>"
if ($serverInfoObjects.Count -gt 0) {
    $s = $serverInfoObjects[0]
    $serverSection += @"
<div class='cards'>
    <div class='card'><div class='label'>Server</div><div class='value small'>$(Convert-ToSafeHtml -Text ([string]$s.ServerName))</div></div>
    <div class='card'><div class='label'>Edition</div><div class='value small'>$(Convert-ToSafeHtml -Text ([string]$s.Edition))</div></div>
    <div class='card'><div class='label'>Version</div><div class='value small'>$(Convert-ToSafeHtml -Text ([string]$s.ProductVersion))</div></div>
    <div class='card'><div class='label'>Level</div><div class='value small'>$(Convert-ToSafeHtml -Text ([string]$s.ProductLevel))</div></div>
    <div class='card'><div class='label'>CU</div><div class='value small'>$(Convert-ToSafeHtml -Text ([string]$s.ProductUpdateLevel))</div></div>
    <div class='card'><div class='label'>Uptime Hours</div><div class='value'>$(Convert-ToSafeHtml -Text ([string]$s.UptimeHours))</div></div>
</div>
"@
}

$configSection = Convert-ObjectsToHtmlTable -Rows $configSnapshotObjects `
    -Columns @("name","value_in_use") `
    -Title "Configuration Snapshot" `
    -EmptyMessage "No configuration rows returned."

$instanceHealthSection = "<h2>Instance Health Snapshot</h2>"
if ($healthObjects.Count -gt 0) {
    $h = $healthObjects[0]
    $instanceHealthSection += @"
<div class='cards'>
    <div class='card'><div class='label'>Snapshot Time</div><div class='value small'>$(Convert-ToSafeHtml -Text ([string]$h.SnapshotTime))</div></div>
    <div class='card'><div class='label'>PLE</div><div class='value'>$(Convert-ToSafeHtml -Text ([string]$h.PageLifeExpectancy))</div></div>
    <div class='card'><div class='label'>Buffer Cache Hit Ratio</div><div class='value'>$(Convert-ToSafeHtml -Text ([string]$h.BufferCacheHitRatio))</div></div>
    <div class='card'><div class='label'>Memory Grants Pending</div><div class='value'>$(Convert-ToSafeHtml -Text ([string]$h.MemoryGrantsPending))</div></div>
    <div class='card'><div class='label'>TempDB Data Files</div><div class='value'>$(Convert-ToSafeHtml -Text ([string]$h.TempdbDataFileCount))</div></div>
    <div class='card'><div class='label'>TempDB Size MB</div><div class='value'>$(Convert-ToSafeHtml -Text ([string]$h.TempdbTotalMB))</div></div>
</div>
"@
} else {
    $instanceHealthSection += "<p class='empty'>No prior observability health snapshot rows returned.</p>"
}

$databaseStateSection = Convert-ObjectsToHtmlTable -Rows $databaseStateDisplay `
    -Columns @("Severity","name","state_desc","recovery_model_desc","user_access_desc","page_verify_option_desc","is_auto_create_stats_on","is_auto_update_stats_on","is_auto_update_stats_async_on","is_query_store_on") `
    -Title "Database State Summary" `
    -EmptyMessage "No database state rows returned."

$dbccSection = Convert-ObjectsToHtmlTable -Rows $dbccDisplay `
    -Columns @("Severity","DatabaseName","LastKnownGood") `
    -Title "DBCC CHECKDB Status" `
    -EmptyMessage "No DBCC status rows returned."

$backupSection = Convert-ObjectsToHtmlTable -Rows $backupGapDisplay `
    -Columns @("Severity","DatabaseName","RecoveryModel","LastFullBackup","LastDiffBackup","LastLogBackup") `
    -Title "Backup Compliance Exceptions" `
    -EmptyMessage "No backup compliance exceptions detected."

$jobSection = Convert-ObjectsToHtmlTable -Rows $jobFailDisplay `
    -Columns @("Severity","JobName","LastRunDateTime","LastRunOutcome","Message") `
    -Title "SQL Agent Job Failures" `
    -EmptyMessage "No recent job failures detected."

$blockingSection = Convert-ObjectsToHtmlTable -Rows $blockingDisplay `
    -Columns @("Severity","session_id","blocking_session_id","wait_type","wait_duration_ms","status","DatabaseName","login_name","host_name","program_name","SqlText") `
    -Title "Blocking and Concurrency Snapshot" `
    -EmptyMessage "No active blocking captured."

$waitSection = Convert-ObjectsToHtmlTable -Rows $topWaitDisplay `
    -Columns @("Severity","WaitType","WaitTimeMs","SignalWaitTimeMs") `
    -Title "Wait Statistics Analysis" `
    -EmptyMessage "No wait rows returned."

$fileSpaceSection = Convert-ObjectsToHtmlTable -Rows $fileSpaceDisplay `
    -Columns @("Severity","DatabaseName","LogicalFileName","type_desc","FileSizeMB","SpaceUsedMB","FreeMB","FreePct") `
    -Title "File and Log Space Usage" `
    -EmptyMessage "No file space rows returned."

$queryStoreSection = Convert-ObjectsToHtmlTable -Rows $queryStoreDisplay `
    -Columns @("Severity","query_id","plan_id","avg_duration","count_executions","QueryAvgDuration","DurationRegressionPct","QueryText") `
    -Title "Query Store Top Regressions" `
    -EmptyMessage "No Query Store regressions returned."

$fragSection = Convert-ObjectsToHtmlTable -Rows $fragDisplay `
    -Columns @("Severity","DatabaseName","SchemaName","TableName","IndexName","AvgFragmentationPct","PageCount") `
    -Title "Index Maintenance Candidates" `
    -EmptyMessage "No fragmentation candidates detected."

$actionSection = "<h2>Operational Action Queue</h2>"
if ($actionQueue.Count -eq 0) {
    $actionSection += "<p class='empty'>No action items were generated from the current dataset.</p>"
} else {
    foreach ($action in $actionQueue) {
        $actionSection += @"
<div class='action-item'>
    <div class='action-header'>$(New-SeverityBadge -Severity $action.Severity) <span class='action-category'>$(Convert-ToSafeHtml -Text $action.Category)</span></div>
    <div><b>Target:</b> $(Convert-ToSafeHtml -Text $action.Target)</div>
    <div><b>Recommendation:</b> $(Convert-ToSafeHtml -Text $action.Recommendation)</div>
    <div><b>T-SQL:</b></div>
    <pre>$(Convert-ToSafeHtml -Text $action.TSqlSnippet)</pre>
</div>
"@
    }
}

$reportFile = Join-Path $ReportsDir "DBA_Agent_Report_Technical_v4_$TimeStamp.html"

$html = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8" />
    <title>DBA Agent Technical Report - $SqlInstance</title>
    <style>
        body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; background: #ffffff; color: #222; }
        h1 { color: #1f4e79; margin-bottom: 10px; }
        h2, h3 { color: #2f75b5; margin-top: 24px; }
        table { border-collapse: collapse; width: 100%; margin-top: 12px; margin-bottom: 20px; font-size: 13px; }
        th, td { border: 1px solid #d9d9d9; padding: 8px; text-align: left; vertical-align: top; }
        th { background-color: #f2f2f2; }
        code, pre {
            background-color: #f6f6f6;
            border: 1px solid #e0e0e0;
            padding: 8px;
            display: block;
            overflow-x: auto;
            white-space: pre-wrap;
            font-size: 12px;
        }
        .meta { margin-bottom: 20px; }
        .meta p { margin: 4px 0; }
        .cards { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 12px; margin-bottom: 18px; }
        .card {
            min-width: 170px;
            padding: 14px;
            border-radius: 10px;
            background: #f8f9fb;
            border: 1px solid #dde3ea;
            box-shadow: 0 1px 3px rgba(0,0,0,0.06);
        }
        .card .label { font-size: 12px; color: #555; margin-bottom: 6px; text-transform: uppercase; }
        .card .value { font-size: 22px; font-weight: 600; color: #1f1f1f; }
        .card .value.small { font-size: 14px; line-height: 1.3; }
        .sev-critical { background: #fdeaea !important; border-color: #e6a8a8 !important; }
        .sev-high { background: #fff2e6 !important; border-color: #efc08f !important; }
        .sev-medium { background: #fff9e6 !important; border-color: #e2cf7a !important; }
        .sev-low { background: #eef8ee !important; border-color: #9fd19f !important; }
        .sev-info { background: #eef5fb !important; border-color: #a8c6e6 !important; }
        .sev-badge {
            display: inline-block;
            padding: 4px 10px;
            border-radius: 999px;
            font-size: 12px;
            font-weight: 600;
            margin-right: 8px;
        }
        .action-item {
            border: 1px solid #dde3ea;
            border-radius: 10px;
            padding: 14px;
            margin-bottom: 14px;
            background: #fcfcfd;
        }
        .action-header { margin-bottom: 10px; font-size: 14px; }
        .action-category { font-weight: 700; color: #2f75b5; }
        .empty { color: #666; font-style: italic; }
    </style>
</head>
<body>
    <h1>DBA Agent Technical Report - $SqlInstance</h1>
    <div class="meta">
        <p><b>Generated:</b> $(Get-Date)</p>
        <p><b>Database:</b> $Database</p>
        <p><b>Reports Folder:</b> $ReportsDir</p>
        <p><b>Log File:</b> $LogFile</p>
        <p><b>Action Queue Written:</b> $(if ($WriteActionQueue) { "Yes" } else { "No" })</p>
    </div>

    $dashboardSection
    $summarySection
    $attentionSection
    $serverSection
    $configSection
    $instanceHealthSection

    <h2>Operational Analysis</h2>
    $operationalAnalysis

    $databaseStateSection
    $dbccSection
    $backupSection
    $jobSection
    $blockingSection
    $waitSection
    $fileSpaceSection
    $queryStoreSection
    $fragSection
    $actionSection
</body>
</html>
"@

$html | Out-File -FilePath $reportFile -Encoding UTF8
Write-Log "HTML report written to: $reportFile"
Write-Host "Report created: $reportFile"
Write-Host "Log file: $LogFile"

if ($SaveJsonPayload) {
    Write-Host "Payload folder: $JsonDir"
}
