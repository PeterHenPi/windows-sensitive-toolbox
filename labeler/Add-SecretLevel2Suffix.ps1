param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [string]$Suffix = "_$([char]0x5546)$([char]0x5BC6)$([char]0x4E8C)$([char]0x7EA7)",

    [string]$LogPath = ".\SecretLevel2Suffix-Failures.csv",

    [switch]$Preview
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[object]

function Convert-ToLongPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($Path.StartsWith("\\?\")) {
        return $Path
    }

    if ($Path.StartsWith("\\")) {
        return "\\?\UNC\" + $Path.Substring(2)
    }

    return "\\?\" + $Path
}

function Test-AnyPathExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $longPath = Convert-ToLongPath -Path $Path
    return ([System.IO.File]::Exists($longPath) -or [System.IO.Directory]::Exists($longPath))
}

function Rename-PathWithLongPathSupport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath,

        [Parameter(Mandatory = $true)]
        [bool]$IsDirectory
    )

    $longSourcePath = Convert-ToLongPath -Path $SourcePath
    $longTargetPath = Convert-ToLongPath -Path $TargetPath

    if ($IsDirectory) {
        [System.IO.Directory]::Move($longSourcePath, $longTargetPath)
    } else {
        [System.IO.File]::Move($longSourcePath, $longTargetPath)
    }
}

function Invoke-RenameItem {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo]$Item
    )

    $isDirectory = ($Item.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0
    if ($isDirectory) {
        if ($Item.Name.EndsWith($Suffix)) {
            Write-Host "Skip already labeled: $($Item.FullName)"
            return
        }

        $newName = "$($Item.Name)$Suffix"
        $parentPath = $Item.Parent.FullName
    } else {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Item.Name)
        $extension = [System.IO.Path]::GetExtension($Item.Name)

        if ($baseName.EndsWith($Suffix)) {
            Write-Host "Skip already labeled: $($Item.FullName)"
            return
        }

        $newName = "$baseName$Suffix$extension"
        $parentPath = $Item.Directory.FullName
    }

    $newPath = $parentPath.TrimEnd('\') + '\' + $newName

    if (Test-AnyPathExists -Path $newPath) {
        Write-Warning "Target already exists, skipped: $newPath"
        return
    }

    if ($Preview) {
        Write-Host "Preview rename: $($Item.FullName) -> $newPath"
        return
    }

    try {
        Rename-PathWithLongPathSupport -SourcePath $Item.FullName -TargetPath $newPath -IsDirectory $isDirectory
        Write-Host "Renamed: $($Item.FullName) -> $newPath"
    } catch {
        $failure = [PSCustomObject]@{
            SourcePath = $Item.FullName
            TargetPath = $newPath
            ItemType = $(if ($isDirectory) { "Directory" } else { "File" })
            ErrorMessage = $_.Exception.Message
        }
        $script:failures.Add($failure) | Out-Null
        Write-Warning "Rename failed, skipped: $($Item.FullName). Error: $($_.Exception.Message)"
    }
}

$resolvedRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RootPath)
$longRoot = Convert-ToLongPath -Path $resolvedRoot
if (-not [System.IO.Directory]::Exists($longRoot)) {
    throw "Root directory is missing or inaccessible: $resolvedRoot"
}
if ([string]::IsNullOrWhiteSpace($Suffix)) {
    throw "Suffix must not be empty."
}

Write-Host "RootPath: $resolvedRoot"
Write-Host "Suffix: $Suffix"
if ($Preview) {
    Write-Host "Mode: preview only, no files will be renamed"
} else {
    Write-Host "Mode: execute rename"
}
Write-Host ""

# Snapshot the tree with extended paths before any rename takes place.
$files = New-Object System.Collections.Generic.List[object]
$folders = New-Object System.Collections.Generic.List[object]
$pending = New-Object System.Collections.Generic.Stack[string]
$pending.Push($longRoot)
while ($pending.Count -gt 0) {
    $scanPath = $pending.Pop()
    try {
        $directory = New-Object System.IO.DirectoryInfo -ArgumentList $scanPath
        $entries = $directory.GetFileSystemInfos()
    } catch {
        $failures.Add([PSCustomObject]@{
            SourcePath = $scanPath
            TargetPath = ""
            ItemType = "ScanDirectory"
            ErrorMessage = $_.Exception.Message
        })
        Write-Warning "Cannot scan: $scanPath. Error: $($_.Exception.Message)"
        continue
    }
    foreach ($entry in $entries) {
        if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            $failures.Add([PSCustomObject]@{
                SourcePath = $entry.FullName
                TargetPath = ""
                ItemType = "ReparsePointSkipped"
                ErrorMessage = "Link or junction skipped; review separately."
            })
            continue
        }
        if (($entry.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
            $folders.Add($entry)
            $pending.Push($entry.FullName)
        } else {
            $files.Add($entry)
        }
    }
}

foreach ($file in $files) {
    Invoke-RenameItem -Item $file
}

foreach ($folder in ($folders | Sort-Object { $_.FullName.Length } -Descending)) {
    Invoke-RenameItem -Item $folder
}

Write-Host ""
if ($failures.Count -gt 0) {
    $resolvedLogPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
    $failures | Export-Csv -LiteralPath $resolvedLogPath -NoTypeInformation -Encoding UTF8
    Write-Warning "Some items failed. Failure count: $($failures.Count)"
    Write-Warning "Failure log: $resolvedLogPath"
}

Write-Host "Done."
