@echo off
setlocal

dotnet publish -c Release -r win-x64 --self-contained true /p:PublishSingleFile=true

if errorlevel 1 (
    echo Publish failed.
    exit /b 1
)

set PUBLISH_DIR=%~dp0bin\Release\net8.0\win-x64\publish

if exist "%~dp0keywords.sample.csv" (
    copy /Y "%~dp0keywords.sample.csv" "%PUBLISH_DIR%\keywords.sample.csv" >nul
)

if exist "%~dp0README.md" (
    copy /Y "%~dp0README.md" "%PUBLISH_DIR%\README.md" >nul
)

if exist "%~dp0license.json" (
    copy /Y "%~dp0license.json" "%PUBLISH_DIR%\license.json" >nul
)

if exist "%~dp0Generate-License.ps1" (
    copy /Y "%~dp0Generate-License.ps1" "%PUBLISH_DIR%\Generate-License.ps1" >nul
)

if exist "%~dp0Generate-License.bat" (
    copy /Y "%~dp0Generate-License.bat" "%PUBLISH_DIR%\Generate-License.bat" >nul
)

echo.
echo Publish succeeded.
echo EXE path:
echo   %PUBLISH_DIR%\SensitiveFileScanner.exe
echo Rule file:
echo   %PUBLISH_DIR%\keywords.sample.csv
echo Readme:
echo   %PUBLISH_DIR%\README.md
echo License:
echo   %PUBLISH_DIR%\license.json
echo License generator:
echo   %PUBLISH_DIR%\Generate-License.bat

endlocal
