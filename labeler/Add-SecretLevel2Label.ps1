param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$RootPath,

    [string]$Prefix = "$([char]0x3010)$([char]0x5546)$([char]0x5BC6)$([char]0x4E8C)$([char]0x7EA7)$([char]0x3011)",

    [switch]$Preview
)

$ErrorActionPreference = "Stop"

$resolvedRoot = (Resolve-Path -LiteralPath $RootPath).Path

Write-Host "RootPath: $resolvedRoot"
Write-Host "Prefix: $Prefix"
if ($Preview) {
    Write-Host "Mode: preview only, no files will be renamed"
} else {
    Write-Host "Mode: execute rename"
}
Write-Host ""

# Do not rename the root directory itself.
# Rename deeper paths first so parent folder renames do not break child paths.
$items = Get-ChildItem -LiteralPath $resolvedRoot -Recurse -Force |
    Sort-Object { $_.FullName.Length } -Descending

foreach ($item in $items) {
    if ($item.Name.StartsWith($Prefix)) {
        Write-Host "Skip already labeled: $($item.FullName)"
        continue
    }

    $newName = "$Prefix$($item.Name)"
    if ($item.PSIsContainer) {
        $parentPath = $item.Parent.FullName
    } else {
        $parentPath = $item.Directory.FullName
    }
    $newPath = Join-Path -Path $parentPath -ChildPath $newName

    if (Test-Path -LiteralPath $newPath) {
        Write-Warning "Target already exists, skipped: $newPath"
        continue
    }

    if ($Preview) {
        Write-Host "Preview rename: $($item.FullName) -> $newPath"
        continue
    }

    Rename-Item -LiteralPath $item.FullName -NewName $newName
    Write-Host "Renamed: $($item.FullName) -> $newPath"
}

Write-Host ""
Write-Host "Done."
