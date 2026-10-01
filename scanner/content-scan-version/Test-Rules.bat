@echo off
setlocal

set SCRIPT_DIR=%~dp0

if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Test-Rules.ps1"
    pause
    exit /b %errorlevel%
)

set TEST_TEXT=%~1

if "%~2"=="" (
    set CONFIG_PATH=%SCRIPT_DIR%keywords.sample.csv
) else (
    set CONFIG_PATH=%~2
)

if "%~3"=="" (
    set SCOPE=content
) else (
    set SCOPE=%~3
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Test-Rules.ps1" -Text "%TEST_TEXT%" -ConfigPath "%CONFIG_PATH%" -Scope "%SCOPE%"

if errorlevel 1 (
    pause
)

endlocal
