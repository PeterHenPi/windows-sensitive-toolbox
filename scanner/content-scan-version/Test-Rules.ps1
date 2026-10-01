[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\keywords.sample.csv",

    [Parameter(Mandatory = $false)]
    [string]$Text = "",

    [Parameter(Mandatory = $false)]
    [string]$Scope = "content",

    [Parameter(Mandatory = $false)]
    [switch]$ShowAll
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function Test-IsRuleEnabled {
    param([Parameter(Mandatory = $false)][object]$EnabledValue)

    if ($null -eq $EnabledValue) { return $true }
    $text = [string]$EnabledValue
    if ([string]::IsNullOrWhiteSpace($text)) { return $true }

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
    param([Parameter(Mandatory = $false)][string]$ScopeText)

    if ([string]::IsNullOrWhiteSpace($ScopeText)) { return "name" }
    $scopeValue = $ScopeText.Trim().ToLowerInvariant()
    if ($scopeValue -notin @("name", "content", "both")) {
        throw "Invalid config format: matchScope must be name, content, or both."
    }
    return $scopeValue
}

function Get-RuleMode {
    param([Parameter(Mandatory = $false)][string]$ModeText)

    if ([string]::IsNullOrWhiteSpace($ModeText)) { return "contains" }
    $mode = $ModeText.Trim().ToLowerInvariant()
    if ($mode -notin @("contains", "regex")) {
        throw "Invalid config format: matchMode must be contains or regex."
    }
    return $mode
}

function Get-PiiType {
    param([Parameter(Mandatory = $false)][string]$PiiTypeText)

    if ([string]::IsNullOrWhiteSpace($PiiTypeText)) { return "" }
    $piiType = $PiiTypeText.Trim().ToLowerInvariant()
    if ($piiType -notin @("cn_mobile", "cn_id_card", "email", "bank_card", "passport", "cn_name_mobile_combo", "cn_name_id_combo", "cn_name_mobile_id_combo")) {
        throw "Invalid config format: unsupported piiType: $piiType"
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
    param([Parameter(Mandatory = $true)][string]$ConfigFile)

    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        throw "Config file not found: $ConfigFile"
    }

    $rows = Import-Csv -LiteralPath $ConfigFile -Encoding UTF8
    if ($null -eq $rows -or @($rows).Count -eq 0) {
        throw "Invalid config format: CSV file is empty."
    }

    $rules = New-Object System.Collections.Generic.List[object]
    foreach ($row in $rows) {
        if ($row.PSObject.Properties.Match("enabled").Count -gt 0 -and -not (Test-IsRuleEnabled -EnabledValue $row.enabled)) {
            continue
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
                Level = $level.Trim()
                Priority = $priority
                MatchScope = $matchScope
                MatchMode = $matchMode
                Keyword = $keyword
                PiiType = $piiType
                Category = $category
                Notes = $notes
            })
        }

        if (-not [string]::IsNullOrWhiteSpace($piiType) -and $keywords.Count -eq 0) {
            $rules.Add([PSCustomObject]@{
                Level = $level.Trim()
                Priority = $priority
                MatchScope = $matchScope
                MatchMode = $matchMode
                Keyword = ""
                PiiType = $piiType
                Category = $category
                Notes = $notes
            })
        }
    }

    return @($rules | Sort-Object -Property @{ Expression = "Priority"; Descending = $true }, "Level", "Keyword")
}

function Test-RuleMatch {
    param(
        [Parameter(Mandatory = $true)][string]$InputText,
        [Parameter(Mandatory = $true)][object]$Rule
    )

    if ($Rule.MatchMode -eq "regex") {
        return $InputText -imatch $Rule.Keyword
    }

    return $InputText.IndexOf($Rule.Keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Test-Luhn {
    param([Parameter(Mandatory = $true)][string]$NumberText)

    $digits = ($NumberText -replace '\D', '')
    if ($digits.Length -lt 12 -or $digits.Length -gt 19) { return $false }

    $sum = 0
    $alternate = $false
    for ($i = $digits.Length - 1; $i -ge 0; $i--) {
        $digit = [int][string]$digits[$i]
        if ($alternate) {
            $digit *= 2
            if ($digit -gt 9) { $digit -= 9 }
        }
        $sum += $digit
        $alternate = -not $alternate
    }
    return ($sum % 10) -eq 0
}

function Test-ChinaIdCard {
    param([Parameter(Mandatory = $true)][string]$IdText)

    $value = $IdText.Trim().ToUpperInvariant()
    if ($value -notmatch '^\d{17}[\dX]$') { return $false }

    $weights = @(7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2)
    $checkMap = @('1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2')
    $sum = 0
    for ($i = 0; $i -lt 17; $i++) {
        $sum += ([int][string]$value[$i]) * $weights[$i]
    }

    return $checkMap[$sum % 11] -eq [string]$value[17]
}

function Get-ChineseNameCandidates {
    param([Parameter(Mandatory = $true)][string]$InputText)

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($InputText, '(?:姓名|联系人|客户|用户|员工|收件人|申请人|持卡人)\s*[:：]?\s*([\u4e00-\u9fa5]{2,4})')) {
        if ($match.Groups.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace($match.Groups[1].Value)) {
            $candidates.Add($match.Groups[1].Value)
        }
    }
    foreach ($match in [regex]::Matches($InputText, '(?<![\u4e00-\u9fa5])[\u4e00-\u9fa5]{2,4}(?![\u4e00-\u9fa5])')) {
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
        [Parameter(Mandatory = $true)][string]$InputText,
        [Parameter(Mandatory = $true)][string]$PiiType
    )

    switch ($PiiType) {
        "cn_mobile" { return @([regex]::Matches($InputText, '(?<!\d)(?:\+?86[- ]?)?1[3-9]\d{9}(?!\d)') | ForEach-Object { $_.Value }) }
        "cn_id_card" { return @([regex]::Matches($InputText, '(?<!\d)\d{17}[\dXx](?!\d)') | ForEach-Object { $_.Value } | Where-Object { Test-ChinaIdCard -IdText $_ }) }
        "email" { return @([regex]::Matches($InputText, '\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) | ForEach-Object { $_.Value }) }
        "bank_card" { return @([regex]::Matches($InputText, '(?<!\d)\d{12,19}(?!\d)') | ForEach-Object { $_.Value } | Where-Object { Test-Luhn -NumberText $_ }) }
        "passport" { return @([regex]::Matches($InputText, '\b(?:[EG]\d{8}|P\d{7}|[A-Z]\d{8,9})\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) | ForEach-Object { $_.Value }) }
        "cn_name_mobile_combo" {
            $names = @(Get-ChineseNameCandidates -InputText $InputText)
            $mobiles = @(Get-PiiCandidates -InputText $InputText -PiiType "cn_mobile")
            if ($names.Count -gt 0 -and $mobiles.Count -gt 0) { return @("{0}|{1}" -f $names[0], $mobiles[0]) }
            return @()
        }
        "cn_name_id_combo" {
            $names = @(Get-ChineseNameCandidates -InputText $InputText)
            $ids = @(Get-PiiCandidates -InputText $InputText -PiiType "cn_id_card")
            if ($names.Count -gt 0 -and $ids.Count -gt 0) { return @("{0}|{1}" -f $names[0], $ids[0]) }
            return @()
        }
        "cn_name_mobile_id_combo" {
            $names = @(Get-ChineseNameCandidates -InputText $InputText)
            $mobiles = @(Get-PiiCandidates -InputText $InputText -PiiType "cn_mobile")
            $ids = @(Get-PiiCandidates -InputText $InputText -PiiType "cn_id_card")
            if ($names.Count -gt 0 -and $mobiles.Count -gt 0 -and $ids.Count -gt 0) { return @("{0}|{1}|{2}" -f $names[0], $mobiles[0], $ids[0]) }
            return @()
        }
        default { return @() }
    }
}

function Test-DebugRules {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rules,
        [Parameter(Mandatory = $true)][string]$InputText,
        [Parameter(Mandatory = $true)][string]$ScopeValue,
        [Parameter(Mandatory = $true)][bool]$IncludeNonMatches
    )

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($rule in $Rules) {
        if ($rule.MatchScope -ne $ScopeValue -and $rule.MatchScope -ne "both") {
            if ($IncludeNonMatches) {
                $results.Add([PSCustomObject]@{ Matched = $false; Reason = "scope_not_applicable"; Level = $rule.Level; Priority = $rule.Priority; MatchScope = $rule.MatchScope; MatchMode = $rule.MatchMode; PiiType = $rule.PiiType; Keyword = $rule.Keyword; MatchedValue = ""; Category = $rule.Category; Notes = $rule.Notes })
            }
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$rule.PiiType)) {
            $candidates = @(Get-PiiCandidates -InputText $InputText -PiiType $rule.PiiType)
            $matched = $candidates.Count -gt 0
            if ($matched -or $IncludeNonMatches) {
                $reason = if ($matched) { "pii_match" } else { "pii_no_match" }
                $matchedValue = if ($matched) { ($candidates -join "|") } else { "" }
                $results.Add([PSCustomObject]@{ Matched = $matched; Reason = $reason; Level = $rule.Level; Priority = $rule.Priority; MatchScope = $rule.MatchScope; MatchMode = $rule.MatchMode; PiiType = $rule.PiiType; Keyword = $rule.Keyword; MatchedValue = $matchedValue; Category = $rule.Category; Notes = $rule.Notes })
            }
            continue
        }

        $keywordMatched = Test-RuleMatch -InputText $InputText -Rule $rule
        if ($keywordMatched -or $IncludeNonMatches) {
            $reason = if ($keywordMatched) { "keyword_match" } else { "keyword_no_match" }
            $matchedValue = if ($keywordMatched) { $rule.Keyword } else { "" }
            $results.Add([PSCustomObject]@{ Matched = $keywordMatched; Reason = $reason; Level = $rule.Level; Priority = $rule.Priority; MatchScope = $rule.MatchScope; MatchMode = $rule.MatchMode; PiiType = $rule.PiiType; Keyword = $rule.Keyword; MatchedValue = $matchedValue; Category = $rule.Category; Notes = $rule.Notes })
        }
    }

    return $results.ToArray()
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = ".\keywords.sample.csv"
}

if ([string]::IsNullOrWhiteSpace($Text)) {
    Write-Host "Rule debug interactive mode started."
    $ConfigPath = Read-InputWithDefault -PromptText "Enter rule file path (.csv)" -DefaultValue $ConfigPath
    $Text = Read-InputWithDefault -PromptText "Enter text to test" -DefaultValue "姓名: 张三 手机: 13800138000 身份证号: 11010519491231002X"
    $Scope = Read-InputWithDefault -PromptText "Enter scope (name/content)" -DefaultValue $Scope
}

$scopeValue = $Scope.Trim().ToLowerInvariant()
if ($scopeValue -notin @("name", "content")) {
    throw "Scope must be name or content."
}

$rules = @(Get-LevelRules -ConfigFile (Resolve-Path -LiteralPath $ConfigPath).Path)
$includeNonMatches = if ($ShowAll -is [System.Management.Automation.SwitchParameter]) { [bool]$ShowAll.IsPresent } else { [bool]$ShowAll }
$results = @(Test-DebugRules -Rules $rules -InputText $Text -ScopeValue $scopeValue -IncludeNonMatches $includeNonMatches)
$matchedResults = @($results | Where-Object { $_.Matched })

Write-Host "Rules loaded: $($rules.Count)"
Write-Host "Matched rules: $($matchedResults.Count)"
Write-Host ""

if ($results.Count -eq 0) {
    Write-Host "No rules matched."
    exit 0
}

$results |
    Sort-Object -Property @{ Expression = "Matched"; Descending = $true }, @{ Expression = "Priority"; Descending = $true }, "Level", "Keyword" |
    Format-Table -AutoSize Matched, Reason, Level, Priority, MatchScope, MatchMode, PiiType, Keyword, MatchedValue, Category
