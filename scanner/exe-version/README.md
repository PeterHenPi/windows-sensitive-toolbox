# EXE Version

Files in this folder:

- `SensitiveFileScanner.csproj`
- `Program.cs`
- `publish-win-x64.bat`
- `keywords.sample.csv`
- `license.json`
- `Generate-License.ps1`
- `Generate-License.bat`

Save `keywords.sample.csv` as `UTF-8 with BOM` when editing on Windows, especially if you open it with Excel.

Publish example:

```powershell
dotnet publish -c Release --self-contained false
```

Show machine code:

```powershell
.\SensitiveFileScanner.exe --show-machine-code
```
