param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
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

    if ($Item.PSIsContainer) {
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

    $newPath = Join-Path -Path $parentPath -ChildPath $newName

    if (Test-AnyPathExists -Path $newPath) {
        Write-Warning "Target already exists, skipped: $newPath"
        return
    }

    if ($Preview) {
        Write-Host "Preview rename: $($Item.FullName) -> $newPath"
        return
    }

    try {
        Rename-PathWithLongPathSupport -SourcePath $Item.FullName -TargetPath $newPath -IsDirectory ([bool]$Item.PSIsContainer)
        Write-Host "Renamed: $($Item.FullName) -> $newPath"
    } catch {
        $failure = [PSCustomObject]@{
            SourcePath = $Item.FullName
            TargetPath = $newPath
            ItemType = $(if ($Item.PSIsContainer) { "Directory" } else { "File" })
            ErrorMessage = $_.Exception.Message
        }
        $script:failures.Add($failure) | Out-Null
        Write-Warning "Rename failed, skipped: $($Item.FullName). Error: $($_.Exception.Message)"
    }
}

$resolvedRoot = (Resolve-Path -LiteralPath $RootPath).Path

Write-Host "RootPath: $resolvedRoot"
Write-Host "Suffix: $Suffix"
if ($Preview) {
    Write-Host "Mode: preview only, no files will be renamed"
} else {
    Write-Host "Mode: execute rename"
}
Write-Host ""

# Do not rename the root directory itself.
# Rename files first, then folders, so folder renames never invalidate file paths.
$files = Get-ChildItem -LiteralPath $resolvedRoot -Recurse -Force |
    Where-Object { -not $_.PSIsContainer } |
    Sort-Object { $_.FullName.Length } -Descending

foreach ($file in $files) {
    Invoke-RenameItem -Item $file
}

$folders = Get-ChildItem -LiteralPath $resolvedRoot -Recurse -Force |
    Where-Object { $_.PSIsContainer } |
    Sort-Object { $_.FullName.Length } -Descending

foreach ($folder in $folders) {
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
