# Content Scan Version

This version supports both file name scanning and file content scanning.
It can extract text from plain-text files and from OpenXML Office files such as Word, Excel, and PowerPoint.
Legacy `doc/xls/ppt` files can be handled through LibreOffice headless conversion, or through Office COM if Office is installed.
PDF scanning is supported through an optional external `pdftotext` tool.

## Files

- `Scan-SensitiveFiles-WithContent.ps1`
- `Start-Scan.bat`
- `Test-Rules.ps1`
- `Test-Rules.bat`
- `keywords.sample.csv`
- `scan-profile.sample.json`

## Rule Format

Use one rule per row:

```csv
level,priority,keyword,matchScope,matchMode,piiType,enabled,category,notes
一级,100,登录密码,both,contains,,1,credential,fixed_keyword
二级,80,工资表,name,contains,,1,hr,file_name_only
二级,80,客户名单,content,contains,,1,business,content_keyword
二级,80,第[0-9一二三四五六七八九十百千万]+届董事会第[0-9一二三四五六七八九十百千万]+次会议,both,regex,,1,meeting,variable_pattern
一级,100,,content,contains,cn_id_card,1,pii,china_id_card
一级,100,,content,contains,cn_name_mobile_id_combo,1,pii,name_mobile_id_combo
```

Columns:

- `level`: sensitive level name
- `priority`: larger number means higher priority
- `keyword`: keyword or regex pattern
- `matchScope`: `name`, `content`, or `both`
- `matchMode`: `contains` or `regex`
- `piiType`: optional built-in detector such as `cn_mobile`, `cn_id_card`, `email`, `bank_card`, `passport`, `cn_name_mobile_combo`, `cn_name_id_combo`, `cn_name_mobile_id_combo`
- `enabled`: `1/0`, `true/false`, `yes/no`, `on/off`
- `category`: optional
- `notes`: optional

Save the rule CSV as `UTF-8 with BOM` when editing on Windows, especially if you open it with Excel.

Built-in PII detectors:

- `cn_mobile`
- `cn_id_card`
- `email`
- `bank_card`
- `passport`
- `cn_name_mobile_combo`
- `cn_name_id_combo`
- `cn_name_mobile_id_combo`

Combination detector notes:

- `cn_name_mobile_combo`: same line contains a Chinese name candidate and a China mobile number
- `cn_name_id_combo`: same line contains a Chinese name candidate and a valid China ID card number
- `cn_name_mobile_id_combo`: same line contains a Chinese name candidate, a China mobile number, and a valid China ID card number

These combination rules are line-based heuristics. They work best on extracted text such as:

```text
姓名: 张三 手机: 13800138000 身份证号: 11010519491231002X
联系人 李四 13912345678
```

## Rule Debug Tool

Use `Test-Rules.ps1` to test rules against a single piece of text before running a directory scan.

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-Rules.ps1 `
  -ConfigPath .\keywords.sample.csv `
  -Text "姓名: 张三 手机: 13800138000 身份证号: 11010519491231002X" `
  -Scope content
```

Use `-Scope name` to test file name rules:

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-Rules.ps1 `
  -ConfigPath .\keywords.sample.csv `
  -Text "第三届董事会第五次会议纪要.docx" `
  -Scope name
```

Add `-ShowAll` to display non-matching rules and reasons:

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-Rules.ps1 `
  -ConfigPath .\keywords.sample.csv `
  -Text "客户名单 张三 13800138000" `
  -Scope content `
  -ShowAll
```

You can also double-click `Test-Rules.bat` to use interactive mode.

## Current Content Scan Limits

To reduce server impact, this version only scans content when all conditions below are met:

- file extension is in the text extension allowlist
- file size is less than or equal to the configured limit
- file content can be extracted successfully

Default content size limit:

- `10 MB`

Default content extensions:

- `txt`
- `csv`
- `log`
- `json`
- `xml`
- `ini`
- `conf`
- `sql`
- `ps1`
- `bat`
- `cmd`
- `cs`
- `java`
- `py`
- `js`
- `ts`
- `md`
- `docx`
- `docm`
- `xlsx`
- `xlsm`
- `pptx`
- `pptm`
- `pdf`

## Office And PDF Support

Office file support:

- `doc`: reads content through Word COM automation
- `docx` / `docm`: reads OpenXML text nodes from the Word package
- `xls`: reads worksheet cell text through Excel COM automation
- `xlsx` / `xlsm`: reads worksheet cell values from the Excel package
- `ppt`: reads slide text through PowerPoint COM automation
- `pptx` / `pptm`: reads slide text nodes from the PowerPoint package

LibreOffice support for legacy Office formats:

- if `-LibreOfficePath` is provided, the scanner first tries to convert `doc/xls/ppt` to `docx/xlsx/pptx`
- converted files are scanned with the existing native OpenXML logic
- this allows legacy Office content scanning even when Microsoft Office is not installed

PDF support:

- requires an external `pdftotext` executable
- if `pdftotext` is not provided, PDF files are skipped for content scanning

Legacy Office file note:

- if `-LibreOfficePath` is configured, Microsoft Office is not required for `doc/xls/ppt`
- if LibreOffice is not configured, the script falls back to Word/Excel/PowerPoint COM automation
- if neither LibreOffice nor Office COM is available, those files are skipped for content scanning

Example with PDF tool:

```powershell
powershell -ExecutionPolicy Bypass -File .\Scan-SensitiveFiles-WithContent.ps1 `
  -ScanPath "E:\Data" `
  -ConfigPath ".\keywords.sample.csv" `
  -OutputPath ".\result\sensitive_scan_result.csv" `
  -PdfToTextPath "C:\Tools\pdftotext.exe"
```

Example with LibreOffice for legacy `doc/xls/ppt`:

```powershell
powershell -ExecutionPolicy Bypass -File .\Scan-SensitiveFiles-WithContent.ps1 `
  -ScanPath "E:\Data" `
  -ConfigPath ".\keywords.sample.csv" `
  -OutputPath ".\result\sensitive_scan_result.csv" `
  -LibreOfficePath "C:\Program Files\LibreOffice\program\soffice.exe"
```

## Output Columns

- `Index`
- `FilePath`
- `FileName`
- `FileSize`
- `FileType`
- `SensitiveLevel`
- `MatchedKeywords`
- `MatchScope`
- `LineNumber`
- `MatchedSnippet`
- `ScanStatus`
- `SkipReason`
- `ExtractionMethod`

Notes:

- matched files still appear as before
- files skipped for content scanning can also be written to the CSV with a reason
- files that were scanned successfully but had no content match are not added just for noise reduction

## Estimate And Summary

Use `-EstimateOnly` before a full scan when the target directory is large. Estimate mode only enumerates files and calculates scan size; it does not extract file content or run match rules.

```powershell
powershell -ExecutionPolicy Bypass -File .\Scan-SensitiveFiles-WithContent.ps1 `
  -ScanPath "E:\Data" `
  -OutputPath ".\result\sensitive_scan_result.csv" `
  -EstimateOnly
```

The scanner writes a summary CSV next to the output file by default:

```text
.\result\sensitive_scan_result.summary.csv
```

You can also set a custom summary path:

```powershell
powershell -ExecutionPolicy Bypass -File .\Scan-SensitiveFiles-WithContent.ps1 `
  -ScanPath "E:\Data" `
  -ConfigPath ".\keywords.sample.csv" `
  -OutputPath ".\result\sensitive_scan_result.csv" `
  -SummaryPath ".\result\scan_summary.csv"
```

Summary metrics include:

- total file count and total size
- content-scan eligible file count and size
- files skipped by extension
- files skipped by size
- matched files
- content extraction failures
- Office / PDF / text / other file counts
- per-extension file counts

## HTML Report

The scanner writes an HTML report next to the output CSV by default:

```text
.\result\sensitive_scan_result.report.html
```

You can also set a custom path:

```powershell
powershell -ExecutionPolicy Bypass -File .\Scan-SensitiveFiles-WithContent.ps1 `
  -ProfilePath .\scan-profile.sample.json `
  -HtmlReportPath ".\result\scan_report.html"
```

The report includes:

- total files and total size
- matched file count
- content eligibility and extraction failures
- incremental scan counters
- sensitive level distribution
- scan status distribution
- extraction method distribution
- match scope distribution
- top file extensions

## Incremental Scan

Use `-Incremental` to skip files that have not changed since the last scan. The scanner compares file path, file size, and last write time.

```powershell
powershell -ExecutionPolicy Bypass -File .\Scan-SensitiveFiles-WithContent.ps1 `
  -ProfilePath .\scan-profile.sample.json `
  -Incremental `
  -StatePath ".\result\sensitive_scan_result.state.json"
```

The state file is written after a successful scan. If `-StatePath` is not provided, the scanner creates one next to the output file:

```text
.\result\sensitive_scan_result.state.json
```

Summary metrics include incremental counters:

- `IncrementalChangedFiles`
- `IncrementalSkippedFiles`
- `IncrementalDeletedFiles`

## Masking And Timeout

Use `-MaskSensitiveValues` to mask sensitive values in the result CSV. This helps prevent the scan result itself from becoming a new sensitive file.

```powershell
powershell -ExecutionPolicy Bypass -File .\Scan-SensitiveFiles-WithContent.ps1 `
  -ScanPath "E:\Data" `
  -ConfigPath ".\keywords.sample.csv" `
  -OutputPath ".\result\sensitive_scan_result.csv" `
  -MaskSensitiveValues
```

Masking applies to matched keywords and matched snippets, including common values such as China ID cards, mobile numbers, emails, bank cards, and passport-like values.

Use `-ExtractionTimeoutSeconds` to limit external extraction tools such as `pdftotext` and LibreOffice. Default value is `60`.

```powershell
powershell -ExecutionPolicy Bypass -File .\Scan-SensitiveFiles-WithContent.ps1 `
  -ScanPath "E:\Data" `
  -ConfigPath ".\keywords.sample.csv" `
  -OutputPath ".\result\sensitive_scan_result.csv" `
  -ExtractionTimeoutSeconds 60
```

## Profile Config

Use a scan profile when you want to avoid long command lines. The profile is a JSON file containing common scan parameters.

Example:

```json
{
  "scanPath": "E:\\Data",
  "configPath": ".\\keywords.sample.csv",
  "outputPath": ".\\result\\sensitive_scan_result.csv",
  "summaryPath": ".\\result\\sensitive_scan_result.summary.csv",
  "htmlReportPath": ".\\result\\sensitive_scan_result.report.html",
  "estimateOnly": false,
  "incremental": false,
  "statePath": ".\\result\\sensitive_scan_result.state.json",
  "recurse": true,
  "excludePaths": [
    "E:\\Data\\Logs",
    "E:\\Data\\Temp",
    "E:\\Data\\DB"
  ],
  "progressInterval": 10000,
  "pauseMilliseconds": 50,
  "maxContentFileSizeMB": 10,
  "extractionTimeoutSeconds": 60,
  "maskSensitiveValues": true,
  "pdfToTextPath": "C:\\Tools\\pdftotext.exe",
  "libreOfficePath": "C:\\Program Files\\LibreOffice\\program\\soffice.exe"
}
```

Run with a profile:

```powershell
powershell -ExecutionPolicy Bypass -File .\Scan-SensitiveFiles-WithContent.ps1 `
  -ProfilePath .\scan-profile.sample.json
```

Command-line parameters override values from the profile. For example:

```powershell
powershell -ExecutionPolicy Bypass -File .\Scan-SensitiveFiles-WithContent.ps1 `
  -ProfilePath .\scan-profile.sample.json `
  -EstimateOnly
```

## Run Example

```powershell
powershell -ExecutionPolicy Bypass -File .\Scan-SensitiveFiles-WithContent.ps1 `
  -ScanPath "E:\Data" `
  -ConfigPath ".\keywords.sample.csv" `
  -OutputPath ".\result\sensitive_scan_result.csv"
```

Large-directory friendly example:

```powershell
powershell -ExecutionPolicy Bypass -File .\Scan-SensitiveFiles-WithContent.ps1 `
  -ScanPath "E:\Data" `
  -ConfigPath ".\keywords.sample.csv" `
  -OutputPath ".\result\sensitive_scan_result.csv" `
  -ExcludePaths "E:\Data\Logs","E:\Data\Temp","E:\Data\DB" `
  -ProgressInterval 10000 `
  -PauseMilliseconds 50 `
  -MaxContentFileSizeMB 10
```
