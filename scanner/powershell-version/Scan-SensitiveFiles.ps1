[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ScanPath,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\sensitive_scan_result.csv",

    [Parameter(Mandatory = $false)]
    [switch]$Recurse = $true,

    [Parameter(Mandatory = $false)]
    [string[]]$ExcludePaths = @(),

    [Parameter(Mandatory = $false)]
    [int]$ProgressInterval = 5000,

    [Parameter(Mandatory = $false)]
    [int]$PauseMilliseconds = 0
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

function Test-JsonArray {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    return $Value -is [System.Array] -or $Value -is [System.Collections.IEnumerable]
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

function Get-LevelRules {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigFile
    )

    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        throw "Config file not found: $ConfigFile"
    }

    $extension = [System.IO.Path]::GetExtension($ConfigFile).ToLowerInvariant()
    switch ($extension) {
        ".json" {
            $rawConfig = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json

            if (-not (Test-JsonArray -Value $rawConfig)) {
                throw "Invalid config format: JSON root must be an array."
            }

            $rules = foreach ($item in $rawConfig) {
                if ([string]::IsNullOrWhiteSpace($item.level)) {
                    throw "Invalid config format: each rule must contain a level."
                }

                if (-not (Test-JsonArray -Value $item.keywords)) {
                    throw "Invalid config format: keywords for level [$($item.level)] must be an array."
                }

                $keywords = @(
                    $item.keywords |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        ForEach-Object { $_.Trim() } |
                        Select-Object -Unique
                )

                if ($keywords.Count -eq 0) {
                    throw "Invalid config format: level [$($item.level)] must contain at least one keyword."
                }

                [PSCustomObject]@{
                    Level    = [string]$item.level
                    Priority = if ($null -ne $item.priority) { [int]$item.priority } else { 0 }
                    MatchMode = if ($null -ne $item.matchMode -and -not [string]::IsNullOrWhiteSpace([string]$item.matchMode)) { ([string]$item.matchMode).Trim().ToLowerInvariant() } else { "contains" }
                    Keywords = $keywords
                }
            }
        }
        ".csv" {
            $rows = Import-Csv -LiteralPath $ConfigFile -Encoding UTF8
            if ($null -eq $rows -or @($rows).Count -eq 0) {
                throw "Invalid config format: CSV file is empty."
            }

            $grouped = @{}

            foreach ($row in $rows) {
                if ($row.PSObject.Properties.Match("enabled").Count -gt 0) {
                    if (-not (Test-IsRuleEnabled -EnabledValue $row.enabled)) {
                        continue
                    }
                }

                $level = ""
                if ($row.PSObject.Properties.Match("level").Count -gt 0) {
                    $level = [string]$row.level
                }

                if ([string]::IsNullOrWhiteSpace($level)) {
                    throw "Invalid config format: CSV must contain a non-empty level column."
                }

                $priority = 0
                if ($row.PSObject.Properties.Match("priority").Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$row.priority)) {
                    $priority = [int]$row.priority
                }

                $matchMode = "contains"
                if ($row.PSObject.Properties.Match("matchMode").Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$row.matchMode)) {
                    $matchMode = ([string]$row.matchMode).Trim().ToLowerInvariant()
                }

                if ($matchMode -ne "contains" -and $matchMode -ne "regex") {
                    throw "Invalid config format: matchMode for level [$level] must be contains or regex."
                }

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

                if ($keywords.Count -eq 0) {
                    continue
                }

                if (-not $grouped.ContainsKey($level)) {
                    $grouped[$level] = [PSCustomObject]@{
                        Level    = $level
                        Priority = $priority
                        MatchMode = $matchMode
                        Keywords = New-Object System.Collections.Generic.List[string]
                    }
                }

                if ($priority -gt $grouped[$level].Priority) {
                    $grouped[$level].Priority = $priority
                }

                if ($matchMode -eq "regex") {
                    $grouped[$level].MatchMode = "regex"
                }

                foreach ($keyword in ($keywords | Select-Object -Unique)) {
                    if (-not $grouped[$level].Keywords.Contains($keyword)) {
                        $grouped[$level].Keywords.Add($keyword)
                    }
                }
            }

            $rules = $grouped.Values
        }
        default {
            throw "Unsupported config format: $extension. Only .json and .csv are supported."
        }
    }

    return $rules | Sort-Object -Property @(
        @{ Expression = "Priority"; Descending = $true },
        @{ Expression = "Level"; Descending = $false }
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

function Find-SensitiveMatch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [object[]]$Rules
    )

    foreach ($rule in $Rules) {
        $matchedKeywords = New-Object System.Collections.Generic.List[string]

        foreach ($keyword in $rule.Keywords) {
            if ($rule.MatchMode -eq "regex") {
                if ($FileName -imatch $keyword) {
                    $matchedKeywords.Add($keyword)
                }
            }
            else {
                if ($FileName.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $matchedKeywords.Add($keyword)
                }
            }
        }

        if ($matchedKeywords.Count -gt 0) {
            return [PSCustomObject]@{
                Level    = $rule.Level
                Keywords = ($matchedKeywords | Select-Object -Unique)
            }
        }
    }

    return $null
}

function Escape-CsvValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

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

if ([string]::IsNullOrWhiteSpace($ScanPath)) {
    Write-Host "No parameters detected. Interactive mode started."
    $defaultConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "keywords.sample.csv"
    $defaultOutputPath = Join-Path -Path $PSScriptRoot -ChildPath "result\sensitive_scan_result.csv"
    $ScanPath = Read-InputWithDefault -PromptText "Enter scan directory" -DefaultValue "D:\Data"
    $ConfigPath = Read-InputWithDefault -PromptText "Enter rule file path (.csv or .json)" -DefaultValue $defaultConfigPath
    $OutputPath = Read-InputWithDefault -PromptText "Enter output CSV path" -DefaultValue $defaultOutputPath
    $recurseInput = Read-InputWithDefault -PromptText "Scan subdirectories recursively? (Y/N)" -DefaultValue "Y"
    $Recurse = -not ($recurseInput -eq "N" -or $recurseInput -eq "n")
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    throw "Config file path is required."
}

if (-not (Test-Path -LiteralPath $ScanPath)) {
    throw "Scan path not found: $ScanPath"
}

$resolvedScanPath = (Resolve-Path -LiteralPath $ScanPath).Path
$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)

$outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$rules = @(Get-LevelRules -ConfigFile $resolvedConfigPath)
$excludedPrefixes = @()
foreach ($pathValue in (Get-ExpandedExcludePaths -RawPaths $ExcludePaths)) {
    if ([string]::IsNullOrWhiteSpace($pathValue)) {
        continue
    }
    $excludedPrefixes += Get-NormalizedPrefix -PathValue $pathValue
}

$scanRootPrefix = Get-NormalizedPrefix -PathValue $resolvedScanPath
if (Test-IsExcludedPath -TargetPath $scanRootPrefix -ExcludedPrefixes $excludedPrefixes) {
    throw "Scan path is fully excluded: $resolvedScanPath"
}

$writer = New-Object System.IO.StreamWriter($resolvedOutputPath, $false, [System.Text.UTF8Encoding]::new($true))
try {
    $writer.WriteLine("Index,FilePath,FileName,FileSize,FileType,SensitiveLevel,MatchedKeywords")

    $index = 1
    $scannedCount = 0
    $matchedCount = 0

    foreach ($file in (Get-TargetFiles -RootPath $resolvedScanPath -Recursive ([bool]$Recurse.IsPresent) -ExcludedPrefixes $excludedPrefixes)) {
        $scannedCount++

        if ($ProgressInterval -gt 0 -and ($scannedCount % $ProgressInterval) -eq 0) {
            Write-Host "Progress: scanned $scannedCount files, matched $matchedCount files."
            if ($PauseMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $PauseMilliseconds
            }
        }

        $match = Find-SensitiveMatch -FileName $file.Name -Rules $rules
        if ($null -eq $match) {
            continue
        }

        $writer.WriteLine((New-CsvLine -Values @(
            $index,
            $file.FullName,
            $file.Name,
            $file.Length,
            (Get-FileType -File $file),
            $match.Level,
            ($match.Keywords -join "|")
        )))

        $matchedCount++
        $index++
    }

    Write-Host "Scan completed. Scanned $scannedCount files and found $matchedCount suspected sensitive files."
    Write-Host "Result file: $resolvedOutputPath"
}
finally {
    $writer.Dispose()
}
