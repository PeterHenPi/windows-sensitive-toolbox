[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$IssuedTo,

    [Parameter(Mandatory = $false)]
    [string]$MachineCode,

    [Parameter(Mandatory = $false)]
    [string]$ExpiresOn,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\license.json"
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

if ([string]::IsNullOrWhiteSpace($IssuedTo)) {
    Write-Host "No parameters detected. Interactive mode started."
    $IssuedTo = Read-InputWithDefault -PromptText "Enter customer name" -DefaultValue "Demo Customer"
    $MachineCode = Read-InputWithDefault -PromptText "Enter machine code" -DefaultValue "REPLACE_WITH_TARGET_MACHINE_CODE"
    $ExpiresOn = Read-InputWithDefault -PromptText "Enter expiration date (yyyy-MM-dd)" -DefaultValue "2026-12-31"
    $OutputPath = Read-InputWithDefault -PromptText "Enter output license path" -DefaultValue ".\license.json"
}

if ([string]::IsNullOrWhiteSpace($MachineCode)) {
    throw "MachineCode is required."
}

if ([string]::IsNullOrWhiteSpace($ExpiresOn)) {
    throw "ExpiresOn is required."
}

$parsedDate = $null
try {
    $parsedDate = [datetime]::ParseExact($ExpiresOn.Trim(), "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
}
catch {
    throw "ExpiresOn must use yyyy-MM-dd format."
}

$license = [PSCustomObject]@{
    issuedTo    = $IssuedTo
    machineCode = $MachineCode
    expiresOn   = $parsedDate.ToString("yyyy-MM-dd")
}

$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$license | ConvertTo-Json | Set-Content -LiteralPath $resolvedOutputPath -Encoding UTF8

Write-Host "License file created successfully."
Write-Host "Output file: $resolvedOutputPath"
