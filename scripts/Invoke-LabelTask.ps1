[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Preview", "Apply", "Rollback")]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    [Parameter(Mandatory = $true)]
    [string]$TaskDir,

    [string]$RootPath = "",

    [string]$RecurseValue = "true",

    [string]$IncludeFilesValue = "true",

    [string]$IncludeFoldersValue = "false",

    [ValidateSet("Suffix", "Prefix")]
    [string]$LabelStyle = "Suffix",

    [string]$LabelText = "商密二级",

    [string]$PreviewCsv = "",

    [string]$RollbackCsv = "",

    [string]$SelectedIdsJson = "[]"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$StatusPath = Join-Path $TaskDir "status.json"
$PreviewOutputPath = Join-Path $TaskDir "label-preview.csv"
$ApplyOutputPath = Join-Path $TaskDir "label-apply-result.csv"
$RollbackPath = Join-Path $TaskDir "rollback-map.csv"
$RollbackResultPath = Join-Path $TaskDir "rollback-result.csv"
$LogPath = Join-Path $TaskDir "label.log"

function Write-TaskStatus {
    param(
        [string]$State,
        [string]$Message,
        [hashtable]$Extra = @{}
    )

    $payload = [ordered]@{
        ok = $true
        id = $TaskId
        type = if ($Mode -eq "Preview") { "label-preview" } elseif ($Mode -eq "Rollback") { "label-rollback" } else { "label-apply" }
        state = $State
        message = $Message
        updatedAt = (Get-Date).ToString("s")
        taskDir = $TaskDir
        previewPath = $PreviewOutputPath
        resultPath = $ApplyOutputPath
        rollbackPath = $RollbackPath
        rollbackResultPath = $RollbackResultPath
        logPath = $LogPath
    }

    foreach ($key in $Extra.Keys) {
        $payload[$key] = $Extra[$key]
    }

    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StatusPath -Encoding UTF8
}

function Convert-ToLongPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.Environment]::OSVersion.Platform -ne "Win32NT") {
        return $Path
    }

    if ($Path.StartsWith("\\?\")) {
        return $Path
    }

    if ($Path.StartsWith("\\")) {
        return "\\?\UNC\" + $Path.Substring(2)
    }

    return "\\?\" + $Path
}

function Test-AnyPathExists {
    param([Parameter(Mandatory = $true)][string]$Path)
    $longPath = Convert-ToLongPath -Path $Path
    return ([System.IO.File]::Exists($longPath) -or [System.IO.Directory]::Exists($longPath))
}

function Move-PathLong {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][bool]$IsDirectory
    )

    $source = Convert-ToLongPath -Path $SourcePath
    $target = Convert-ToLongPath -Path $TargetPath
    if ($IsDirectory) {
        [System.IO.Directory]::Move($source, $target)
    }
    else {
        [System.IO.File]::Move($source, $target)
    }
}

function Test-HasLabel {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $prefix = "【$Text】"
    $suffix = "_$Text"

    if ($Item.PSIsContainer) {
        return ($Item.Name.StartsWith($prefix) -or $Item.Name.EndsWith($suffix))
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Item.Name)
    return ($Item.Name.StartsWith($prefix) -or $baseName.EndsWith($suffix))
}

function Get-TargetName {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item,
        [Parameter(Mandatory = $true)][string]$Style,
        [Parameter(Mandatory = $true)][string]$Text
    )

    if ($Style -eq "Prefix") {
        return "【$Text】$($Item.Name)"
    }

    $suffix = "_$Text"
    if ($Item.PSIsContainer) {
        return "$($Item.Name)$suffix"
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Item.Name)
    $extension = [System.IO.Path]::GetExtension($Item.Name)
    return "$baseName$suffix$extension"
}

function Get-ParentPath {
    param([Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item)
    if ($Item.PSIsContainer) {
        return $Item.Parent.FullName
    }
    return $Item.Directory.FullName
}

function Get-ItemsForPreview {
    param(
        [string]$Path,
        [bool]$Recursive,
        [bool]$IncludeFiles,
        [bool]$IncludeFolders
    )

    if ($Recursive) {
        $items = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue)
    }
    else {
        $items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    }

    $filtered = foreach ($item in $items) {
        if ($item.PSIsContainer -and $IncludeFolders) { $item; continue }
        if ((-not $item.PSIsContainer) -and $IncludeFiles) { $item; continue }
    }

    return @($filtered | Sort-Object { $_.FullName.Length } -Descending)
}

function Get-SelectedIdSet {
    param([string]$Json)
    $set = @{}
    if ([string]::IsNullOrWhiteSpace($Json)) {
        return $set
    }
    $values = $Json | ConvertFrom-Json
    foreach ($value in @($values)) {
        $key = [string]$value
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            $set[$key] = $true
        }
    }
    return $set
}

try {
    if (-not (Test-Path -LiteralPath $TaskDir)) {
        New-Item -ItemType Directory -Path $TaskDir -Force | Out-Null
    }

    if ($Mode -eq "Preview") {
        if ([string]::IsNullOrWhiteSpace($LabelText)) {
            throw "标签内容不能为空。"
        }

        $resolvedRoot = (Resolve-Path -LiteralPath $RootPath).Path
        $recurse = [System.Convert]::ToBoolean($RecurseValue)
        $includeFiles = [System.Convert]::ToBoolean($IncludeFilesValue)
        $includeFolders = [System.Convert]::ToBoolean($IncludeFoldersValue)

        if (-not $includeFiles -and -not $includeFolders) {
            throw "请至少选择文件或文件夹中的一种。"
        }

        Write-TaskStatus -State "running" -Message "正在生成加标签预览..." -Extra @{
            rootPath = $resolvedRoot
            labelText = $LabelText
            labelStyle = $LabelStyle
            totalCount = 0
            processableCount = 0
        }

        $items = @(Get-ItemsForPreview -Path $resolvedRoot -Recursive $recurse -IncludeFiles $includeFiles -IncludeFolders $includeFolders)
        $rows = New-Object System.Collections.Generic.List[object]
        $index = 1
        foreach ($item in $items) {
            $newName = Get-TargetName -Item $item -Style $LabelStyle -Text $LabelText
            $parent = Get-ParentPath -Item $item
            $target = Join-Path -Path $parent -ChildPath $newName
            $status = "可处理"
            if (Test-HasLabel -Item $item -Text $LabelText) {
                $status = "已含标签"
            }
            elseif (Test-AnyPathExists -Path $target) {
                $status = "目标已存在"
            }

            $rows.Add([PSCustomObject]@{
                Id = [string]$index
                Selected = if ($status -eq "可处理") { "1" } else { "0" }
                Status = $status
                ItemType = if ($item.PSIsContainer) { "Folder" } else { "File" }
                SourcePath = $item.FullName
                TargetPath = $target
                SourceName = $item.Name
                TargetName = $newName
            }) | Out-Null
            $index++
        }

        $rows | Export-Csv -LiteralPath $PreviewOutputPath -NoTypeInformation -Encoding UTF8
        $samples = @($rows | Select-Object -First 80 Id, Selected, Status, ItemType, SourceName, TargetName, SourcePath)
        $processable = @($rows | Where-Object { $_.Status -eq "可处理" }).Count
        $skipped = $rows.Count - $processable

        Write-TaskStatus -State "completed" -Message "预览已生成。" -Extra @{
            rootPath = $resolvedRoot
            labelText = $LabelText
            labelStyle = $LabelStyle
            totalCount = $rows.Count
            processableCount = $processable
            skippedCount = $skipped
            samples = $samples
        }
        return
    }

    if ($Mode -eq "Rollback") {
        if ([string]::IsNullOrWhiteSpace($RollbackCsv) -or -not (Test-Path -LiteralPath $RollbackCsv -PathType Leaf)) {
            throw "找不到回滚记录。"
        }

        Write-TaskStatus -State "running" -Message "正在回滚本次加标签..." -Extra @{
            totalCount = 0
            successCount = 0
            skippedCount = 0
            failedCount = 0
            sourceRollbackPath = $RollbackCsv
        }

        $rollbackRows = @(Import-Csv -LiteralPath $RollbackCsv -Encoding UTF8 |
            Sort-Object { ([string]$_.NewPath).Length } -Descending)

        $resultRows = New-Object System.Collections.Generic.List[object]
        $success = 0
        $skipped = 0
        $failed = 0

        foreach ($row in $rollbackRows) {
            $newPath = [string]$row.NewPath
            $originalPath = [string]$row.OriginalPath
            $isDirectory = ([string]$row.ItemType) -eq "Folder"

            if ([string]::IsNullOrWhiteSpace($newPath) -or [string]::IsNullOrWhiteSpace($originalPath)) {
                $skipped++
                $resultRows.Add([PSCustomObject]@{
                    Status = "跳过"
                    CurrentPath = $newPath
                    RestorePath = $originalPath
                    Message = "回滚记录缺少路径"
                }) | Out-Null
                continue
            }

            if (-not (Test-AnyPathExists -Path $newPath)) {
                $skipped++
                $resultRows.Add([PSCustomObject]@{
                    Status = "跳过"
                    CurrentPath = $newPath
                    RestorePath = $originalPath
                    Message = "当前路径不存在，可能已经回滚或被移动"
                }) | Out-Null
                continue
            }

            if (Test-AnyPathExists -Path $originalPath) {
                $skipped++
                $resultRows.Add([PSCustomObject]@{
                    Status = "跳过"
                    CurrentPath = $newPath
                    RestorePath = $originalPath
                    Message = "原路径已存在，为避免覆盖已跳过"
                }) | Out-Null
                continue
            }

            try {
                Move-PathLong -SourcePath $newPath -TargetPath $originalPath -IsDirectory $isDirectory
                $success++
                $resultRows.Add([PSCustomObject]@{
                    Status = "成功"
                    CurrentPath = $newPath
                    RestorePath = $originalPath
                    Message = ""
                }) | Out-Null
            }
            catch {
                $failed++
                $resultRows.Add([PSCustomObject]@{
                    Status = "失败"
                    CurrentPath = $newPath
                    RestorePath = $originalPath
                    Message = $_.Exception.Message
                }) | Out-Null
            }
        }

        $resultRows | Export-Csv -LiteralPath $RollbackResultPath -NoTypeInformation -Encoding UTF8
        $samples = @($resultRows | Select-Object -First 80 Status, CurrentPath, RestorePath, Message)

        Write-TaskStatus -State "completed" -Message "回滚执行完成。" -Extra @{
            totalCount = $rollbackRows.Count
            successCount = $success
            skippedCount = $skipped
            failedCount = $failed
            sourceRollbackPath = $RollbackCsv
            samples = $samples
        }
        return
    }

    Write-TaskStatus -State "running" -Message "正在执行加标签..." -Extra @{
        totalCount = 0
        successCount = 0
        skippedCount = 0
        failedCount = 0
    }

    $selectedSet = Get-SelectedIdSet -Json $SelectedIdsJson
    $previewRows = @(Import-Csv -LiteralPath $PreviewCsv -Encoding UTF8)
    if ($selectedSet.Count -gt 0) {
        $previewRows = @($previewRows | Where-Object { $selectedSet.ContainsKey([string]$_.Id) })
    }

    $resultRows = New-Object System.Collections.Generic.List[object]
    $rollbackRows = New-Object System.Collections.Generic.List[object]
    $success = 0
    $skipped = 0
    $failed = 0

    foreach ($row in $previewRows) {
        if ($row.Status -ne "可处理") {
            $skipped++
            $resultRows.Add([PSCustomObject]@{
                Id = $row.Id
                Status = "跳过"
                SourcePath = $row.SourcePath
                TargetPath = $row.TargetPath
                Message = $row.Status
            }) | Out-Null
            continue
        }

        if (-not (Test-Path -LiteralPath $row.SourcePath)) {
            $failed++
            $resultRows.Add([PSCustomObject]@{
                Id = $row.Id
                Status = "失败"
                SourcePath = $row.SourcePath
                TargetPath = $row.TargetPath
                Message = "源文件不存在"
            }) | Out-Null
            continue
        }

        if (Test-AnyPathExists -Path $row.TargetPath) {
            $skipped++
            $resultRows.Add([PSCustomObject]@{
                Id = $row.Id
                Status = "跳过"
                SourcePath = $row.SourcePath
                TargetPath = $row.TargetPath
                Message = "目标已存在"
            }) | Out-Null
            continue
        }

        try {
            Move-PathLong -SourcePath $row.SourcePath -TargetPath $row.TargetPath -IsDirectory ($row.ItemType -eq "Folder")
            $success++
            $resultRows.Add([PSCustomObject]@{
                Id = $row.Id
                Status = "成功"
                SourcePath = $row.SourcePath
                TargetPath = $row.TargetPath
                Message = ""
            }) | Out-Null
            $rollbackRows.Add([PSCustomObject]@{
                TaskId = $TaskId
                OriginalPath = $row.SourcePath
                NewPath = $row.TargetPath
                ExecutedAt = (Get-Date).ToString("s")
                ItemType = $row.ItemType
            }) | Out-Null
        }
        catch {
            $failed++
            $resultRows.Add([PSCustomObject]@{
                Id = $row.Id
                Status = "失败"
                SourcePath = $row.SourcePath
                TargetPath = $row.TargetPath
                Message = $_.Exception.Message
            }) | Out-Null
        }
    }

    $resultRows | Export-Csv -LiteralPath $ApplyOutputPath -NoTypeInformation -Encoding UTF8
    $rollbackRows | Export-Csv -LiteralPath $RollbackPath -NoTypeInformation -Encoding UTF8
    $samples = @($resultRows | Select-Object -First 80 Id, Status, SourcePath, TargetPath, Message)

    Write-TaskStatus -State "completed" -Message "加标签执行完成。" -Extra @{
        totalCount = $previewRows.Count
        successCount = $success
        skippedCount = $skipped
        failedCount = $failed
        samples = $samples
    }
}
catch {
    Write-TaskStatus -State "failed" -Message $_.Exception.Message -Extra @{
        totalCount = 0
        successCount = 0
        skippedCount = 0
        failedCount = 0
    }
}
