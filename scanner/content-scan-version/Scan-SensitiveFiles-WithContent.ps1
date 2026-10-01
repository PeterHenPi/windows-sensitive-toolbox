[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ProfilePath = "",

    [Parameter(Mandatory = $false)]
    [string]$ScanPath,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\sensitive_scan_result.csv",

    [Parameter(Mandatory = $false)]
    [string]$SummaryPath = "",

    [Parameter(Mandatory = $false)]
    [string]$HtmlReportPath = "",

    [Parameter(Mandatory = $false)]
    [switch]$EstimateOnly,

    [Parameter(Mandatory = $false)]
    [switch]$Incremental,

    [Parameter(Mandatory = $false)]
    [string]$StatePath = "",

    [Parameter(Mandatory = $false)]
    [switch]$Recurse = $true,

    [Parameter(Mandatory = $false)]
    [string[]]$ExcludePaths = @(),

    [Parameter(Mandatory = $false)]
    [int]$ProgressInterval = 5000,

    [Parameter(Mandatory = $false)]
    [int]$PauseMilliseconds = 0,

    [Parameter(Mandatory = $false)]
    [int]$MaxContentFileSizeMB = 10,

    [Parameter(Mandatory = $false)]
    [int]$ExtractionTimeoutSeconds = 60,

    [Parameter(Mandatory = $false)]
    [switch]$MaskSensitiveValues,

    [Parameter(Mandatory = $false)]
    [string[]]$ContentExtensions = @("txt", "csv", "log", "json", "xml", "ini", "conf", "sql", "ps1", "bat", "cmd", "cs", "java", "py", "js", "ts", "md", "doc", "docx", "docm", "xls", "xlsx", "xlsm", "ppt", "pptx", "pptm", "pdf"),

    [Parameter(Mandatory = $false)]
    [string]$PdfToTextPath = "",

    [Parameter(Mandatory = $false)]
    [string]$LibreOfficePath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:InitialBoundParameterNames = @{}
foreach ($boundParameterName in $PSBoundParameters.Keys) {
    $script:InitialBoundParameterNames[$boundParameterName] = $true
}

function Read-InputWithDefault {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PromptText,

        [Parameter(Mandatory = $true)]
        [string]$DefaultValue
    )

    $inputValue = Read-Host "$PromptText [$DefaultValue]"
    if ([string]::IsNullOrWhiteSpace($inputValue)) {
        return $DefaultValue
    }

    return $inputValue.Trim()
}

function Test-ParameterWasBound {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return $script:InitialBoundParameterNames.ContainsKey($Name)
}

function Get-ProfileValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Profile,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Profile) {
        return $null
    }

    $property = $Profile.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Test-IsRuleEnabled {
    param(
        [Parameter(Mandatory = $false)]
        [object]$EnabledValue
    )

    if ($null -eq $EnabledValue) {
        return $true
    }

    $text = [string]$EnabledValue
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $true
    }

    switch ($text.Trim().ToLowerInvariant()) {
        "1" { return $true }
        "true" { return $true }
        "yes" { return $true }
        "y" { return $true }
        "on" { return $true }
        "0" { return $false }
        "false" { return $false }
        "no" { return $false }
        "n" { return $false }
        "off" { return $false }
        default { return $true }
    }
}

function Get-RuleScope {
    param(
        [Parameter(Mandatory = $false)]
        [string]$ScopeText
    )

    if ([string]::IsNullOrWhiteSpace($ScopeText)) {
        return "name"
    }

    $scope = $ScopeText.Trim().ToLowerInvariant()
    if ($scope -notin @("name", "content", "both")) {
        throw "Invalid config format: matchScope must be name, content, or both."
    }

    return $scope
}

function Get-RuleMode {
    param(
        [Parameter(Mandatory = $false)]
        [string]$ModeText
    )

    if ([string]::IsNullOrWhiteSpace($ModeText)) {
        return "contains"
    }

    $mode = $ModeText.Trim().ToLowerInvariant()
    if ($mode -notin @("contains", "regex")) {
        throw "Invalid config format: matchMode must be contains or regex."
    }

    return $mode
}

function Get-PiiType {
    param(
        [Parameter(Mandatory = $false)]
        [string]$PiiTypeText
    )

    if ([string]::IsNullOrWhiteSpace($PiiTypeText)) {
        return ""
    }

    $piiType = $PiiTypeText.Trim().ToLowerInvariant()
    if ($piiType -notin @("cn_mobile", "cn_id_card", "email", "bank_card", "passport", "cn_name_mobile_combo", "cn_name_id_combo", "cn_name_mobile_id_combo")) {
        throw "Invalid config format: piiType must be cn_mobile, cn_id_card, email, bank_card, passport, cn_name_mobile_combo, cn_name_id_combo, or cn_name_mobile_id_combo."
    }

    return $piiType
}

function Get-RowValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Row,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Row.PSObject.Properties.Match($Name).Count -eq 0) {
        return ""
    }

    return [string]$Row.$Name
}

function Get-LevelRules {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigFile
    )

    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        throw "Config file not found: $ConfigFile"
    }

    $extension = [System.IO.Path]::GetExtension($ConfigFile).ToLowerInvariant()
    if ($extension -ne ".csv") {
        throw "Unsupported config format: $extension. This version supports .csv only."
    }

    $rows = Import-Csv -LiteralPath $ConfigFile -Encoding UTF8
    if ($null -eq $rows -or @($rows).Count -eq 0) {
        throw "Invalid config format: CSV file is empty."
    }

    $rules = New-Object System.Collections.Generic.List[object]

    foreach ($row in $rows) {
        if ($row.PSObject.Properties.Match("enabled").Count -gt 0) {
            if (-not (Test-IsRuleEnabled -EnabledValue $row.enabled)) {
                continue
            }
        }

        $level = if ($row.PSObject.Properties.Match("level").Count -gt 0) { [string]$row.level } else { "" }
        if ([string]::IsNullOrWhiteSpace($level)) {
            throw "Invalid config format: CSV must contain a non-empty level column."
        }

        $priority = 0
        if ($row.PSObject.Properties.Match("priority").Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$row.priority)) {
            $priority = [int]$row.priority
        }

        $matchScope = Get-RuleScope -ScopeText (Get-RowValue -Row $row -Name "matchScope")
        $matchMode = Get-RuleMode -ModeText (Get-RowValue -Row $row -Name "matchMode")
        $piiType = Get-PiiType -PiiTypeText (Get-RowValue -Row $row -Name "piiType")
        $category = Get-RowValue -Row $row -Name "category"
        $notes = Get-RowValue -Row $row -Name "notes"

        $keywords = New-Object System.Collections.Generic.List[string]
        if ($row.PSObject.Properties.Match("keywords").Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$row.keywords)) {
            foreach ($keyword in ([string]$row.keywords -split '[|,;]')) {
                if (-not [string]::IsNullOrWhiteSpace($keyword)) {
                    $keywords.Add($keyword.Trim())
                }
            }
        }

        if ($row.PSObject.Properties.Match("keyword").Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$row.keyword)) {
            $keywords.Add(([string]$row.keyword).Trim())
        }

        foreach ($keyword in ($keywords | Select-Object -Unique)) {
            $rules.Add([PSCustomObject]@{
                Level      = $level.Trim()
                Priority   = $priority
                MatchScope = $matchScope
                MatchMode  = $matchMode
                Keyword    = $keyword
                PiiType    = $piiType
                Category   = $category
                Notes      = $notes
            })
        }

        if ([string]::IsNullOrWhiteSpace($piiType) -or $keywords.Count -gt 0) {
            continue
        }

        $rules.Add([PSCustomObject]@{
            Level      = $level.Trim()
            Priority   = $priority
            MatchScope = $matchScope
            MatchMode  = $matchMode
            Keyword    = ""
            PiiType    = $piiType
            Category   = $category
            Notes      = $notes
        })
    }

    return @(
        $rules |
            Sort-Object -Property @(
                @{ Expression = "Priority"; Descending = $true },
                @{ Expression = "Level"; Descending = $false },
                @{ Expression = "Keyword"; Descending = $false }
            )
    )
}

function Get-FileType {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    if ([string]::IsNullOrWhiteSpace($File.Extension)) {
        return "no-extension"
    }

    return $File.Extension.TrimStart(".").ToLowerInvariant()
}

function Test-RuleMatch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [object]$Rule
    )

    if ($Rule.MatchMode -eq "regex") {
        return $Text -imatch $Rule.Keyword
    }

    return $Text.IndexOf($Rule.Keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Test-Luhn {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NumberText
    )

    $digits = ($NumberText -replace '\D', '')
    if ($digits.Length -lt 12 -or $digits.Length -gt 19) {
        return $false
    }

    $sum = 0
    $alternate = $false
    for ($i = $digits.Length - 1; $i -ge 0; $i--) {
        $digit = [int][string]$digits[$i]
        if ($alternate) {
            $digit *= 2
            if ($digit -gt 9) {
                $digit -= 9
            }
        }
        $sum += $digit
        $alternate = -not $alternate
    }

    return ($sum % 10) -eq 0
}

function Test-ChinaIdCard {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IdText
    )

    $value = $IdText.Trim().ToUpperInvariant()
    if ($value -notmatch '^\d{17}[\dX]$') {
        return $false
    }

    $weights = @(7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2)
    $checkMap = @('1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2')
    $sum = 0

    for ($i = 0; $i -lt 17; $i++) {
        $sum += ([int][string]$value[$i]) * $weights[$i]
    }

    $expected = $checkMap[$sum % 11]
    return $expected -eq [string]$value[17]
}

function Get-ChineseNameCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($match in [regex]::Matches($Text, '(?:姓名|联系人|客户|用户|员工|收件人|申请人|持卡人)\s*[:：]?\s*([\u4e00-\u9fa5]{2,4})')) {
        if ($match.Groups.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace($match.Groups[1].Value)) {
            $candidates.Add($match.Groups[1].Value)
        }
    }

    foreach ($match in [regex]::Matches($Text, '(?<![\u4e00-\u9fa5])[\u4e00-\u9fa5]{2,4}(?![\u4e00-\u9fa5])')) {
        $value = $match.Value
        if ($value -match '^(文件|目录|内容|扫描|结果|备注|说明|关键字|类型|格式|信息|数据|文件名|路径|地址|电话|手机|号码|编号|部门|公司|员工|用户|客户|联系人|会议|董事会|材料|报告|方案)$') {
            continue
        }
        $candidates.Add($value)
    }

    return @($candidates | Select-Object -Unique)
}

function Get-PiiCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$PiiType
    )

    switch ($PiiType) {
        "cn_mobile" {
            return @([regex]::Matches($Text, '(?<!\d)(?:\+?86[- ]?)?1[3-9]\d{9}(?!\d)') | ForEach-Object { $_.Value })
        }
        "cn_id_card" {
            return @([regex]::Matches($Text, '(?<!\d)\d{17}[\dXx](?!\d)') | ForEach-Object { $_.Value } | Where-Object { Test-ChinaIdCard -IdText $_ })
        }
        "email" {
            return @([regex]::Matches($Text, '\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) | ForEach-Object { $_.Value })
        }
        "bank_card" {
            return @([regex]::Matches($Text, '(?<!\d)\d{12,19}(?!\d)') | ForEach-Object { $_.Value } | Where-Object { Test-Luhn -NumberText $_ })
        }
        "passport" {
            return @([regex]::Matches($Text, '\b(?:[EG]\d{8}|P\d{7}|[A-Z]\d{8,9})\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) | ForEach-Object { $_.Value })
        }
        "cn_name_mobile_combo" {
            $names = @(Get-ChineseNameCandidates -Text $Text)
            $mobiles = @(Get-PiiCandidates -Text $Text -PiiType "cn_mobile")
            if ($names.Count -gt 0 -and $mobiles.Count -gt 0) {
                return @("{0}|{1}" -f $names[0], $mobiles[0])
            }
            return @()
        }
        "cn_name_id_combo" {
            $names = @(Get-ChineseNameCandidates -Text $Text)
            $ids = @(Get-PiiCandidates -Text $Text -PiiType "cn_id_card")
            if ($names.Count -gt 0 -and $ids.Count -gt 0) {
                return @("{0}|{1}" -f $names[0], $ids[0])
            }
            return @()
        }
        "cn_name_mobile_id_combo" {
            $names = @(Get-ChineseNameCandidates -Text $Text)
            $mobiles = @(Get-PiiCandidates -Text $Text -PiiType "cn_mobile")
            $ids = @(Get-PiiCandidates -Text $Text -PiiType "cn_id_card")
            if ($names.Count -gt 0 -and $mobiles.Count -gt 0 -and $ids.Count -gt 0) {
                return @("{0}|{1}|{2}" -f $names[0], $mobiles[0], $ids[0])
            }
            return @()
        }
        default {
            return @()
        }
    }
}

function Find-PiiMatch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [object[]]$Rules,

        [Parameter(Mandatory = $true)]
        [string]$ScopeName
    )

    foreach ($rule in $Rules) {
        if ($rule.MatchScope -ne $ScopeName -and $rule.MatchScope -ne "both") {
            continue
        }

        if ([string]::IsNullOrWhiteSpace([string]$rule.PiiType)) {
            continue
        }

        $candidates = @(Get-PiiCandidates -Text $Text -PiiType $rule.PiiType)
        if ($candidates.Count -gt 0) {
            $matchScopeName = if ($ScopeName -eq "name") { "Name" } else { "Content" }
            return [PSCustomObject]@{
                Level          = $rule.Level
                Priority       = $rule.Priority
                Keyword        = ($rule.PiiType + ":" + (($candidates | Select-Object -First 1)))
                MatchScope     = $matchScopeName
                MatchedSnippet = Get-Snippet -Text (($candidates | Select-Object -First 1))
                LineNumber     = ""
            }
        }
    }

    return $null
}

function Find-NameMatch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [object[]]$Rules
    )

    $piiMatch = Find-PiiMatch -Text $FileName -Rules $Rules -ScopeName "name"
    if ($null -ne $piiMatch) {
        $piiMatch.MatchedSnippet = $FileName
        return $piiMatch
    }

    foreach ($rule in $Rules) {
        if ($rule.MatchScope -ne "name" -and $rule.MatchScope -ne "both") {
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$rule.PiiType)) {
            continue
        }

        if (Test-RuleMatch -Text $FileName -Rule $rule) {
            return [PSCustomObject]@{
                Level          = $rule.Level
                Priority       = $rule.Priority
                Keyword        = $rule.Keyword
                MatchScope     = "Name"
                MatchedSnippet = $FileName
                LineNumber     = ""
            }
        }
    }

    return $null
}

function Test-HasContentRules {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rules
    )

    foreach ($rule in $Rules) {
        if ($rule.MatchScope -eq "content" -or $rule.MatchScope -eq "both") {
            return $true
        }
    }

    return $false
}

function Get-ContentExtensionSet {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Extensions
    )

    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($extension in $Extensions) {
        if ([string]::IsNullOrWhiteSpace($extension)) {
            continue
        }

        [void]$set.Add($extension.Trim().TrimStart("."))
    }

    return $set
}

function Get-Snippet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $trimmed = $Text.Trim()
    if ($trimmed.Length -le 120) {
        return $trimmed
    }

    return $trimmed.Substring(0, 120)
}

function Mask-SensitiveText {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $masked = $Text
    $masked = [regex]::Replace($masked, '(?<!\d)(\d{6})\d{8}(\d{3}[\dXx])(?!\d)', '$1********$2')
    $masked = [regex]::Replace($masked, '(?<!\d)((?:\+?86[- ]?)?1[3-9]\d{2})\d{4}(\d{4})(?!\d)', '$1****$2')
    $masked = [regex]::Replace($masked, '([A-Z0-9._%+-]{1,3})[A-Z0-9._%+-]*(@[A-Z0-9.-]+\.[A-Z]{2,})', '$1***$2', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $masked = [regex]::Replace($masked, '(?<!\d)(\d{4})\d{4,11}(\d{4})(?!\d)', '$1****$2')
    $masked = [regex]::Replace($masked, '\b([EGP])\d{4,6}(\d{3})\b', '$1****$2', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    return $masked
}

function Convert-MatchForOutput {
    param(
        [Parameter(Mandatory = $false)]
        [object]$Match,

        [Parameter(Mandatory = $true)]
        [bool]$MaskValues
    )

    if ($null -eq $Match -or -not $MaskValues) {
        return $Match
    }

    return [PSCustomObject]@{
        Level          = $Match.Level
        Priority       = $Match.Priority
        Keyword        = Mask-SensitiveText -Text ([string]$Match.Keyword)
        MatchScope     = $Match.MatchScope
        MatchedSnippet = Mask-SensitiveText -Text ([string]$Match.MatchedSnippet)
        LineNumber     = $Match.LineNumber
    }
}

function Start-ProcessWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -PassThru
    if ($TimeoutSeconds -le 0) {
        $process.WaitForExit()
        return $process.ExitCode
    }

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try {
            $process.Kill()
            $process.WaitForExit()
        }
        catch {
        }
        return -999
    }

    return $process.ExitCode
}

function Get-XmlTextListFromZipEntry {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Compression.ZipArchive]$Archive,

        [Parameter(Mandatory = $true)]
        [string]$EntryPath,

        [Parameter(Mandatory = $true)]
        [string]$XPath,

        [Parameter(Mandatory = $false)]
        [hashtable]$NamespaceMap = @{}
    )

    $entry = $Archive.GetEntry($EntryPath)
    if ($null -eq $entry) {
        return @()
    }

    $stream = $null
    $reader = $null
    try {
        $stream = $entry.Open()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
        $xmlText = $reader.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($xmlText)) {
            return @()
        }

        $document = New-Object System.Xml.XmlDocument
        $document.LoadXml($xmlText)

        $namespaceManager = New-Object System.Xml.XmlNamespaceManager($document.NameTable)
        foreach ($key in $NamespaceMap.Keys) {
            $namespaceManager.AddNamespace($key, $NamespaceMap[$key])
        }

        $nodes = $document.SelectNodes($XPath, $namespaceManager)
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($node in $nodes) {
            if (-not [string]::IsNullOrWhiteSpace($node.InnerText)) {
                $items.Add($node.InnerText.Trim())
            }
        }

        return @($items | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
        elseif ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Get-DocxContentLines {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($File.FullName)
        $ns = @{
            "w" = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        }

        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($entryPath in @("word/document.xml", "word/header1.xml", "word/header2.xml", "word/footer1.xml", "word/footer2.xml")) {
            foreach ($line in (Get-XmlTextListFromZipEntry -Archive $archive -EntryPath $entryPath -XPath "//w:t" -NamespaceMap $ns)) {
                $lines.Add($line)
            }
        }

        return @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }
    }
}

function Get-DocContentLines {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    $word = $null
    $document = $null
    try {
        $word = New-Object -ComObject Word.Application
        $word.Visible = $false
        $word.DisplayAlerts = 0

        $document = $word.Documents.Open($File.FullName, $false, $true)
        $text = [string]$document.Content.Text
        if ([string]::IsNullOrWhiteSpace($text)) {
            return @()
        }

        return @($text -split "(`r`n|`n|`r)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    catch {
        return @()
    }
    finally {
        if ($null -ne $document) {
            $document.Close($false) | Out-Null
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($document)
        }
        if ($null -ne $word) {
            $word.Quit() | Out-Null
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($word)
        }
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
}

function Get-XlsxContentLines {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($File.FullName)
        $ns = @{
            "a" = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        }

        $sharedStrings = @()
        $sharedEntry = $archive.GetEntry("xl/sharedStrings.xml")
        if ($null -ne $sharedEntry) {
            $sharedStrings = Get-XmlTextListFromZipEntry -Archive $archive -EntryPath "xl/sharedStrings.xml" -XPath "//a:si" -NamespaceMap $ns |
                ForEach-Object { $_ }
        }

        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -notlike "xl/worksheets/*.xml") {
                continue
            }

            $stream = $null
            $reader = $null
            try {
                $stream = $entry.Open()
                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
                $xmlText = $reader.ReadToEnd()
                if ([string]::IsNullOrWhiteSpace($xmlText)) {
                    continue
                }

                $document = New-Object System.Xml.XmlDocument
                $document.LoadXml($xmlText)
                $namespaceManager = New-Object System.Xml.XmlNamespaceManager($document.NameTable)
                $namespaceManager.AddNamespace("a", $ns["a"])

                $rows = $document.SelectNodes("//a:sheetData/a:row", $namespaceManager)
                foreach ($row in $rows) {
                    $cells = New-Object System.Collections.Generic.List[string]
                    foreach ($cell in $row.SelectNodes("a:c", $namespaceManager)) {
                        $cellType = $cell.GetAttribute("t")
                        $valueNode = $cell.SelectSingleNode("a:v", $namespaceManager)
                        if ($null -eq $valueNode) {
                            continue
                        }

                        $valueText = $valueNode.InnerText
                        if ($cellType -eq "s") {
                            $index = 0
                            if ([int]::TryParse($valueText, [ref]$index) -and $index -ge 0 -and $index -lt $sharedStrings.Count) {
                                $cells.Add($sharedStrings[$index])
                            }
                        }
                        else {
                            $cells.Add($valueText)
                        }
                    }

                    $line = (($cells | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " ")
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        $lines.Add($line.Trim())
                    }
                }
            }
            finally {
                if ($null -ne $reader) {
                    $reader.Dispose()
                }
                elseif ($null -ne $stream) {
                    $stream.Dispose()
                }
            }
        }

        return @($lines)
    }
    finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }
    }
}

function Get-XlsContentLines {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    $excel = $null
    $workbook = $null
    try {
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $excel.DisplayAlerts = $false

        $workbook = $excel.Workbooks.Open($File.FullName, 0, $true)
        $lines = New-Object System.Collections.Generic.List[string]

        foreach ($worksheet in $workbook.Worksheets) {
            try {
                $usedRange = $worksheet.UsedRange
                if ($null -eq $usedRange) {
                    continue
                }

                $rowCount = [int]$usedRange.Rows.Count
                $columnCount = [int]$usedRange.Columns.Count
                for ($row = 1; $row -le $rowCount; $row++) {
                    $cells = New-Object System.Collections.Generic.List[string]
                    for ($column = 1; $column -le $columnCount; $column++) {
                        $cellText = [string]$worksheet.Cells.Item($row, $column).Text
                        if (-not [string]::IsNullOrWhiteSpace($cellText)) {
                            $cells.Add($cellText.Trim())
                        }
                    }

                    $line = ($cells -join " ").Trim()
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        $lines.Add($line)
                    }
                }
            }
            finally {
                if ($null -ne $usedRange) {
                    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($usedRange)
                }
                if ($null -ne $worksheet) {
                    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($worksheet)
                }
            }
        }

        return @($lines)
    }
    catch {
        return @()
    }
    finally {
        if ($null -ne $workbook) {
            $workbook.Close($false) | Out-Null
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($workbook)
        }
        if ($null -ne $excel) {
            $excel.Quit() | Out-Null
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
        }
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
}

function Get-PptxContentLines {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($File.FullName)
        $ns = @{
            "a" = "http://schemas.openxmlformats.org/drawingml/2006/main"
        }

        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -notlike "ppt/slides/*.xml") {
                continue
            }

            foreach ($line in (Get-XmlTextListFromZipEntry -Archive $archive -EntryPath $entry.FullName -XPath "//a:t" -NamespaceMap $ns)) {
                $lines.Add($line)
            }
        }

        return @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }
    }
}

function Get-PptContentLines {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    $powerPoint = $null
    $presentation = $null
    try {
        $powerPoint = New-Object -ComObject PowerPoint.Application
        $presentation = $powerPoint.Presentations.Open($File.FullName, $true, $false, $false)

        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($slide in $presentation.Slides) {
            try {
                foreach ($shape in $slide.Shapes) {
                    try {
                        if ($shape.HasTextFrame -and $shape.TextFrame.HasText) {
                            $text = [string]$shape.TextFrame.TextRange.Text
                            if (-not [string]::IsNullOrWhiteSpace($text)) {
                                foreach ($line in ($text -split "(`r`n|`n|`r)")) {
                                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                                        $lines.Add($line.Trim())
                                    }
                                }
                            }
                        }
                    }
                    finally {
                        if ($null -ne $shape) {
                            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shape)
                        }
                    }
                }
            }
            finally {
                if ($null -ne $slide) {
                    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($slide)
                }
            }
        }

        return @($lines)
    }
    catch {
        return @()
    }
    finally {
        if ($null -ne $presentation) {
            $presentation.Close()
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($presentation)
        }
        if ($null -ne $powerPoint) {
            $powerPoint.Quit()
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($powerPoint)
        }
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
}

function Get-PdfContentLines {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory = $false)]
        [string]$PdfToolPath,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 60
    )

    if ([string]::IsNullOrWhiteSpace($PdfToolPath)) {
        return @()
    }

    $resolvedToolPath = [System.IO.Path]::GetFullPath($PdfToolPath)
    if (-not (Test-Path -LiteralPath $resolvedToolPath)) {
        return @()
    }

    $tempOutput = [System.IO.Path]::GetTempFileName()
    try {
        $exitCode = Start-ProcessWithTimeout -FilePath $resolvedToolPath -ArgumentList @("-q", "-enc", "UTF-8", $File.FullName, $tempOutput) -TimeoutSeconds $TimeoutSeconds
        if ($exitCode -ne 0) {
            return @()
        }

        return @(Get-Content -LiteralPath $tempOutput -Encoding UTF8 -ErrorAction SilentlyContinue)
    }
    finally {
        if (Test-Path -LiteralPath $tempOutput) {
            Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue
        }
    }
}

function Convert-WithLibreOffice {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory = $true)]
        [string]$LibreOfficeExecutable,

        [Parameter(Mandatory = $true)]
        [string]$TargetExtension,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 60
    )

    if ([string]::IsNullOrWhiteSpace($LibreOfficeExecutable)) {
        return $null
    }

    $resolvedToolPath = [System.IO.Path]::GetFullPath($LibreOfficeExecutable)
    if (-not (Test-Path -LiteralPath $resolvedToolPath)) {
        return $null
    }

    $tempDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDirectory -Force | Out-Null

    try {
        $exitCode = Start-ProcessWithTimeout -FilePath $resolvedToolPath -ArgumentList @("--headless", "--convert-to", $TargetExtension, "--outdir", $tempDirectory, $File.FullName) -TimeoutSeconds $TimeoutSeconds
        if ($exitCode -ne 0) {
            return $null
        }

        $convertedPath = Join-Path -Path $tempDirectory -ChildPath ($File.BaseName + "." + $TargetExtension)
        if (-not (Test-Path -LiteralPath $convertedPath)) {
            return $null
        }

        return Get-Item -LiteralPath $convertedPath
    }
    catch {
        return $null
    }
}

function Get-LegacyOfficeContentLinesByLibreOffice {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory = $true)]
        [string]$LibreOfficeExecutable,

        [Parameter(Mandatory = $false)]
        [string]$PdfToolPath = "",

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 60
    )

    $convertedFile = $null
    try {
        switch ((Get-FileType -File $File)) {
            "doc" {
                $convertedFile = Convert-WithLibreOffice -File $File -LibreOfficeExecutable $LibreOfficeExecutable -TargetExtension "docx" -TimeoutSeconds $TimeoutSeconds
                if ($null -ne $convertedFile) {
                    return @(Get-DocxContentLines -File $convertedFile)
                }
            }
            "xls" {
                $convertedFile = Convert-WithLibreOffice -File $File -LibreOfficeExecutable $LibreOfficeExecutable -TargetExtension "xlsx" -TimeoutSeconds $TimeoutSeconds
                if ($null -ne $convertedFile) {
                    return @(Get-XlsxContentLines -File $convertedFile)
                }
            }
            "ppt" {
                $convertedFile = Convert-WithLibreOffice -File $File -LibreOfficeExecutable $LibreOfficeExecutable -TargetExtension "pptx" -TimeoutSeconds $TimeoutSeconds
                if ($null -ne $convertedFile) {
                    return @(Get-PptxContentLines -File $convertedFile)
                }
            }
        }
    }
    finally {
        if ($null -ne $convertedFile) {
            $tempRoot = Split-Path -Path $convertedFile.FullName -Parent
            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return @()
}

function Get-ExtractedContentResult {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory = $false)]
        [string]$PdfToolPath,

        [Parameter(Mandatory = $false)]
        [string]$LibreOfficeExecutable = "",

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 60
    )

    $fileType = Get-FileType -File $File
    switch ($fileType) {
        "doc" {
            $lines = @(Get-LegacyOfficeContentLinesByLibreOffice -File $File -LibreOfficeExecutable $LibreOfficeExecutable -PdfToolPath $PdfToolPath -TimeoutSeconds $TimeoutSeconds)
            if ($lines.Count -gt 0) {
                return [PSCustomObject]@{
                    Lines            = $lines
                    ScanStatus       = "Extracted"
                    SkipReason       = ""
                    ExtractionMethod = "LibreOffice"
                }
            }
            $lines = @(Get-DocContentLines -File $File)
            if ($lines.Count -gt 0) {
                return [PSCustomObject]@{
                    Lines            = $lines
                    ScanStatus       = "Extracted"
                    SkipReason       = ""
                    ExtractionMethod = "WordCom"
                }
            }
            $skipReason = if ([string]::IsNullOrWhiteSpace($LibreOfficeExecutable)) { "Legacy Word extraction failed. LibreOffice not configured and Word COM unavailable or file unreadable." } else { "Legacy Word extraction failed." }
            return [PSCustomObject]@{
                Lines            = @()
                ScanStatus       = "ExtractionFailed"
                SkipReason       = $skipReason
                ExtractionMethod = ""
            }
        }
        { $_ -in @("docx", "docm") } {
            $lines = @(Get-DocxContentLines -File $File)
            return [PSCustomObject]@{
                Lines            = $lines
                ScanStatus       = "Extracted"
                SkipReason       = ""
                ExtractionMethod = "OpenXmlWord"
            }
        }
        "xls" {
            $lines = @(Get-LegacyOfficeContentLinesByLibreOffice -File $File -LibreOfficeExecutable $LibreOfficeExecutable -PdfToolPath $PdfToolPath -TimeoutSeconds $TimeoutSeconds)
            if ($lines.Count -gt 0) {
                return [PSCustomObject]@{
                    Lines            = $lines
                    ScanStatus       = "Extracted"
                    SkipReason       = ""
                    ExtractionMethod = "LibreOffice"
                }
            }
            $lines = @(Get-XlsContentLines -File $File)
            if ($lines.Count -gt 0) {
                return [PSCustomObject]@{
                    Lines            = $lines
                    ScanStatus       = "Extracted"
                    SkipReason       = ""
                    ExtractionMethod = "ExcelCom"
                }
            }
            $skipReason = if ([string]::IsNullOrWhiteSpace($LibreOfficeExecutable)) { "Legacy Excel extraction failed. LibreOffice not configured and Excel COM unavailable or file unreadable." } else { "Legacy Excel extraction failed." }
            return [PSCustomObject]@{
                Lines            = @()
                ScanStatus       = "ExtractionFailed"
                SkipReason       = $skipReason
                ExtractionMethod = ""
            }
        }
        { $_ -in @("xlsx", "xlsm") } {
            $lines = @(Get-XlsxContentLines -File $File)
            return [PSCustomObject]@{
                Lines            = $lines
                ScanStatus       = "Extracted"
                SkipReason       = ""
                ExtractionMethod = "OpenXmlExcel"
            }
        }
        "ppt" {
            $lines = @(Get-LegacyOfficeContentLinesByLibreOffice -File $File -LibreOfficeExecutable $LibreOfficeExecutable -PdfToolPath $PdfToolPath -TimeoutSeconds $TimeoutSeconds)
            if ($lines.Count -gt 0) {
                return [PSCustomObject]@{
                    Lines            = $lines
                    ScanStatus       = "Extracted"
                    SkipReason       = ""
                    ExtractionMethod = "LibreOffice"
                }
            }
            $lines = @(Get-PptContentLines -File $File)
            if ($lines.Count -gt 0) {
                return [PSCustomObject]@{
                    Lines            = $lines
                    ScanStatus       = "Extracted"
                    SkipReason       = ""
                    ExtractionMethod = "PowerPointCom"
                }
            }
            $skipReason = if ([string]::IsNullOrWhiteSpace($LibreOfficeExecutable)) { "Legacy PowerPoint extraction failed. LibreOffice not configured and PowerPoint COM unavailable or file unreadable." } else { "Legacy PowerPoint extraction failed." }
            return [PSCustomObject]@{
                Lines            = @()
                ScanStatus       = "ExtractionFailed"
                SkipReason       = $skipReason
                ExtractionMethod = ""
            }
        }
        { $_ -in @("pptx", "pptm") } {
            $lines = @(Get-PptxContentLines -File $File)
            return [PSCustomObject]@{
                Lines            = $lines
                ScanStatus       = "Extracted"
                SkipReason       = ""
                ExtractionMethod = "OpenXmlPowerPoint"
            }
        }
        "pdf" {
            if ([string]::IsNullOrWhiteSpace($PdfToolPath)) {
                return [PSCustomObject]@{
                    Lines            = @()
                    ScanStatus       = "Skipped"
                    SkipReason       = "PDF tool not configured."
                    ExtractionMethod = ""
                }
            }

            $lines = @(Get-PdfContentLines -File $File -PdfToolPath $PdfToolPath -TimeoutSeconds $TimeoutSeconds)
            if ($lines.Count -gt 0) {
                return [PSCustomObject]@{
                    Lines            = $lines
                    ScanStatus       = "Extracted"
                    SkipReason       = ""
                    ExtractionMethod = "PdfToText"
                }
            }
            return [PSCustomObject]@{
                Lines            = @()
                ScanStatus       = "ExtractionFailed"
                SkipReason       = "PDF extraction failed."
                ExtractionMethod = ""
            }
        }
        default {
            try {
                return [PSCustomObject]@{
                    Lines            = @(Get-Content -LiteralPath $File.FullName -Encoding UTF8 -ErrorAction Stop)
                    ScanStatus       = "Extracted"
                    SkipReason       = ""
                    ExtractionMethod = "PlainText"
                }
            }
            catch {
                return [PSCustomObject]@{
                    Lines            = @()
                    ScanStatus       = "ExtractionFailed"
                    SkipReason       = "Text extraction failed."
                    ExtractionMethod = ""
                }
            }
        }
    }
}

function Find-ContentMatch {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory = $true)]
        [object[]]$Rules,

        [Parameter(Mandatory = $true)]
        [int64]$MaxContentBytes,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$AllowedExtensions,

        [Parameter(Mandatory = $false)]
        [string]$PdfToolPath = "",

        [Parameter(Mandatory = $false)]
        [string]$LibreOfficeExecutable = "",

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 60
    )

    if (-not (Test-HasContentRules -Rules $Rules)) {
        return [PSCustomObject]@{
            Match            = $null
            ScanStatus       = "NotRequested"
            SkipReason       = ""
            ExtractionMethod = ""
        }
    }

    $fileType = Get-FileType -File $File
    if (-not $AllowedExtensions.Contains($fileType)) {
        return [PSCustomObject]@{
            Match            = $null
            ScanStatus       = "Skipped"
            SkipReason       = "Extension not in content scan allowlist."
            ExtractionMethod = ""
        }
    }

    if ($File.Length -gt $MaxContentBytes) {
        return [PSCustomObject]@{
            Match            = $null
            ScanStatus       = "Skipped"
            SkipReason       = "File exceeds content scan size limit."
            ExtractionMethod = ""
        }
    }

    try {
        $contentResult = Get-ExtractedContentResult -File $File -PdfToolPath $PdfToolPath -LibreOfficeExecutable $LibreOfficeExecutable -TimeoutSeconds $TimeoutSeconds
        if ($contentResult.ScanStatus -ne "Extracted") {
            return [PSCustomObject]@{
                Match            = $null
                ScanStatus       = $contentResult.ScanStatus
                SkipReason       = $contentResult.SkipReason
                ExtractionMethod = $contentResult.ExtractionMethod
            }
        }

        $lineNumber = 0
        foreach ($line in $contentResult.Lines) {
            $lineNumber++
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            foreach ($rule in $Rules) {
                if ($rule.MatchScope -ne "content" -and $rule.MatchScope -ne "both") {
                    continue
                }

                if (-not [string]::IsNullOrWhiteSpace([string]$rule.PiiType)) {
                    $piiCandidates = @(Get-PiiCandidates -Text $line -PiiType $rule.PiiType)
                    if ($piiCandidates.Count -gt 0) {
                        return [PSCustomObject]@{
                            Match = [PSCustomObject]@{
                                Level          = $rule.Level
                                Priority       = $rule.Priority
                                Keyword        = ($rule.PiiType + ":" + (($piiCandidates | Select-Object -First 1)))
                                MatchScope     = "Content"
                                MatchedSnippet = Get-Snippet -Text $line
                                LineNumber     = $lineNumber
                            }
                            ScanStatus       = "Matched"
                            SkipReason       = ""
                            ExtractionMethod = $contentResult.ExtractionMethod
                        }
                    }
                    continue
                }

                if (Test-RuleMatch -Text $line -Rule $rule) {
                    return [PSCustomObject]@{
                        Match = [PSCustomObject]@{
                            Level          = $rule.Level
                            Priority       = $rule.Priority
                            Keyword        = $rule.Keyword
                            MatchScope     = "Content"
                            MatchedSnippet = Get-Snippet -Text $line
                            LineNumber     = $lineNumber
                        }
                        ScanStatus       = "Matched"
                        SkipReason       = ""
                        ExtractionMethod = $contentResult.ExtractionMethod
                    }
                }
            }
        }
    }
    catch {
        return [PSCustomObject]@{
            Match            = $null
            ScanStatus       = "ExtractionFailed"
            SkipReason       = "Unexpected content extraction error."
            ExtractionMethod = ""
        }
    }

    return [PSCustomObject]@{
        Match            = $null
        ScanStatus       = "ScannedNoMatch"
        SkipReason       = ""
        ExtractionMethod = $contentResult.ExtractionMethod
    }
}

function Resolve-FinalMatch {
    param(
        [Parameter(Mandatory = $false)]
        [object]$NameMatch,

        [Parameter(Mandatory = $false)]
        [object]$ContentMatch
    )

    if ($null -eq $NameMatch -and $null -eq $ContentMatch) {
        return $null
    }

    if ($null -eq $NameMatch) {
        return $ContentMatch
    }

    if ($null -eq $ContentMatch) {
        return $NameMatch
    }

    if ($ContentMatch.Priority -gt $NameMatch.Priority) {
        return $ContentMatch
    }

    if ($NameMatch.Priority -gt $ContentMatch.Priority) {
        return $NameMatch
    }

    if ($NameMatch.Level -eq $ContentMatch.Level) {
        $matchedSnippet = if (-not [string]::IsNullOrWhiteSpace([string]$ContentMatch.MatchedSnippet)) { $ContentMatch.MatchedSnippet } else { $NameMatch.MatchedSnippet }
        return [PSCustomObject]@{
            Level          = $NameMatch.Level
            Priority       = $NameMatch.Priority
            Keyword        = ($NameMatch.Keyword + "|" + $ContentMatch.Keyword)
            MatchScope     = "Name|Content"
            MatchedSnippet = $matchedSnippet
            LineNumber     = $ContentMatch.LineNumber
        }
    }

    return $NameMatch
}

function Escape-CsvValue {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Value = ""
    )

    if ($null -eq $Value) {
        return ""
    }

    $escaped = $Value.Replace('"', '""')
    if ($escaped.IndexOfAny([char[]]@(',', '"', "`r", "`n")) -ge 0) {
        return '"' + $escaped + '"'
    }

    return $escaped
}

function New-CsvLine {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Values
    )

    return (($Values | ForEach-Object { Escape-CsvValue -Value ([string]$_) }) -join ",")
}

function New-ScanStats {
    return [PSCustomObject]@{
        TotalFiles                   = 0
        TotalBytes                   = [int64]0
        IncrementalSkippedFiles      = 0
        IncrementalChangedFiles      = 0
        IncrementalDeletedFiles      = 0
        ContentEligibleFiles         = 0
        ContentEligibleBytes         = [int64]0
        SkippedByExtensionFiles      = 0
        SkippedBySizeFiles           = 0
        MatchedFiles                 = 0
        NameMatchedFiles             = 0
        ContentMatchedFiles          = 0
        ContentSkippedFiles          = 0
        ContentExtractionFailedFiles = 0
        ContentScannedNoMatchFiles   = 0
        OfficeFiles                  = 0
        PdfFiles                     = 0
        TextFiles                    = 0
        OtherFiles                   = 0
        ExtensionCounts              = @{}
        SensitiveLevelCounts         = @{}
        ScanStatusCounts             = @{}
        ExtractionMethodCounts       = @{}
        MatchScopeCounts             = @{}
    }
}

function Add-Count {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Map,

        [Parameter(Mandatory = $false)]
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        $Key = "(blank)"
    }

    if (-not $Map.ContainsKey($Key)) {
        $Map[$Key] = 0
    }

    $Map[$Key]++
}

function Get-FileStateKey {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    return $File.FullName.ToLowerInvariant()
}

function Get-FileStateRecord {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    return [PSCustomObject]@{
        Path              = $File.FullName
        Length            = [int64]$File.Length
        LastWriteTimeUtc  = $File.LastWriteTimeUtc.ToString("o")
    }
}

function Read-ScanState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $state = @{}
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $state
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $state
    }

    $parsed = $raw | ConvertFrom-Json
    $records = @()
    if ($parsed.PSObject.Properties["files"]) {
        $records = @($parsed.files)
    }
    else {
        $records = @($parsed)
    }

    foreach ($record in $records) {
        if ($null -eq $record -or [string]::IsNullOrWhiteSpace([string]$record.Path)) {
            continue
        }

        $state[((([string]$record.Path).ToLowerInvariant()))] = $record
    }

    return $state
}

function Test-FileChangedSinceState {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory = $false)]
        [object]$PreviousRecord
    )

    if ($null -eq $PreviousRecord) {
        return $true
    }

    if ([int64]$PreviousRecord.Length -ne [int64]$File.Length) {
        return $true
    }

    return ([string]$PreviousRecord.LastWriteTimeUtc) -ne $File.LastWriteTimeUtc.ToString("o")
}

function Write-ScanState {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$CurrentState,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stateDirectory = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($stateDirectory) -and -not (Test-Path -LiteralPath $stateDirectory)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    $records = @($CurrentState.Values | Sort-Object -Property Path)
    $stateObject = [PSCustomObject]@{
        version        = 1
        generatedAtUtc = [DateTime]::UtcNow.ToString("o")
        files          = $records
    }

    $json = $stateObject | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($true))
}

function Add-ExtensionCount {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ExtensionCounts,

        [Parameter(Mandatory = $true)]
        [string]$FileType
    )

    Add-Count -Map $ExtensionCounts -Key $FileType
}

function Add-FileToStats {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Stats,

        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$AllowedExtensions,

        [Parameter(Mandatory = $true)]
        [int64]$MaxContentBytes
    )

    $fileType = Get-FileType -File $File
    $Stats.TotalFiles++
    $Stats.TotalBytes += [int64]$File.Length
    Add-ExtensionCount -ExtensionCounts $Stats.ExtensionCounts -FileType $fileType

    if ($fileType -in @("doc", "docx", "docm", "xls", "xlsx", "xlsm", "ppt", "pptx", "pptm")) {
        $Stats.OfficeFiles++
    }
    elseif ($fileType -eq "pdf") {
        $Stats.PdfFiles++
    }
    elseif ($fileType -in @("txt", "csv", "log", "json", "xml", "ini", "conf", "sql", "ps1", "bat", "cmd", "cs", "java", "py", "js", "ts", "md")) {
        $Stats.TextFiles++
    }
    else {
        $Stats.OtherFiles++
    }

    if (-not $AllowedExtensions.Contains($fileType)) {
        $Stats.SkippedByExtensionFiles++
        return
    }

    if ($File.Length -gt $MaxContentBytes) {
        $Stats.SkippedBySizeFiles++
        return
    }

    $Stats.ContentEligibleFiles++
    $Stats.ContentEligibleBytes += [int64]$File.Length
}

function Format-ByteSize {
    param(
        [Parameter(Mandatory = $true)]
        [int64]$Bytes
    )

    if ($Bytes -ge 1TB) {
        return ("{0:N2} TB" -f ($Bytes / 1TB))
    }
    if ($Bytes -ge 1GB) {
        return ("{0:N2} GB" -f ($Bytes / 1GB))
    }
    if ($Bytes -ge 1MB) {
        return ("{0:N2} MB" -f ($Bytes / 1MB))
    }
    if ($Bytes -ge 1KB) {
        return ("{0:N2} KB" -f ($Bytes / 1KB))
    }

    return "$Bytes B"
}

function Write-ScanSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Stats,

        [Parameter(Mandatory = $true)]
        [string]$ReportPath
    )

    $summaryDirectory = Split-Path -Path $ReportPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($summaryDirectory) -and -not (Test-Path -LiteralPath $summaryDirectory)) {
        New-Item -ItemType Directory -Path $summaryDirectory -Force | Out-Null
    }

    $writer = New-Object System.IO.StreamWriter($ReportPath, $false, [System.Text.UTF8Encoding]::new($true))
    try {
        $writer.WriteLine("Metric,Value")
        $writer.WriteLine((New-CsvLine -Values @("TotalFiles", $Stats.TotalFiles)))
        $writer.WriteLine((New-CsvLine -Values @("TotalSizeBytes", $Stats.TotalBytes)))
        $writer.WriteLine((New-CsvLine -Values @("TotalSizeReadable", (Format-ByteSize -Bytes $Stats.TotalBytes))))
        $writer.WriteLine((New-CsvLine -Values @("IncrementalSkippedFiles", $Stats.IncrementalSkippedFiles)))
        $writer.WriteLine((New-CsvLine -Values @("IncrementalChangedFiles", $Stats.IncrementalChangedFiles)))
        $writer.WriteLine((New-CsvLine -Values @("IncrementalDeletedFiles", $Stats.IncrementalDeletedFiles)))
        $writer.WriteLine((New-CsvLine -Values @("ContentEligibleFiles", $Stats.ContentEligibleFiles)))
        $writer.WriteLine((New-CsvLine -Values @("ContentEligibleSizeBytes", $Stats.ContentEligibleBytes)))
        $writer.WriteLine((New-CsvLine -Values @("ContentEligibleSizeReadable", (Format-ByteSize -Bytes $Stats.ContentEligibleBytes))))
        $writer.WriteLine((New-CsvLine -Values @("SkippedByExtensionFiles", $Stats.SkippedByExtensionFiles)))
        $writer.WriteLine((New-CsvLine -Values @("SkippedBySizeFiles", $Stats.SkippedBySizeFiles)))
        $writer.WriteLine((New-CsvLine -Values @("MatchedFiles", $Stats.MatchedFiles)))
        $writer.WriteLine((New-CsvLine -Values @("NameMatchedFiles", $Stats.NameMatchedFiles)))
        $writer.WriteLine((New-CsvLine -Values @("ContentMatchedFiles", $Stats.ContentMatchedFiles)))
        $writer.WriteLine((New-CsvLine -Values @("ContentSkippedFiles", $Stats.ContentSkippedFiles)))
        $writer.WriteLine((New-CsvLine -Values @("ContentExtractionFailedFiles", $Stats.ContentExtractionFailedFiles)))
        $writer.WriteLine((New-CsvLine -Values @("ContentScannedNoMatchFiles", $Stats.ContentScannedNoMatchFiles)))
        $writer.WriteLine((New-CsvLine -Values @("OfficeFiles", $Stats.OfficeFiles)))
        $writer.WriteLine((New-CsvLine -Values @("PdfFiles", $Stats.PdfFiles)))
        $writer.WriteLine((New-CsvLine -Values @("TextFiles", $Stats.TextFiles)))
        $writer.WriteLine((New-CsvLine -Values @("OtherFiles", $Stats.OtherFiles)))

        foreach ($key in ($Stats.ExtensionCounts.Keys | Sort-Object)) {
            $writer.WriteLine((New-CsvLine -Values @("Extension:$key", $Stats.ExtensionCounts[$key])))
        }
        foreach ($key in ($Stats.SensitiveLevelCounts.Keys | Sort-Object)) {
            $writer.WriteLine((New-CsvLine -Values @("SensitiveLevel:$key", $Stats.SensitiveLevelCounts[$key])))
        }
        foreach ($key in ($Stats.ScanStatusCounts.Keys | Sort-Object)) {
            $writer.WriteLine((New-CsvLine -Values @("ScanStatus:$key", $Stats.ScanStatusCounts[$key])))
        }
        foreach ($key in ($Stats.ExtractionMethodCounts.Keys | Sort-Object)) {
            $writer.WriteLine((New-CsvLine -Values @("ExtractionMethod:$key", $Stats.ExtractionMethodCounts[$key])))
        }
        foreach ($key in ($Stats.MatchScopeCounts.Keys | Sort-Object)) {
            $writer.WriteLine((New-CsvLine -Values @("MatchScope:$key", $Stats.MatchScopeCounts[$key])))
        }
    }
    finally {
        $writer.Dispose()
    }
}

function Escape-Html {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Value
    )

    if ($null -eq $Value) {
        return ""
    }

    return [System.Security.SecurityElement]::Escape($Value)
}

function New-HtmlMetricCard {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return "<section class=""card""><div class=""label"">$(Escape-Html -Value $Label)</div><div class=""value"">$(Escape-Html -Value $Value)</div></section>"
}

function New-HtmlTable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [hashtable]$Map,

        [Parameter(Mandatory = $false)]
        [int]$Top = 20
    )

    $rows = New-Object System.Text.StringBuilder
    foreach ($entry in ($Map.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First $Top)) {
        [void]$rows.AppendLine("<tr><td>$(Escape-Html -Value ([string]$entry.Key))</td><td>$($entry.Value)</td></tr>")
    }

    if ($rows.Length -eq 0) {
        [void]$rows.AppendLine("<tr><td colspan=""2"">No data</td></tr>")
    }

    return @"
<section class="panel">
  <h2>$(Escape-Html -Value $Title)</h2>
  <table>
    <thead><tr><th>Name</th><th>Count</th></tr></thead>
    <tbody>
$($rows.ToString())
    </tbody>
  </table>
</section>
"@
}

function Write-HtmlReport {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Stats,

        [Parameter(Mandatory = $true)]
        [string]$ReportPath,

        [Parameter(Mandatory = $true)]
        [string]$ResultPath,

        [Parameter(Mandatory = $true)]
        [string]$SummaryPath,

        [Parameter(Mandatory = $true)]
        [bool]$EstimateOnly,

        [Parameter(Mandatory = $true)]
        [bool]$Incremental
    )

    $reportDirectory = Split-Path -Path $ReportPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($reportDirectory) -and -not (Test-Path -LiteralPath $reportDirectory)) {
        New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
    }

    $generatedAt = [DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss")
    $modeText = if ($EstimateOnly) { "Estimate only" } elseif ($Incremental) { "Incremental scan" } else { "Full scan" }
    $cards = @(
        (New-HtmlMetricCard -Label "Mode" -Value $modeText),
        (New-HtmlMetricCard -Label "Total files" -Value ([string]$Stats.TotalFiles)),
        (New-HtmlMetricCard -Label "Total size" -Value (Format-ByteSize -Bytes $Stats.TotalBytes)),
        (New-HtmlMetricCard -Label "Matched files" -Value ([string]$Stats.MatchedFiles)),
        (New-HtmlMetricCard -Label "Content eligible" -Value ([string]$Stats.ContentEligibleFiles)),
        (New-HtmlMetricCard -Label "Extraction failed" -Value ([string]$Stats.ContentExtractionFailedFiles)),
        (New-HtmlMetricCard -Label "Skipped unchanged" -Value ([string]$Stats.IncrementalSkippedFiles)),
        (New-HtmlMetricCard -Label "Deleted since state" -Value ([string]$Stats.IncrementalDeletedFiles))
    ) -join "`n"

    $html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Sensitive File Scan Report</title>
  <style>
    :root {
      --bg: #f5f7fa;
      --panel: #ffffff;
      --text: #18202f;
      --muted: #667085;
      --line: #d8dee8;
      --accent: #0f766e;
      --warn: #b42318;
    }
    body {
      margin: 0;
      font-family: "Segoe UI", "Microsoft YaHei", sans-serif;
      background: var(--bg);
      color: var(--text);
    }
    header {
      padding: 28px 32px 18px;
      background: #ffffff;
      border-bottom: 1px solid var(--line);
    }
    h1 {
      margin: 0 0 8px;
      font-size: 26px;
      font-weight: 650;
    }
    .meta {
      color: var(--muted);
      font-size: 13px;
      line-height: 1.7;
    }
    main {
      padding: 24px 32px 40px;
    }
    .cards {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
      gap: 12px;
      margin-bottom: 20px;
    }
    .card, .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
    }
    .card {
      padding: 16px;
    }
    .label {
      font-size: 12px;
      color: var(--muted);
      margin-bottom: 8px;
    }
    .value {
      font-size: 22px;
      font-weight: 700;
      color: var(--accent);
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
      gap: 16px;
    }
    .panel {
      padding: 16px;
      overflow: auto;
    }
    h2 {
      font-size: 16px;
      margin: 0 0 12px;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 13px;
    }
    th, td {
      text-align: left;
      border-bottom: 1px solid var(--line);
      padding: 8px 6px;
      vertical-align: top;
    }
    th {
      color: var(--muted);
      font-weight: 600;
    }
    footer {
      padding: 0 32px 28px;
      color: var(--muted);
      font-size: 12px;
    }
  </style>
</head>
<body>
  <header>
    <h1>Sensitive File Scan Report</h1>
    <div class="meta">
      Generated at: $(Escape-Html -Value $generatedAt)<br>
      Result CSV: $(Escape-Html -Value $ResultPath)<br>
      Summary CSV: $(Escape-Html -Value $SummaryPath)
    </div>
  </header>
  <main>
    <section class="cards">
$cards
    </section>
    <section class="grid">
$(New-HtmlTable -Title "Sensitive Levels" -Map $Stats.SensitiveLevelCounts -Top 20)
$(New-HtmlTable -Title "Scan Status" -Map $Stats.ScanStatusCounts -Top 20)
$(New-HtmlTable -Title "Extraction Methods" -Map $Stats.ExtractionMethodCounts -Top 20)
$(New-HtmlTable -Title "Match Scope" -Map $Stats.MatchScopeCounts -Top 20)
$(New-HtmlTable -Title "File Extensions" -Map $Stats.ExtensionCounts -Top 30)
    </section>
  </main>
  <footer>Generated by Sensitive File Scanner.</footer>
</body>
</html>
"@

    [System.IO.File]::WriteAllText($ReportPath, $html, [System.Text.UTF8Encoding]::new($true))
}

function Show-ScanSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Stats
    )

    Write-Host "Summary: total files $($Stats.TotalFiles), total size $(Format-ByteSize -Bytes $Stats.TotalBytes)."
    Write-Host "Summary: incremental changed $($Stats.IncrementalChangedFiles), skipped unchanged $($Stats.IncrementalSkippedFiles), deleted since last state $($Stats.IncrementalDeletedFiles)."
    Write-Host "Summary: content eligible files $($Stats.ContentEligibleFiles), eligible size $(Format-ByteSize -Bytes $Stats.ContentEligibleBytes)."
    Write-Host "Summary: matched $($Stats.MatchedFiles), skipped by extension $($Stats.SkippedByExtensionFiles), skipped by size $($Stats.SkippedBySizeFiles), extraction failed $($Stats.ContentExtractionFailedFiles)."
}

function Test-IsExcludedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath,

        [Parameter(Mandatory = $false)]
        [string[]]$ExcludedPrefixes = @()
    )

    foreach ($prefix in $ExcludedPrefixes) {
        if ($TargetPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-NormalizedPrefix {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue
    )

    $cleanPath = $PathValue.Trim()
    if (($cleanPath.StartsWith('"') -and $cleanPath.EndsWith('"')) -or ($cleanPath.StartsWith("'") -and $cleanPath.EndsWith("'"))) {
        $cleanPath = $cleanPath.Substring(1, $cleanPath.Length - 2).Trim()
    }

    if ([string]::IsNullOrWhiteSpace($cleanPath)) {
        throw "Exclude path is empty."
    }

    $resolved = [System.IO.Path]::GetFullPath($cleanPath).TrimEnd('\')
    return $resolved + '\'
}

function Get-ExpandedExcludePaths {
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$RawPaths = @()
    )

    $expandedPaths = New-Object System.Collections.Generic.List[string]

    foreach ($rawPath in $RawPaths) {
        if ([string]::IsNullOrWhiteSpace($rawPath)) {
            continue
        }

        foreach ($part in ($rawPath -split '[,;]')) {
            $candidate = $part.Trim()
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                continue
            }

            $expandedPaths.Add($candidate)
        }
    }

    return @($expandedPaths | Select-Object -Unique)
}

function Get-TargetFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,

        [Parameter(Mandatory = $true)]
        [bool]$Recursive,

        [Parameter(Mandatory = $false)]
        [string[]]$ExcludedPrefixes = @()
    )

    $rootDirectory = Get-Item -LiteralPath $RootPath -ErrorAction Stop
    if (-not $rootDirectory.PSIsContainer) {
        throw "Scan path must be a directory: $RootPath"
    }

    if (-not $Recursive) {
        foreach ($item in (Get-ChildItem -LiteralPath $rootDirectory.FullName -File -Force -ErrorAction SilentlyContinue)) {
            if (-not (Test-IsExcludedPath -TargetPath $item.FullName -ExcludedPrefixes $ExcludedPrefixes)) {
                $item
            }
        }
        return
    }

    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($rootDirectory.FullName)

    while ($stack.Count -gt 0) {
        $currentPath = $stack.Pop()
        $childItems = @(Get-ChildItem -LiteralPath $currentPath -Force -ErrorAction SilentlyContinue)

        foreach ($child in $childItems) {
            if ($child.PSIsContainer) {
                $directoryPrefix = Get-NormalizedPrefix -PathValue $child.FullName
                if (-not (Test-IsExcludedPath -TargetPath $directoryPrefix -ExcludedPrefixes $ExcludedPrefixes)) {
                    $stack.Push($child.FullName)
                }
                continue
            }

            if (-not (Test-IsExcludedPath -TargetPath $child.FullName -ExcludedPrefixes $ExcludedPrefixes)) {
                $child
            }
        }
    }
}

$profile = $null
if (-not [string]::IsNullOrWhiteSpace($ProfilePath)) {
    if (-not (Test-Path -LiteralPath $ProfilePath)) {
        throw "Profile file not found: $ProfilePath"
    }

    $profile = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json

    if (-not (Test-ParameterWasBound -Name "ScanPath")) {
        $profileValue = Get-ProfileValue -Profile $profile -Name "scanPath"
        if ($null -ne $profileValue) { $ScanPath = [string]$profileValue }
    }
    if (-not (Test-ParameterWasBound -Name "ConfigPath")) {
        $profileValue = Get-ProfileValue -Profile $profile -Name "configPath"
        if ($null -ne $profileValue) { $ConfigPath = [string]$profileValue }
    }
    if (-not (Test-ParameterWasBound -Name "OutputPath")) {
        $profileValue = Get-ProfileValue -Profile $profile -Name "outputPath"
        if ($null -ne $profileValue) { $OutputPath = [string]$profileValue }
    }
    if (-not (Test-ParameterWasBound -Name "SummaryPath")) {
        $profileValue = Get-ProfileValue -Profile $profile -Name "summaryPath"
        if ($null -ne $profileValue) { $SummaryPath = [string]$profileValue }
    }
    if (-not (Test-ParameterWasBound -Name "HtmlReportPath")) {
        $profileValue = Get-ProfileValue -Profile $profile -Name "htmlReportPath"
        if ($null -ne $profileValue) { $HtmlReportPath = [string]$profileValue }
    }
    if (-not (Test-ParameterWasBound -Name "EstimateOnly")) {
        $profileValue = Get-ProfileValue -Profile $profile -Name "estimateOnly"
        if ($null -ne $profileValue -and [bool]$profileValue) { $EstimateOnly = [System.Management.Automation.SwitchParameter]::Present }
    }
    if (-not (Test-ParameterWasBound -Name "Incremental")) {
        $profileValue = Get-ProfileValue -Profile $profile -Name "incremental"
        if ($null -ne $profileValue -and [bool]$profileValue) { $Incremental = [System.Management.Automation.SwitchParameter]::Present }
    }
    if (-not (Test-ParameterWasBound -Name "StatePath")) {
        $profileValue = Get-ProfileValue -Profile $profile -Name "statePath"
        if ($null -ne $profileValue) { $StatePath = [string]$profileValue }
    }
    if (-not (Test-ParameterWasBound -Name "Recurse")) {
        $profileValue = Get-ProfileValue -Profile $profile -Name "recurse"
        if ($null -ne $profileValue) { $Recurse = [bool]$profileValue }
    }
    if (-not (Test-ParameterWasBound -Name "ExcludePaths")) {
        $profileValue = Get-ProfileValue -Profile $profile -Name "excludePaths"
        if ($null -ne $profileValue) { $ExcludePaths = @($profileValue | ForEach-Object { [string]$_ }) }
    }
    if (-not (Test-ParameterWasBound -Name "ProgressInterval")) {
        $profileValue = Get-ProfileValue -Profile $profile -Name "progressInterval"
        if ($null -ne $profileValue) { $ProgressInterval = [int]$profileValue }
    }
    if (-not (Test-ParameterWasBound -Name "PauseMilliseconds")) {
        $profileValue = Get-ProfileValue -Profile $profile -Name "pauseMilliseconds"
        if ($null -ne $profileValue) { $PauseMilliseconds = [int]$profileValue }
    }
    if (-not (Test-ParameterWasBound -Name "MaxContentFileSizeMB")) {
        $profileValue = Get-ProfileValue -Profile $profile -Name "maxContentFileSizeMB"
        if ($null -ne $profileValue) { $MaxContentFileSizeMB = [int]$profileValue }
    }
    if (-not (Test-ParameterWasBound -Name "ExtractionTimeoutSeconds")) {
        $profileValue = Get-ProfileValue -Profile $profile -Name "extractionTimeoutSeconds"
        if ($null -ne $profileValue) { $ExtractionTimeoutSeconds = [int]$profileValue }
    }
    if (-not (Test-ParameterWasBound -Name "MaskSensitiveValues")) {
        $profileValue = Get-ProfileValue -Profile $profile -Name "maskSensitiveValues"
        if ($null -ne $profileValue -and [bool]$profileValue) { $MaskSensitiveValues = [System.Management.Automation.SwitchParameter]::Present }
    }
    if (-not (Test-ParameterWasBound -Name "ContentExtensions")) {
        $profileValue = Get-ProfileValue -Profile $profile -Name "contentExtensions"
        if ($null -ne $profileValue) { $ContentExtensions = @($profileValue | ForEach-Object { [string]$_ }) }
    }
    if (-not (Test-ParameterWasBound -Name "PdfToTextPath")) {
        $profileValue = Get-ProfileValue -Profile $profile -Name "pdfToTextPath"
        if ($null -ne $profileValue) { $PdfToTextPath = [string]$profileValue }
    }
    if (-not (Test-ParameterWasBound -Name "LibreOfficePath")) {
        $profileValue = Get-ProfileValue -Profile $profile -Name "libreOfficePath"
        if ($null -ne $profileValue) { $LibreOfficePath = [string]$profileValue }
    }
}

if ([string]::IsNullOrWhiteSpace($ScanPath)) {
    Write-Host "No parameters detected. Interactive mode started."
    $ScanPath = Read-InputWithDefault -PromptText "Enter scan directory" -DefaultValue "D:\Data"
    $ConfigPath = Read-InputWithDefault -PromptText "Enter rule file path (.csv)" -DefaultValue ".\keywords.sample.csv"
    $OutputPath = Read-InputWithDefault -PromptText "Enter output CSV path" -DefaultValue ".\result\sensitive_scan_result.csv"
    $recurseInput = Read-InputWithDefault -PromptText "Scan subdirectories recursively? (Y/N)" -DefaultValue "Y"
    $Recurse = -not ($recurseInput -eq "N" -or $recurseInput -eq "n")
}

$estimateOnlyEnabled = if ($EstimateOnly -is [System.Management.Automation.SwitchParameter]) { [bool]$EstimateOnly.IsPresent } else { [bool]$EstimateOnly }
$incrementalEnabled = if ($Incremental -is [System.Management.Automation.SwitchParameter]) { [bool]$Incremental.IsPresent } else { [bool]$Incremental }
$recurseEnabled = if ($Recurse -is [System.Management.Automation.SwitchParameter]) { [bool]$Recurse.IsPresent } else { [bool]$Recurse }
$maskSensitiveValuesEnabled = if ($MaskSensitiveValues -is [System.Management.Automation.SwitchParameter]) { [bool]$MaskSensitiveValues.IsPresent } else { [bool]$MaskSensitiveValues }

if ([string]::IsNullOrWhiteSpace($ConfigPath) -and -not $estimateOnlyEnabled) {
    throw "Config file path is required."
}

if (-not (Test-Path -LiteralPath $ScanPath)) {
    throw "Scan path not found: $ScanPath"
}

$resolvedScanPath = (Resolve-Path -LiteralPath $ScanPath).Path
$resolvedConfigPath = ""
if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    $resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
}
$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$resolvedSummaryPath = if ([string]::IsNullOrWhiteSpace($SummaryPath)) { [System.IO.Path]::ChangeExtension($resolvedOutputPath, ".summary.csv") } else { [System.IO.Path]::GetFullPath($SummaryPath) }
$resolvedHtmlReportPath = if ([string]::IsNullOrWhiteSpace($HtmlReportPath)) { [System.IO.Path]::ChangeExtension($resolvedOutputPath, ".report.html") } else { [System.IO.Path]::GetFullPath($HtmlReportPath) }
$resolvedStatePath = if ([string]::IsNullOrWhiteSpace($StatePath)) { [System.IO.Path]::ChangeExtension($resolvedOutputPath, ".state.json") } else { [System.IO.Path]::GetFullPath($StatePath) }
$outputDirectory = Split-Path -Path $resolvedOutputPath -Parent

if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$rules = @()
if (-not $estimateOnlyEnabled) {
    $rules = @(Get-LevelRules -ConfigFile $resolvedConfigPath)
}
$excludedPrefixes = @()
foreach ($pathValue in (Get-ExpandedExcludePaths -RawPaths $ExcludePaths)) {
    if (-not [string]::IsNullOrWhiteSpace($pathValue)) {
        $excludedPrefixes += Get-NormalizedPrefix -PathValue $pathValue
    }
}

$scanRootPrefix = Get-NormalizedPrefix -PathValue $resolvedScanPath
if (Test-IsExcludedPath -TargetPath $scanRootPrefix -ExcludedPrefixes $excludedPrefixes) {
    throw "Scan path is fully excluded: $resolvedScanPath"
}

$allowedContentExtensions = Get-ContentExtensionSet -Extensions $ContentExtensions
$maxContentBytes = [int64]$MaxContentFileSizeMB * 1MB
$stats = New-ScanStats
$previousState = if ($incrementalEnabled -and -not $estimateOnlyEnabled) { Read-ScanState -Path $resolvedStatePath } else { @{} }
$currentState = @{}

if ($estimateOnlyEnabled) {
    Write-Host "Estimate mode started. The scanner will enumerate files only and will not extract file content."

    $estimatedCount = 0
    foreach ($file in (Get-TargetFiles -RootPath $resolvedScanPath -Recursive $recurseEnabled -ExcludedPrefixes $excludedPrefixes)) {
        $estimatedCount++
        Add-FileToStats -Stats $stats -File $file -AllowedExtensions $allowedContentExtensions -MaxContentBytes $maxContentBytes

        if ($ProgressInterval -gt 0 -and ($estimatedCount % $ProgressInterval) -eq 0) {
            Write-Host "Progress: estimated $estimatedCount files."
            if ($PauseMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $PauseMilliseconds
            }
        }
    }

    Write-ScanSummary -Stats $stats -ReportPath $resolvedSummaryPath
    Write-HtmlReport -Stats $stats -ReportPath $resolvedHtmlReportPath -ResultPath $resolvedOutputPath -SummaryPath $resolvedSummaryPath -EstimateOnly $true -Incremental $false
    Show-ScanSummary -Stats $stats
    Write-Host "Estimate completed. Summary file: $resolvedSummaryPath"
    Write-Host "HTML report: $resolvedHtmlReportPath"
    return
}

$writer = New-Object System.IO.StreamWriter($resolvedOutputPath, $false, [System.Text.UTF8Encoding]::new($true))
try {
    $writer.WriteLine("Index,FilePath,FileName,FileSize,FileType,SensitiveLevel,MatchedKeywords,MatchScope,LineNumber,MatchedSnippet,ScanStatus,SkipReason,ExtractionMethod")

    $index = 1
    $scannedCount = 0
    $matchedCount = 0

    foreach ($file in (Get-TargetFiles -RootPath $resolvedScanPath -Recursive $recurseEnabled -ExcludedPrefixes $excludedPrefixes)) {
        $scannedCount++
        Add-FileToStats -Stats $stats -File $file -AllowedExtensions $allowedContentExtensions -MaxContentBytes $maxContentBytes
        $fileStateKey = Get-FileStateKey -File $file
        $currentState[$fileStateKey] = Get-FileStateRecord -File $file

        if ($incrementalEnabled) {
            $previousRecord = if ($previousState.ContainsKey($fileStateKey)) { $previousState[$fileStateKey] } else { $null }
            if (-not (Test-FileChangedSinceState -File $file -PreviousRecord $previousRecord)) {
                $stats.IncrementalSkippedFiles++
                continue
            }
            $stats.IncrementalChangedFiles++
        }

        if ($ProgressInterval -gt 0 -and ($scannedCount % $ProgressInterval) -eq 0) {
            Write-Host "Progress: scanned $scannedCount files, matched $matchedCount files."
            if ($PauseMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $PauseMilliseconds
            }
        }

        $nameMatch = Find-NameMatch -FileName $file.Name -Rules $rules
        $contentResult = Find-ContentMatch -File $file -Rules $rules -MaxContentBytes $maxContentBytes -AllowedExtensions $allowedContentExtensions -PdfToolPath $PdfToTextPath -LibreOfficeExecutable $LibreOfficePath -TimeoutSeconds $ExtractionTimeoutSeconds
        $finalMatch = Resolve-FinalMatch -NameMatch $nameMatch -ContentMatch $contentResult.Match
        $outputMatch = Convert-MatchForOutput -Match $finalMatch -MaskValues $maskSensitiveValuesEnabled

        switch ($contentResult.ScanStatus) {
            "Matched" { $stats.ContentMatchedFiles++ }
            "Skipped" { $stats.ContentSkippedFiles++ }
            "ExtractionFailed" { $stats.ContentExtractionFailedFiles++ }
            "ScannedNoMatch" { $stats.ContentScannedNoMatchFiles++ }
        }
        Add-Count -Map $stats.ScanStatusCounts -Key $contentResult.ScanStatus
        if (-not [string]::IsNullOrWhiteSpace([string]$contentResult.ExtractionMethod)) {
            Add-Count -Map $stats.ExtractionMethodCounts -Key $contentResult.ExtractionMethod
        }

        if ($null -eq $finalMatch) {
            if ($contentResult.ScanStatus -eq "Skipped" -or $contentResult.ScanStatus -eq "ExtractionFailed") {
                $writer.WriteLine((New-CsvLine -Values @(
                    $index,
                    $file.FullName,
                    $file.Name,
                    $file.Length,
                    (Get-FileType -File $file),
                    "",
                    "",
                    "",
                    "",
                    "",
                    $contentResult.ScanStatus,
                    $contentResult.SkipReason,
                    $contentResult.ExtractionMethod
                )))
                $index++
            }
            continue
        }

        $outputScanStatus = ""
        if ($null -ne $contentResult -and $contentResult.ScanStatus -eq "Matched") {
            $outputScanStatus = "Matched"
        }
        elseif ($null -ne $nameMatch) {
            $outputScanStatus = "Matched"
        }

        $writer.WriteLine((New-CsvLine -Values @(
            $index,
            $file.FullName,
            $file.Name,
            $file.Length,
            (Get-FileType -File $file),
            $outputMatch.Level,
            $outputMatch.Keyword,
            $outputMatch.MatchScope,
            $outputMatch.LineNumber,
            $outputMatch.MatchedSnippet,
            $outputScanStatus,
            "",
            $contentResult.ExtractionMethod
        )))

        $matchedCount++
        $stats.MatchedFiles++
        Add-Count -Map $stats.SensitiveLevelCounts -Key $finalMatch.Level
        Add-Count -Map $stats.MatchScopeCounts -Key $finalMatch.MatchScope
        if ($null -ne $nameMatch) {
            $stats.NameMatchedFiles++
        }
        $index++
    }

    Write-Host "Scan completed. Scanned $scannedCount files and found $matchedCount suspected sensitive files."
    Write-Host "Result file: $resolvedOutputPath"
    if ($incrementalEnabled) {
        foreach ($key in $previousState.Keys) {
            if (-not $currentState.ContainsKey($key)) {
                $stats.IncrementalDeletedFiles++
            }
        }
        Write-ScanState -CurrentState $currentState -Path $resolvedStatePath
        Write-Host "State file: $resolvedStatePath"
    }
    Write-ScanSummary -Stats $stats -ReportPath $resolvedSummaryPath
    Write-HtmlReport -Stats $stats -ReportPath $resolvedHtmlReportPath -ResultPath $resolvedOutputPath -SummaryPath $resolvedSummaryPath -EstimateOnly $false -Incremental $incrementalEnabled
    Show-ScanSummary -Stats $stats
    Write-Host "Summary file: $resolvedSummaryPath"
    Write-Host "HTML report: $resolvedHtmlReportPath"
}
finally {
    $writer.Dispose()
}
