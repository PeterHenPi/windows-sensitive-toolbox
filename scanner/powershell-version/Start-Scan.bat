@echo off
setlocal

set SCRIPT_DIR=%~dp0
cd /d "%SCRIPT_DIR%"

if "%~1"=="" (
    echo No scan path supplied. Starting interactive mode...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Scan-SensitiveFiles.ps1"
    pause
    exit /b %errorlevel%
)

set SCAN_PATH=%~1

if "%~2"=="" (
    set CONFIG_PATH=%SCRIPT_DIR%keywords.sample.csv
) else (
    set CONFIG_PATH=%~2
)

if "%~3"=="" (
    set OUTPUT_PATH=%SCRIPT_DIR%result\sensitive_scan_result.csv
) else (
    set OUTPUT_PATH=%~3
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Scan-SensitiveFiles.ps1" -ScanPath "%SCAN_PATH%" -ConfigPath "%CONFIG_PATH%" -OutputPath "%OUTPUT_PATH%"

if errorlevel 1 (
    pause
)

endlocal
