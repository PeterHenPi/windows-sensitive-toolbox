# PowerShell Version

Files in this folder:

- `Scan-SensitiveFiles.ps1`
- `Start-Scan.bat`
- `keywords.sample.csv`

Rule format:

```csv
level,priority,keyword,matchMode,enabled,category,notes
二级,80,合同,contains,1,business,fixed_keyword
二级,80,第[0-9一二三四五六七八九十百千万]+届董事会第[0-9一二三四五六七八九十百千万]+次会议,regex,1,meeting,variable_pattern
```

Save the rule CSV as `UTF-8 with BOM` when editing on Windows, especially if you open it with Excel.

`matchMode` supports:

- `contains`: normal keyword matching
- `regex`: regular expression matching

Run example:

```powershell
powershell -ExecutionPolicy Bypass -File .\Scan-SensitiveFiles.ps1 -ScanPath "E:\Data" -ConfigPath ".\keywords.sample.csv" -OutputPath ".\result\sensitive_scan_result.csv"
```
