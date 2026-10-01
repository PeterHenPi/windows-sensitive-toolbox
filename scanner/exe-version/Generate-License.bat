@echo off
setlocal

set SCRIPT_DIR=%~dp0

if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Generate-License.ps1"
    pause
    exit /b %errorlevel%
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Generate-License.ps1" -IssuedTo "%~1" -MachineCode "%~2" -ExpiresOn "%~3" -OutputPath "%~4"

if errorlevel 1 (
    pause
)

endlocal
