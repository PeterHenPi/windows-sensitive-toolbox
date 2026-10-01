[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    [Parameter(Mandatory = $true)]
    [string]$TaskDir,

    [Parameter(Mandatory = $false)]
    [ValidateSet("filename", "content")]
    [string]$ScanMode = "filename",

    [Parameter(Mandatory = $true)]
    [string]$ScanPath,

    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$RecurseValue,

    [Parameter(Mandatory = $false)]
    [string]$ExcludePathsJson = "[]",

    [Parameter(Mandatory = $true)]
    [string]$ScannerScript,

    [Parameter(Mandatory = $false)]
    [string]$ContentScannerScript = "",

    [Parameter(Mandatory = $false)]
    [string]$ContentExtensionsJson = "[]",

    [Parameter(Mandatory = $false)]
    [int]$MaxContentFileSizeMB = 50,

    [Parameter(Mandatory = $false)]
    [int]$ExtractionTimeoutSeconds = 60,

    [Parameter(Mandatory = $false)]
    [string]$IncrementalValue = "true"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$StatusPath = Join-Path $TaskDir "status.json"
$OutputPath = Join-Path $TaskDir "sensitive-scan-result.csv"
$SummaryPath = Join-Path $TaskDir "sensitive-scan-result.summary.csv"
$HtmlReportPath = Join-Path $TaskDir "sensitive-scan-result.report.html"
$StatePath = Join-Path $TaskDir "sensitive-scan-result.state.json"
$SkippedPath = Join-Path $TaskDir "skipped.csv"
$FailedPath = Join-Path $TaskDir "failed.csv"
$LogPath = Join-Path $TaskDir "scan.log"
$ChildPidPath = Join-Path $TaskDir "child.pid"

function Write-TaskStatus {
    param(
        [string]$State,
        [string]$Message,
        [hashtable]$Extra = @{}
    )

    $payload = [ordered]@{
        ok = $true
        id = $TaskId
        type = "scan"
        state = $State
        message = $Message
        updatedAt = (Get-Date).ToString("s")
        taskDir = $TaskDir
        scanMode = $ScanMode
        outputPath = $OutputPath
        summaryPath = $SummaryPath
        htmlReportPath = $HtmlReportPath
        statePath = $StatePath
        skippedPath = $SkippedPath
        failedPath = $FailedPath
        logPath = $LogPath
    }

    foreach ($key in $Extra.Keys) {
        $payload[$key] = $Extra[$key]
    }

    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StatusPath -Encoding UTF8
}

function Get-LevelCounts {
    param([object[]]$Rows)
    $counts = @{}
    foreach ($row in $Rows) {
        $level = [string]$row.SensitiveLevel
        if ([string]::IsNullOrWhiteSpace($level)) {
            $level = "未标注"
        }
        if (-not $counts.ContainsKey($level)) {
            $counts[$level] = 0
        }
        $counts[$level]++
    }
    return $counts
}

function Get-JsonStringArray {
    param([string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) {
        return @()
    }

    $parsed = $Json | ConvertFrom-Json
    if ($null -eq $parsed) {
        return @()
    }

    return @($parsed | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-NormalizedPrefix {
    param([string]$PathValue)
    $cleanPath = $PathValue.Trim()
    if ([string]::IsNullOrWhiteSpace($cleanPath)) {
        return ""
    }
    try {
        return ([System.IO.Path]::GetFullPath($cleanPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar)
    }
    catch {
        return ""
    }
}

function Test-IsExcludedPath {
    param(
        [string]$TargetPath,
        [string[]]$ExcludedPrefixes
    )

    foreach ($prefix in $ExcludedPrefixes) {
        if (-not [string]::IsNullOrWhiteSpace($prefix) -and $TargetPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-TargetFilesForEstimate {
    param(
        [string]$RootPath,
        [bool]$Recursive,
        [string[]]$ExcludedPrefixes
    )

    if ($Recursive) {
        $items = Get-ChildItem -LiteralPath $RootPath -File -Force -Recurse -ErrorAction SilentlyContinue
    }
    else {
        $items = Get-ChildItem -LiteralPath $RootPath -File -Force -ErrorAction SilentlyContinue
    }

    foreach ($item in $items) {
        if (-not (Test-IsExcludedPath -TargetPath $item.FullName -ExcludedPrefixes $ExcludedPrefixes)) {
            $item
        }
    }
}

function Get-ScanEstimate {
    param(
        [string]$RootPath,
        [bool]$Recursive,
        [string[]]$ExcludePaths,
        [string[]]$ContentExtensions,
        [int]$SizeLimitMB
    )

    $extensionSet = @{}
    foreach ($extension in $ContentExtensions) {
        $clean = $extension.Trim().TrimStart(".").ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($clean)) {
            $extensionSet[$clean] = $true
        }
    }

    $excludedPrefixes = @($ExcludePaths | ForEach-Object { Get-NormalizedPrefix -PathValue $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $maxBytes = [int64]$SizeLimitMB * 1024 * 1024
    $total = 0
    $contentEligible = 0
    $unsupported = 0
    $tooLarge = 0

    foreach ($file in (Get-TargetFilesForEstimate -RootPath $RootPath -Recursive $Recursive -ExcludedPrefixes $excludedPrefixes)) {
        $total++
        $fileType = $file.Extension.TrimStart(".").ToLowerInvariant()
        if (-not $extensionSet.ContainsKey($fileType)) {
            $unsupported++
            continue
        }
        if ($file.Length -gt $maxBytes) {
            $tooLarge++
            continue
        }
        $contentEligible++
    }

    return [PSCustomObject]@{
        totalFiles = $total
        contentEligibleFiles = $contentEligible
        unsupportedFiles = $unsupported
        tooLargeFiles = $tooLarge
    }
}

function Split-ContentScanRows {
    param([object[]]$Rows)

    $skipped = @($Rows | Where-Object { $_.ScanStatus -eq "Skipped" })
    $failed = @($Rows | Where-Object { $_.ScanStatus -eq "ExtractionFailed" })
    if ($skipped.Count -gt 0) {
        $skipped | Export-Csv -LiteralPath $SkippedPath -NoTypeInformation -Encoding UTF8
    }
    if ($failed.Count -gt 0) {
        $failed | Export-Csv -LiteralPath $FailedPath -NoTypeInformation -Encoding UTF8
    }
}

try {
    if (-not (Test-Path -LiteralPath $TaskDir)) {
        New-Item -ItemType Directory -Path $TaskDir -Force | Out-Null
    }

    Write-TaskStatus -State "running" -Message "正在启动扫描任务..." -Extra @{
        scanPath = $ScanPath
        configPath = $ConfigPath
        scannedCount = 0
        matchedCount = 0
    }

    if ($MaxContentFileSizeMB -le 0) {
        $MaxContentFileSizeMB = 50
    }
    if ($ExtractionTimeoutSeconds -le 0) {
        $ExtractionTimeoutSeconds = 60
    }

    $excludePaths = @(Get-JsonStringArray -Json $ExcludePathsJson)
    $contentExtensions = @(Get-JsonStringArray -Json $ContentExtensionsJson)
    if ($contentExtensions.Count -eq 0) {
        $contentExtensions = @("doc", "docx", "xls", "xlsx", "ppt", "pptx", "pdf", "txt", "csv")
    }
    $recurse = [System.Convert]::ToBoolean($RecurseValue)
    $incremental = [System.Convert]::ToBoolean($IncrementalValue)
    $activeScannerScript = if ($ScanMode -eq "content") { $ContentScannerScript } else { $ScannerScript }
    if ([string]::IsNullOrWhiteSpace($activeScannerScript) -or -not (Test-Path -LiteralPath $activeScannerScript)) {
        throw "扫描脚本不存在。"
    }

    $estimate = $null
    if ($ScanMode -eq "content") {
        Write-TaskStatus -State "running" -Message "正在枚举文件并估算深度扫描范围..." -Extra @{
            scanPath = $ScanPath
            configPath = $ConfigPath
            stage = "estimate"
            matchedCount = 0
        }
        $estimate = Get-ScanEstimate -RootPath $ScanPath -Recursive $recurse -ExcludePaths $excludePaths -ContentExtensions $contentExtensions -SizeLimitMB $MaxContentFileSizeMB
    }

    $scanParameters = @{
        ScanPath = $ScanPath
        ConfigPath = $ConfigPath
        OutputPath = $OutputPath
        ProgressInterval = 2000
        Recurse = $recurse
    }
    if ($excludePaths.Count -gt 0) {
        $scanParameters.ExcludePaths = $excludePaths
    }

    if ($ScanMode -eq "content") {
        $scanParameters.SummaryPath = $SummaryPath
        $scanParameters.HtmlReportPath = $HtmlReportPath
        $scanParameters.StatePath = $StatePath
        $scanParameters.MaxContentFileSizeMB = $MaxContentFileSizeMB
        $scanParameters.ExtractionTimeoutSeconds = $ExtractionTimeoutSeconds
        $scanParameters.MaskSensitiveValues = $true
        if ($incremental) {
            $scanParameters.Incremental = $true
        }
        if ($contentExtensions.Count -gt 0) {
            $scanParameters.ContentExtensions = $contentExtensions
        }
    }

    Write-TaskStatus -State "running" -Message $(if ($ScanMode -eq "content") { "正在深度扫描，读取文档内容并生成报告..." } else { "正在快速扫描，详细进度写入日志..." }) -Extra @{
        scanPath = $ScanPath
        configPath = $ConfigPath
        stage = if ($ScanMode -eq "content") { "content-scan" } else { "filename-scan" }
        scannedCount = 0
        matchedCount = 0
        estimate = $estimate
    }

    try {
        & $activeScannerScript @scanParameters *> $LogPath
    }
    catch {
        $errorPath = Join-Path $TaskDir "scan-error.log"
        $_ | Out-String | Set-Content -LiteralPath $errorPath -Encoding UTF8
        throw "扫描脚本执行失败。$($_.Exception.Message)"
    }

    $rows = @()
    if (Test-Path -LiteralPath $OutputPath) {
        $rows = @(Import-Csv -LiteralPath $OutputPath -Encoding UTF8)
    }

    if ($ScanMode -eq "content") {
        Split-ContentScanRows -Rows $rows
    }

    [array]$matchedRows = if ($ScanMode -eq "content") {
        @($rows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.SensitiveLevel) })
    }
    else {
        @($rows)
    }
    [array]$skippedRows = if ($ScanMode -eq "content") { @($rows | Where-Object { $_.ScanStatus -eq "Skipped" }) } else { @() }
    [array]$failedRows = if ($ScanMode -eq "content") { @($rows | Where-Object { $_.ScanStatus -eq "ExtractionFailed" }) } else { @() }
    [array]$samples = if ($ScanMode -eq "content") {
        @($matchedRows | Select-Object -First 20 FileName, FilePath, SensitiveLevel, MatchedKeywords, MatchScope, LineNumber, MatchedSnippet, ScanStatus, SkipReason, ExtractionMethod)
    }
    else {
        @($matchedRows | Select-Object -First 20 FileName, FilePath, SensitiveLevel, MatchedKeywords)
    }
    $levelCounts = Get-LevelCounts -Rows $matchedRows

    $completionMessage = if ($ScanMode -eq "content") { "深度扫描完成。按当前规则生成结果。" } else { "扫描完成。" }
    $estimateForStatus = if ($null -ne $estimate) {
        [ordered]@{
            totalFiles = $estimate.totalFiles
            contentEligibleFiles = $estimate.contentEligibleFiles
            unsupportedFiles = $estimate.unsupportedFiles
            tooLargeFiles = $estimate.tooLargeFiles
        }
    }
    else {
        $null
    }

    Write-TaskStatus -State "completed" -Message $completionMessage -Extra @{
        scanPath = $ScanPath
        configPath = $ConfigPath
        stage = "completed"
        scannedCount = $null
        matchedCount = @($matchedRows).Count
        skippedCount = @($skippedRows).Count
        failedCount = @($failedRows).Count
        estimate = $estimateForStatus
        levelCounts = $levelCounts
        samples = $samples
    }
}
catch {
    $currentStatus = $null
    if (Test-Path -LiteralPath $StatusPath) {
        $currentStatus = Get-Content -LiteralPath $StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    if ($null -ne $currentStatus -and $currentStatus.state -eq "canceled") {
        return
    }
    Write-TaskStatus -State "failed" -Message $_.Exception.Message -Extra @{
        scanPath = $ScanPath
        configPath = $ConfigPath
        matchedCount = 0
    }
}
