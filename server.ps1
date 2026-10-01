[CmdletBinding()]
param(
    [int]$Port = 8787,
    [switch]$NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$PublicRoot = Join-Path $Root "public"
$TasksRoot = Join-Path $Root "tasks"
$ScannerScript = Join-Path $Root "scanner\powershell-version\Scan-SensitiveFiles.ps1"
$ContentScannerScript = Join-Path $Root "scanner\content-scan-version\Scan-SensitiveFiles-WithContent.ps1"

if (-not (Test-Path -LiteralPath $TasksRoot)) {
    New-Item -ItemType Directory -Path $TasksRoot -Force | Out-Null
}

function Get-JsonBody {
    param([System.Net.HttpListenerRequest]$Request)

    if (-not $Request.HasEntityBody) {
        return [PSCustomObject]@{}
    }

    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try {
        $raw = $reader.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return [PSCustomObject]@{}
        }
        return $raw | ConvertFrom-Json
    }
    finally {
        $reader.Dispose()
    }
}

function Get-BodyProperty {
    param(
        [object]$Body,
        [string]$Name,
        [object]$DefaultValue = $null
    )

    if ($null -ne $Body -and $Body.PSObject.Properties.Match($Name).Count -gt 0) {
        return $Body.$Name
    }

    return $DefaultValue
}

function Send-Bytes {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [byte[]]$Bytes,
        [string]$ContentType = "application/octet-stream",
        [int]$StatusCode = 200
    )

    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.ContentLength64 = $Bytes.Length
    $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Response.OutputStream.Close()
}

function Send-Text {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [string]$Text,
        [string]$ContentType = "text/plain; charset=utf-8",
        [int]$StatusCode = 200
    )

    Send-Bytes -Response $Response -Bytes ([System.Text.Encoding]::UTF8.GetBytes($Text)) -ContentType $ContentType -StatusCode $StatusCode
}

function Send-Json {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [object]$Value,
        [int]$StatusCode = 200
    )

    $json = $Value | ConvertTo-Json -Depth 8
    Send-Text -Response $Response -Text $json -ContentType "application/json; charset=utf-8" -StatusCode $StatusCode
}

function New-TaskId {
    param([string]$Prefix)
    return ("{0}-{1}" -f $Prefix, (Get-Date -Format "yyyyMMdd-HHmmss-fff"))
}

function Get-PowerShellExe {
    $current = (Get-Process -Id $PID).Path
    if (-not [string]::IsNullOrWhiteSpace($current) -and (Test-Path -LiteralPath $current)) {
        return $current
    }

    $candidate = Join-Path $PSHOME "powershell.exe"
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    return "powershell.exe"
}

function Start-Worker {
    param(
        [string]$ScriptPath,
        [string[]]$Arguments
    )

    function Quote-Argument {
        param([string]$Value)
        if ($null -eq $Value) { return '""' }
        return '"' + ($Value -replace '"', '\"') + '"'
    }

    $exe = Get-PowerShellExe
    $allArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath) + $Arguments
    $argumentLine = ($allArgs | ForEach-Object { Quote-Argument -Value ([string]$_) }) -join " "
    $startInfo = @{
        FilePath = $exe
        ArgumentList = $argumentLine
        PassThru = $true
    }

    $isWindowsRuntime = ($PSVersionTable.PSEdition -eq "Desktop" -or [System.Environment]::OSVersion.Platform -eq "Win32NT")
    if ($isWindowsRuntime) {
        $startInfo.WindowStyle = "Hidden"
    }

    return Start-Process @startInfo
}

function Get-MimeType {
    param([string]$Path)
    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        ".html" { "text/html; charset=utf-8" }
        ".css" { "text/css; charset=utf-8" }
        ".js" { "application/javascript; charset=utf-8" }
        ".json" { "application/json; charset=utf-8" }
        ".svg" { "image/svg+xml" }
        default { "application/octet-stream" }
    }
}

function Resolve-PublicFile {
    param([string]$UrlPath)

    $relative = [System.Uri]::UnescapeDataString($UrlPath.TrimStart("/"))
    if ([string]::IsNullOrWhiteSpace($relative)) {
        $relative = "index.html"
    }

    $candidate = [System.IO.Path]::GetFullPath((Join-Path $PublicRoot $relative))
    $publicFull = [System.IO.Path]::GetFullPath($PublicRoot)
    if (-not $candidate.StartsWith($publicFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Invalid static path."
    }

    if (Test-Path -LiteralPath $candidate -PathType Container) {
        $candidate = Join-Path $candidate "index.html"
    }

    return $candidate
}

function Get-TaskStatus {
    param([string]$TaskId)
    $statusPath = Join-Path (Join-Path $TasksRoot $TaskId) "status.json"
    if (-not (Test-Path -LiteralPath $statusPath)) {
        return $null
    }
    return Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-CancelStatus {
    param([string]$TaskId)

    $taskDir = Join-Path $TasksRoot $TaskId
    $statusPath = Join-Path $taskDir "status.json"
    $existing = Get-TaskStatus -TaskId $TaskId
    $payload = [ordered]@{
        ok = $true
        id = $TaskId
        type = if ($null -ne $existing -and $existing.PSObject.Properties.Match("type").Count -gt 0) { $existing.type } else { "task" }
        state = "canceled"
        message = "任务已取消。"
        updatedAt = (Get-Date).ToString("s")
        taskDir = $taskDir
    }

    if ($null -ne $existing) {
        foreach ($property in $existing.PSObject.Properties) {
            if (-not $payload.Contains($property.Name)) {
                $payload[$property.Name] = $property.Value
            }
        }
        $payload["state"] = "canceled"
        $payload["message"] = "任务已取消。"
        $payload["updatedAt"] = (Get-Date).ToString("s")
    }

    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statusPath -Encoding UTF8
}

function Stop-TaskProcess {
    param([string]$TaskId)

    $taskDir = Join-Path $TasksRoot $TaskId
    if (-not (Test-Path -LiteralPath $taskDir -PathType Container)) {
        throw "任务不存在。"
    }

    $pidFiles = @("child.pid", "worker.pid") | ForEach-Object { Join-Path $taskDir $_ }
    foreach ($pidFile in $pidFiles) {
        if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
            continue
        }

        $processIdText = Get-Content -LiteralPath $pidFile -Raw -Encoding UTF8
        $processId = 0
        if ([int]::TryParse($processIdText.Trim(), [ref]$processId) -and $processId -gt 0) {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        }
    }

    Write-CancelStatus -TaskId $TaskId
}

function Test-RuleEnabled {
    param([object]$Value)

    if ($null -eq $Value) { return $true }
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($text)) { return $true }
    return $text -in @("1", "true", "yes", "y", "on")
}

function Get-RuleRows {
    param([string]$ConfigPath)

    if ([string]::IsNullOrWhiteSpace($ConfigPath) -or -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "规则文件不存在。"
    }

    $extension = [System.IO.Path]::GetExtension($ConfigPath).ToLowerInvariant()
    if ($extension -eq ".csv") {
        return @(Import-Csv -LiteralPath $ConfigPath -Encoding UTF8)
    }

    if ($extension -eq ".json") {
        $json = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($json)
    }

    throw "仅支持 CSV 或 JSON 规则文件。"
}

function Get-RuleValue {
    param(
        [object]$Rule,
        [string[]]$Names,
        [string]$DefaultValue = ""
    )

    foreach ($name in $Names) {
        if ($Rule.PSObject.Properties.Match($name).Count -gt 0) {
            $value = [string]$Rule.$name
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value.Trim()
            }
        }
    }

    return $DefaultValue
}

function Test-PiiMatch {
    param(
        [string]$PiiType,
        [string]$Text
    )

    switch ($PiiType.Trim().ToLowerInvariant()) {
        "cn_mobile" { return [regex]::IsMatch($Text, "(?<!\d)1[3-9]\d{9}(?!\d)") }
        "email" { return [regex]::IsMatch($Text, "[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) }
        "cn_id_card" { return [regex]::IsMatch($Text, "(?<!\d)\d{17}[\dXx](?!\d)") }
        "passport" { return [regex]::IsMatch($Text, "(?<![A-Z0-9])[A-Z]\d{7,8}(?![A-Z0-9])", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) }
        "bank_card" { return [regex]::IsMatch($Text, "(?<!\d)\d{16,19}(?!\d)") }
        default { return $false }
    }
}

function Invoke-RuleTest {
    param(
        [string]$ConfigPath,
        [string]$InputText,
        [string]$Scope
    )

    if ([string]::IsNullOrWhiteSpace($InputText)) {
        throw "测试文本不能为空。"
    }

    $scopeValue = if ($Scope -in @("name", "content")) { $Scope } else { "both" }
    $rules = Get-RuleRows -ConfigPath $ConfigPath
    $matches = New-Object System.Collections.Generic.List[object]
    $enabledCount = 0

    foreach ($rule in $rules) {
        $enabled = Get-RuleValue -Rule $rule -Names @("enabled") -DefaultValue "1"
        if (-not (Test-RuleEnabled -Value $enabled)) {
            continue
        }
        $enabledCount++

        $ruleScope = Get-RuleValue -Rule $rule -Names @("matchScope", "scope") -DefaultValue "name"
        if ($ruleScope -notin @("name", "content", "both")) {
            $ruleScope = "name"
        }
        if ($scopeValue -ne "both" -and $ruleScope -ne "both" -and $ruleScope -ne $scopeValue) {
            continue
        }

        $level = Get-RuleValue -Rule $rule -Names @("level", "Level") -DefaultValue "未标注"
        $priorityText = Get-RuleValue -Rule $rule -Names @("priority", "Priority") -DefaultValue "0"
        $priority = 0
        [void][int]::TryParse($priorityText, [ref]$priority)
        $keyword = Get-RuleValue -Rule $rule -Names @("keyword", "keywords", "Keyword", "Keywords")
        $matchMode = Get-RuleValue -Rule $rule -Names @("matchMode", "mode") -DefaultValue "contains"
        $piiType = Get-RuleValue -Rule $rule -Names @("piiType", "PiiType")

        $matched = $false
        $matchedText = $keyword
        $reason = ""

        if (-not [string]::IsNullOrWhiteSpace($keyword)) {
            if ($matchMode -eq "regex") {
                $matched = [regex]::IsMatch($InputText, $keyword, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                $reason = "正则匹配"
            }
            else {
                $matched = $InputText.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                $reason = "包含关键词"
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($piiType)) {
            $matched = Test-PiiMatch -PiiType $piiType -Text $InputText
            $matchedText = $piiType
            $reason = "内置识别类型"
        }

        if ($matched) {
            $matches.Add([PSCustomObject]@{
                Level = $level
                Priority = $priority
                MatchScope = $ruleScope
                MatchMode = $matchMode
                Keyword = $matchedText
                Reason = $reason
            }) | Out-Null
        }
    }

    return [PSCustomObject]@{
        ok = $true
        totalRules = @($rules).Count
        enabledRules = $enabledCount
        matchedCount = $matches.Count
        matches = @($matches | Sort-Object -Property @{ Expression = "Priority"; Descending = $true }, @{ Expression = "Level"; Descending = $false })
    }
}

function Test-CommandAvailable {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-EnvironmentReport {
    $items = New-Object System.Collections.Generic.List[object]
    function Add-Check {
        param([string]$Name, [string]$Status, [string]$Detail)
        $items.Add([PSCustomObject]@{ name = $Name; status = $Status; detail = $Detail }) | Out-Null
    }

    Add-Check -Name "PowerShell" -Status "ok" -Detail ("{0} {1}" -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
    Add-Check -Name "操作系统" -Status "ok" -Detail ([System.Environment]::OSVersion.VersionString)
    Add-Check -Name "快速扫描脚本" -Status $(if (Test-Path -LiteralPath $ScannerScript) { "ok" } else { "fail" }) -Detail $ScannerScript
    Add-Check -Name "内容扫描脚本" -Status $(if (Test-Path -LiteralPath $ContentScannerScript) { "ok" } else { "fail" }) -Detail $ContentScannerScript

    try {
        $probe = Join-Path $TasksRoot ("env-check-" + [System.Guid]::NewGuid().ToString("N") + ".tmp")
        Set-Content -LiteralPath $probe -Value "ok" -Encoding UTF8
        Remove-Item -LiteralPath $probe -Force
        Add-Check -Name "任务目录写入" -Status "ok" -Detail $TasksRoot
    }
    catch {
        Add-Check -Name "任务目录写入" -Status "fail" -Detail $_.Exception.Message
    }

    $isWindowsRuntime = ([System.Environment]::OSVersion.Platform -eq "Win32NT")
    if ($isWindowsRuntime) {
        try {
            $word = New-Object -ComObject Word.Application
            $word.Quit()
            Add-Check -Name "Word COM" -Status "ok" -Detail "可用于旧版 Word 文档提取"
        }
        catch {
            Add-Check -Name "Word COM" -Status "warn" -Detail "未检测到或不可用"
        }

        try {
            $excel = New-Object -ComObject Excel.Application
            $excel.Quit()
            Add-Check -Name "Excel COM" -Status "ok" -Detail "可用于旧版 Excel 文档提取"
        }
        catch {
            Add-Check -Name "Excel COM" -Status "warn" -Detail "未检测到或不可用"
        }
    }
    else {
        Add-Check -Name "Office COM" -Status "warn" -Detail "当前不是 Windows，COM 检测跳过"
    }

    Add-Check -Name "LibreOffice" -Status $(if ((Test-CommandAvailable -Name "soffice") -or (Test-CommandAvailable -Name "libreoffice")) { "ok" } else { "warn" }) -Detail "用于无 Office 时提取旧版 Office 文档"
    Add-Check -Name "pdftotext" -Status $(if (Test-CommandAvailable -Name "pdftotext") { "ok" } else { "warn" }) -Detail "用于 PDF 内容提取"

    if ($isWindowsRuntime) {
        try {
            $value = Get-ItemPropertyValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "LongPathsEnabled" -ErrorAction Stop
            Add-Check -Name "Windows 长路径" -Status $(if ($value -eq 1) { "ok" } else { "warn" }) -Detail ("LongPathsEnabled={0}" -f $value)
        }
        catch {
            Add-Check -Name "Windows 长路径" -Status "warn" -Detail "无法读取注册表状态"
        }
    }

    return [PSCustomObject]@{
        ok = $true
        checkedAt = (Get-Date).ToString("s")
        items = $items
    }
}

function Select-PathWithShell {
    param(
        [ValidateSet("folder", "file")]
        [string]$Kind
    )

    $isWindowsRuntime = ($PSVersionTable.PSEdition -eq "Desktop" -or [System.Environment]::OSVersion.Platform -eq "Win32NT")
    if (-not $isWindowsRuntime) {
        throw "Path picker is only available on Windows."
    }

    $shell = New-Object -ComObject Shell.Application
    if ($Kind -eq "folder") {
        $folder = $shell.BrowseForFolder(0, "请选择文件夹", 0, 0)
        if ($null -eq $folder) { return "" }
        return $folder.Self.Path
    }

    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "规则文件 (*.csv;*.json)|*.csv;*.json|所有文件 (*.*)|*.*"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.FileName
    }
    return ""
}

$listener = New-Object System.Net.HttpListener
$prefix = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()

Write-Host "Sensitive File Toolbox is running:"
Write-Host $prefix
Write-Host "Press Ctrl+C to stop."

if (-not $NoBrowser) {
    Start-Process $prefix | Out-Null
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        try {
            $path = $request.Url.AbsolutePath

            if ($path -eq "/api/scan/start" -and $request.HttpMethod -eq "POST") {
                $body = Get-JsonBody -Request $request
                $scanMode = if ([string]$body.scanMode -eq "content") { "content" } else { "filename" }
                if ([string]::IsNullOrWhiteSpace([string]$body.scanPath)) { throw "扫描目录不能为空。" }
                if ([string]::IsNullOrWhiteSpace([string]$body.configPath)) { throw "规则文件不能为空。" }
                if (-not (Test-Path -LiteralPath ([string]$body.scanPath) -PathType Container)) { throw "扫描目录不存在。" }
                if (-not (Test-Path -LiteralPath ([string]$body.configPath) -PathType Leaf)) { throw "规则文件不存在。" }
                if (-not (Test-Path -LiteralPath $ScannerScript)) { throw "扫描脚本不存在：$ScannerScript" }
                if ($scanMode -eq "content" -and -not (Test-Path -LiteralPath $ContentScannerScript)) { throw "内容扫描脚本不存在：$ContentScannerScript" }

                $taskId = New-TaskId -Prefix "SCAN"
                $taskDir = Join-Path $TasksRoot $taskId
                New-Item -ItemType Directory -Path $taskDir -Force | Out-Null
                $excludeJson = if ($null -ne $body.excludePaths) { $body.excludePaths | ConvertTo-Json -Compress } else { "[]" }
                $contentExtensions = Get-BodyProperty -Body $body -Name "contentExtensions" -DefaultValue @()
                $contentExtensionsJson = if ($null -ne $contentExtensions) { $contentExtensions | ConvertTo-Json -Compress } else { "[]" }
                $maxContentFileSizeMB = [int](Get-BodyProperty -Body $body -Name "maxContentFileSizeMB" -DefaultValue 50)
                $extractionTimeoutSeconds = [int](Get-BodyProperty -Body $body -Name "extractionTimeoutSeconds" -DefaultValue 60)
                $incremental = [bool](Get-BodyProperty -Body $body -Name "incremental" -DefaultValue $true)
                $worker = Join-Path $Root "scripts\Invoke-ScanTask.ps1"
                $process = Start-Worker -ScriptPath $worker -Arguments @(
                    "-TaskId", $taskId,
                    "-TaskDir", $taskDir,
                    "-ScanMode", $scanMode,
                    "-ScanPath", ([string]$body.scanPath),
                    "-ConfigPath", ([string]$body.configPath),
                    "-RecurseValue", ([string]([bool]$body.recurse)),
                    "-ExcludePathsJson", $excludeJson,
                    "-ScannerScript", $ScannerScript,
                    "-ContentScannerScript", $ContentScannerScript,
                    "-ContentExtensionsJson", $contentExtensionsJson,
                    "-MaxContentFileSizeMB", ([string]$maxContentFileSizeMB),
                    "-ExtractionTimeoutSeconds", ([string]$extractionTimeoutSeconds),
                    "-IncrementalValue", ([string]$incremental)
                )
                Set-Content -LiteralPath (Join-Path $taskDir "worker.pid") -Value ([string]$process.Id) -Encoding ASCII
                Send-Json -Response $response -Value ([PSCustomObject]@{ ok = $true; taskId = $taskId; pid = $process.Id })
                continue
            }

            if ($path -eq "/api/label/preview" -and $request.HttpMethod -eq "POST") {
                $body = Get-JsonBody -Request $request
                if ([string]::IsNullOrWhiteSpace([string]$body.rootPath)) { throw "处理目录不能为空。" }
                if (-not (Test-Path -LiteralPath ([string]$body.rootPath) -PathType Container)) { throw "处理目录不存在。" }

                $taskId = New-TaskId -Prefix "LABELPREVIEW"
                $taskDir = Join-Path $TasksRoot $taskId
                New-Item -ItemType Directory -Path $taskDir -Force | Out-Null
                $worker = Join-Path $Root "scripts\Invoke-LabelTask.ps1"
                $process = Start-Worker -ScriptPath $worker -Arguments @(
                    "-Mode", "Preview",
                    "-TaskId", $taskId,
                    "-TaskDir", $taskDir,
                    "-RootPath", ([string]$body.rootPath),
                    "-RecurseValue", ([string]([bool]$body.recurse)),
                    "-IncludeFilesValue", ([string]([bool]$body.includeFiles)),
                    "-IncludeFoldersValue", ([string]([bool]$body.includeFolders)),
                    "-LabelStyle", ([string]$body.labelStyle),
                    "-LabelText", ([string]$body.labelText)
                )
                Set-Content -LiteralPath (Join-Path $taskDir "worker.pid") -Value ([string]$process.Id) -Encoding ASCII
                Send-Json -Response $response -Value ([PSCustomObject]@{ ok = $true; taskId = $taskId; pid = $process.Id })
                continue
            }

            if ($path -eq "/api/label/apply" -and $request.HttpMethod -eq "POST") {
                $body = Get-JsonBody -Request $request
                if ([string]::IsNullOrWhiteSpace([string]$body.previewTaskId)) { throw "缺少预览任务 ID。" }
                $previewDir = Join-Path $TasksRoot ([string]$body.previewTaskId)
                $previewCsv = Join-Path $previewDir "label-preview.csv"
                if (-not (Test-Path -LiteralPath $previewCsv)) { throw "找不到预览结果，请先生成预览。" }

                $taskId = New-TaskId -Prefix "LABEL"
                $taskDir = Join-Path $TasksRoot $taskId
                New-Item -ItemType Directory -Path $taskDir -Force | Out-Null
                $selectedJson = if ($null -ne $body.selectedIds) { $body.selectedIds | ConvertTo-Json -Compress } else { "[]" }
                $worker = Join-Path $Root "scripts\Invoke-LabelTask.ps1"
                $process = Start-Worker -ScriptPath $worker -Arguments @(
                    "-Mode", "Apply",
                    "-TaskId", $taskId,
                    "-TaskDir", $taskDir,
                    "-PreviewCsv", $previewCsv,
                    "-SelectedIdsJson", $selectedJson
                )
                Set-Content -LiteralPath (Join-Path $taskDir "worker.pid") -Value ([string]$process.Id) -Encoding ASCII
                Send-Json -Response $response -Value ([PSCustomObject]@{ ok = $true; taskId = $taskId; pid = $process.Id })
                continue
            }

            if ($path -eq "/api/label/rollback" -and $request.HttpMethod -eq "POST") {
                $body = Get-JsonBody -Request $request
                if ([string]::IsNullOrWhiteSpace([string]$body.taskId)) { throw "缺少要回滚的任务 ID。" }
                $sourceTaskDir = Join-Path $TasksRoot ([string]$body.taskId)
                $rollbackCsv = Join-Path $sourceTaskDir "rollback-map.csv"
                if (-not (Test-Path -LiteralPath $rollbackCsv -PathType Leaf)) { throw "找不到该任务的回滚记录。" }

                $taskId = New-TaskId -Prefix "ROLLBACK"
                $taskDir = Join-Path $TasksRoot $taskId
                New-Item -ItemType Directory -Path $taskDir -Force | Out-Null
                $worker = Join-Path $Root "scripts\Invoke-LabelTask.ps1"
                $process = Start-Worker -ScriptPath $worker -Arguments @(
                    "-Mode", "Rollback",
                    "-TaskId", $taskId,
                    "-TaskDir", $taskDir,
                    "-RollbackCsv", $rollbackCsv
                )
                Set-Content -LiteralPath (Join-Path $taskDir "worker.pid") -Value ([string]$process.Id) -Encoding ASCII
                Send-Json -Response $response -Value ([PSCustomObject]@{ ok = $true; taskId = $taskId; pid = $process.Id })
                continue
            }

            if ($path -eq "/api/task/cancel" -and $request.HttpMethod -eq "POST") {
                $body = Get-JsonBody -Request $request
                if ([string]::IsNullOrWhiteSpace([string]$body.taskId)) { throw "缺少任务 ID。" }
                Stop-TaskProcess -TaskId ([string]$body.taskId)
                Send-Json -Response $response -Value ([PSCustomObject]@{ ok = $true; taskId = [string]$body.taskId })
                continue
            }

            if ($path -eq "/api/rules/test" -and $request.HttpMethod -eq "POST") {
                $body = Get-JsonBody -Request $request
                $result = Invoke-RuleTest -ConfigPath ([string]$body.configPath) -InputText ([string]$body.inputText) -Scope ([string]$body.scope)
                Send-Json -Response $response -Value $result
                continue
            }

            if ($path -eq "/api/environment/check" -and $request.HttpMethod -eq "GET") {
                Send-Json -Response $response -Value (Get-EnvironmentReport)
                continue
            }

            if ($path -eq "/api/task" -and $request.HttpMethod -eq "GET") {
                $taskId = $request.QueryString["id"]
                $status = Get-TaskStatus -TaskId $taskId
                if ($null -eq $status) {
                    Send-Json -Response $response -StatusCode 404 -Value ([PSCustomObject]@{ ok = $false; error = "任务不存在。" })
                }
                else {
                    Send-Json -Response $response -Value $status
                }
                continue
            }

            if ($path -eq "/api/tasks" -and $request.HttpMethod -eq "GET") {
                $items = @(Get-ChildItem -LiteralPath $TasksRoot -Directory -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 20 |
                    ForEach-Object { Get-TaskStatus -TaskId $_.Name } |
                    Where-Object { $null -ne $_ })
                Send-Json -Response $response -Value ([PSCustomObject]@{ ok = $true; tasks = $items })
                continue
            }

            if ($path -eq "/api/path/pick" -and $request.HttpMethod -eq "GET") {
                $kind = $request.QueryString["kind"]
                if ($kind -ne "file") { $kind = "folder" }
                $selected = Select-PathWithShell -Kind $kind
                Send-Json -Response $response -Value ([PSCustomObject]@{ ok = $true; path = $selected })
                continue
            }

            if ($path -eq "/api/path/open" -and $request.HttpMethod -eq "POST") {
                $body = Get-JsonBody -Request $request
                if ([string]::IsNullOrWhiteSpace([string]$body.path)) { throw "路径不能为空。" }
                if (-not (Test-Path -LiteralPath ([string]$body.path))) { throw "路径不存在。" }
                Start-Process ([string]$body.path) | Out-Null
                Send-Json -Response $response -Value ([PSCustomObject]@{ ok = $true })
                continue
            }

            $filePath = Resolve-PublicFile -UrlPath $path
            if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                Send-Json -Response $response -StatusCode 404 -Value ([PSCustomObject]@{ ok = $false; error = "Not found" })
                continue
            }

            Send-Bytes -Response $response -Bytes ([System.IO.File]::ReadAllBytes($filePath)) -ContentType (Get-MimeType -Path $filePath)
        }
        catch {
            Send-Json -Response $response -StatusCode 500 -Value ([PSCustomObject]@{ ok = $false; error = $_.Exception.Message })
        }
    }
}
finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }
    $listener.Close()
}
