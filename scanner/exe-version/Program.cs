using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

if (args.Any(a => a is "-h" or "--help")) {
    PrintUsage();
    return 0;
}

if (args.Any(a => a == "--show-machine-code")) {
    Console.WriteLine(GetMachineCode());
    return 0;
}

var interactiveMode = args.Length == 0;
var options = interactiveMode ? PromptForOptions() : ParseArguments(args);

if (string.IsNullOrWhiteSpace(options.ScanPath) || string.IsNullOrWhiteSpace(options.ConfigPath)) {
    Console.Error.WriteLine("Error: --scan-path and --config are required.");
    PrintUsage();
    WaitIfInteractive(interactiveMode);
    return 1;
}

try {
    var scanPath = Path.GetFullPath(options.ScanPath);
    var configPath = Path.GetFullPath(options.ConfigPath);
    var outputPath = Path.GetFullPath(options.OutputPath ?? "sensitive_scan_result.csv");
    var licensePath = Path.GetFullPath(options.LicensePath ?? Path.Combine(AppContext.BaseDirectory, "license.json"));

    if (!Directory.Exists(scanPath)) {
        Console.Error.WriteLine($"Error: scan path not found: {scanPath}");
        WaitIfInteractive(interactiveMode);
        return 1;
    }

    if (!File.Exists(configPath)) {
        Console.Error.WriteLine($"Error: config file not found: {configPath}");
        WaitIfInteractive(interactiveMode);
        return 1;
    }

    var license = LoadAndValidateLicense(licensePath);

    var rules = LoadRules(configPath);
    var outputDirectory = Path.GetDirectoryName(outputPath);
    if (!string.IsNullOrWhiteSpace(outputDirectory)) {
        Directory.CreateDirectory(outputDirectory);
    }

    var excludedPrefixes = ExpandExcludePaths(options.ExcludePaths)
        .Select(NormalizePrefix)
        .Distinct(StringComparer.OrdinalIgnoreCase)
        .ToList();

    if (IsExcludedPath(NormalizePrefix(scanPath), excludedPrefixes)) {
        throw new InvalidOperationException($"Scan path is fully excluded: {scanPath}");
    }

    var summary = ScanFiles(scanPath, rules, outputPath, options, excludedPrefixes);

    Console.WriteLine($"License valid until: {license.ExpiresOn:yyyy-MM-dd}");
    Console.WriteLine($"Scan completed. Scanned {summary.ScannedCount} files and found {summary.MatchedCount} suspected sensitive files.");
    Console.WriteLine($"Result file: {outputPath}");
    WaitIfInteractive(interactiveMode);
    return 0;
}
catch (Exception ex) {
    Console.Error.WriteLine($"Execution failed: {ex.Message}");
    WaitIfInteractive(interactiveMode);
    return 1;
}

static void PrintUsage()
{
    Console.WriteLine("SensitiveFileScanner");
    Console.WriteLine("Usage:");
    Console.WriteLine("  SensitiveFileScanner.exe --scan-path <directory> --config <config-file> [--output <csv-file>] [--no-recurse]");
    Console.WriteLine("                           [--exclude-paths <path1,path2>] [--progress-interval <n>] [--pause-milliseconds <n>]");
    Console.WriteLine("                           [--license <license-file>]");
    Console.WriteLine("  SensitiveFileScanner.exe --show-machine-code");
    Console.WriteLine();
    Console.WriteLine("Example:");
    Console.WriteLine(@"  SensitiveFileScanner.exe --scan-path ""D:\Data"" --config "".\keywords.sample.csv"" --output "".\result\sensitive_scan_result.csv"" --exclude-paths ""D:\Data\Logs,D:\Data\Temp"" --progress-interval 10000 --pause-milliseconds 50 --license "".\license.json""");
}

static AppOptions ParseArguments(string[] args)
{
    var options = new AppOptions {
        Recurse = true,
        ProgressInterval = 5000,
        PauseMilliseconds = 0
    };

    for (var i = 0; i < args.Length; i++) {
        var arg = args[i];
        switch (arg) {
            case "--scan-path":
                options.ScanPath = ReadValue(args, ref i, arg);
                break;
            case "--config":
                options.ConfigPath = ReadValue(args, ref i, arg);
                break;
            case "--output":
                options.OutputPath = ReadValue(args, ref i, arg);
                break;
            case "--exclude-paths":
                options.ExcludePaths = ReadValue(args, ref i, arg)
                    .Split([',', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                    .ToList();
                break;
            case "--progress-interval":
                options.ProgressInterval = ParseNonNegativeInt(ReadValue(args, ref i, arg), arg);
                break;
            case "--pause-milliseconds":
                options.PauseMilliseconds = ParseNonNegativeInt(ReadValue(args, ref i, arg), arg);
                break;
            case "--license":
                options.LicensePath = ReadValue(args, ref i, arg);
                break;
            case "--no-recurse":
                options.Recurse = false;
                break;
            default:
                throw new ArgumentException($"Unsupported argument: {arg}");
        }
    }

    return options;
}

static int ParseNonNegativeInt(string value, string argName)
{
    if (!int.TryParse(value, out var result) || result < 0) {
        throw new ArgumentException($"Argument {argName} must be a non-negative integer.");
    }

    return result;
}

static AppOptions PromptForOptions()
{
    Console.WriteLine("SensitiveFileScanner");
    Console.WriteLine("No command line arguments detected. Interactive mode started.");
    Console.WriteLine();

    var scanPath = Prompt("Enter scan directory", @"D:\Data");
    var configPath = Prompt("Enter rule file path (.csv or .json)", @".\keywords.sample.csv");
    var outputPath = Prompt("Enter output CSV path", @".\result\sensitive_scan_result.csv");
    var recurse = Prompt("Scan subdirectories recursively? (Y/N)", "Y");
    var excludePaths = Prompt("Exclude paths (comma-separated, optional)", "");
    var progressInterval = Prompt("Progress interval", "5000");
    var pauseMilliseconds = Prompt("Pause milliseconds after each progress report", "0");
    var licensePath = Prompt("License file path", @".\license.json");

    return new AppOptions {
        ScanPath = scanPath,
        ConfigPath = configPath,
        OutputPath = outputPath,
        Recurse = !string.Equals(recurse, "N", StringComparison.OrdinalIgnoreCase),
        ExcludePaths = excludePaths
            .Split([',', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .ToList(),
        ProgressInterval = int.TryParse(progressInterval, out var interval) && interval >= 0 ? interval : 5000,
        PauseMilliseconds = int.TryParse(pauseMilliseconds, out var pause) && pause >= 0 ? pause : 0,
        LicensePath = licensePath
    };
}

static string Prompt(string label, string defaultValue)
{
    Console.Write($"{label} [{defaultValue}]: ");
    var input = Console.ReadLine();
    return string.IsNullOrWhiteSpace(input) ? defaultValue : input.Trim();
}

static string ReadValue(string[] args, ref int index, string argName)
{
    if (index + 1 >= args.Length) {
        throw new ArgumentException($"Argument {argName} is missing a value.");
    }

    index++;
    return args[index];
}

static void WaitIfInteractive(bool interactiveMode)
{
    if (!interactiveMode) {
        return;
    }

    Console.WriteLine();
    Console.Write("Press Enter to exit...");
    Console.ReadLine();
}

static List<LevelRule> LoadRules(string configPath)
{
    var extension = Path.GetExtension(configPath).ToLowerInvariant();
    var rules = extension switch {
        ".json" => LoadRulesFromJson(configPath),
        ".csv" => LoadRulesFromCsv(configPath),
        _ => throw new InvalidOperationException($"Unsupported config format: {extension}. Only .json and .csv are supported.")
    };

    return rules
        .OrderByDescending(r => r.Priority)
        .ThenBy(r => r.Level, StringComparer.Ordinal)
        .ToList();
}

static LicenseInfo LoadAndValidateLicense(string licensePath)
{
    if (!File.Exists(licensePath)) {
        throw new InvalidOperationException($"License file not found: {licensePath}");
    }

    var json = File.ReadAllText(licensePath, Encoding.UTF8);
    var license = JsonSerializer.Deserialize<LicenseInfo>(json, new JsonSerializerOptions {
        PropertyNameCaseInsensitive = true
    });

    if (license is null) {
        throw new InvalidOperationException("Invalid license: file is empty or unreadable.");
    }

    if (string.IsNullOrWhiteSpace(license.ExpiresOnRaw)) {
        throw new InvalidOperationException("Invalid license: expiresOn is required.");
    }

    if (string.IsNullOrWhiteSpace(license.MachineCode)) {
        throw new InvalidOperationException("Invalid license: machineCode is required.");
    }

    if (!DateTime.TryParseExact(
        license.ExpiresOnRaw,
        "yyyy-MM-dd",
        CultureInfo.InvariantCulture,
        DateTimeStyles.None,
        out var expiresOn)) {
        throw new InvalidOperationException("Invalid license: expiresOn must use yyyy-MM-dd format.");
    }

    var currentMachineCode = GetMachineCode();
    if (!string.Equals(license.MachineCode.Trim(), currentMachineCode, StringComparison.OrdinalIgnoreCase)) {
        throw new InvalidOperationException("License machineCode does not match this machine.");
    }

    expiresOn = expiresOn.Date;
    var today = DateTime.Today;
    if (today > expiresOn) {
        throw new InvalidOperationException($"License expired on {expiresOn:yyyy-MM-dd}.");
    }

    license.ExpiresOn = expiresOn;
    return license;
}

static string GetMachineCode()
{
    var machineGuid = GetWindowsMachineGuid();
    if (string.IsNullOrWhiteSpace(machineGuid)) {
        throw new InvalidOperationException("Unable to read Windows MachineGuid.");
    }

    var raw = $"{Environment.MachineName}|{machineGuid.Trim()}";
    using var sha256 = SHA256.Create();
    var hash = sha256.ComputeHash(Encoding.UTF8.GetBytes(raw));
    return Convert.ToHexString(hash);
}

static string? GetWindowsMachineGuid()
{
    using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Cryptography");
    return key?.GetValue("MachineGuid")?.ToString();
}

static List<LevelRule> LoadRulesFromJson(string configPath)
{
    var json = File.ReadAllText(configPath, Encoding.UTF8);
    var rawRules = JsonSerializer.Deserialize<List<RuleConfig>>(json, new JsonSerializerOptions {
        PropertyNameCaseInsensitive = true
    });

    if (rawRules is null || rawRules.Count == 0) {
        throw new InvalidOperationException("Invalid config: JSON root must be a non-empty array.");
    }

    var rules = new List<LevelRule>();
    foreach (var item in rawRules) {
        if (string.IsNullOrWhiteSpace(item.Level)) {
            throw new InvalidOperationException("Invalid config: level is required.");
        }

        var keywords = item.Keywords?
            .Where(k => !string.IsNullOrWhiteSpace(k))
            .Select(k => k!.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (keywords is null || keywords.Count == 0) {
            throw new InvalidOperationException($"Invalid config: level [{item.Level}] must contain at least one keyword.");
        }

        var matchMode = string.IsNullOrWhiteSpace(item.MatchMode)
            ? "contains"
            : item.MatchMode.Trim().ToLowerInvariant();

        if (matchMode is not ("contains" or "regex")) {
            throw new InvalidOperationException($"Invalid config: matchMode for level [{item.Level}] must be contains or regex.");
        }

        rules.Add(new LevelRule(item.Level.Trim(), item.Priority, matchMode, keywords));
    }

    return rules;
}

static List<LevelRule> LoadRulesFromCsv(string configPath)
{
    var lines = File.ReadAllLines(configPath, Encoding.UTF8);
    if (lines.Length <= 1) {
        throw new InvalidOperationException("Invalid config: CSV must contain a header row and at least one data row.");
    }

    var rows = ParseCsv(lines);
    if (rows.Count == 0) {
        throw new InvalidOperationException("Invalid config: CSV contains no valid data rows.");
    }

    var grouped = new Dictionary<string, CsvRuleAccumulator>(StringComparer.OrdinalIgnoreCase);

    foreach (var row in rows) {
        if (row.TryGetValue("enabled", out var enabledValue) && !IsRuleEnabled(enabledValue)) {
            continue;
        }

        var level = GetCsvValue(row, "level");
        if (string.IsNullOrWhiteSpace(level)) {
            throw new InvalidOperationException("Invalid config: CSV must contain a non-empty level column.");
        }

        var priorityText = GetCsvValue(row, "priority");
        var priority = 0;
        if (!string.IsNullOrWhiteSpace(priorityText) && !int.TryParse(priorityText, out priority)) {
            throw new InvalidOperationException($"Invalid config: priority for level [{level}] is not a valid integer.");
        }

        var matchMode = GetCsvValue(row, "matchMode");
        if (string.IsNullOrWhiteSpace(matchMode)) {
            matchMode = "contains";
        }
        matchMode = matchMode.Trim().ToLowerInvariant();
        if (matchMode is not ("contains" or "regex")) {
            throw new InvalidOperationException($"Invalid config: matchMode for level [{level}] must be contains or regex.");
        }

        var parsedKeywords = new List<string>();
        var keywordsCell = GetCsvValue(row, "keywords");
        if (!string.IsNullOrWhiteSpace(keywordsCell)) {
            parsedKeywords.AddRange(SplitKeywords(keywordsCell));
        }

        var keywordCell = GetCsvValue(row, "keyword");
        if (!string.IsNullOrWhiteSpace(keywordCell)) {
            parsedKeywords.Add(keywordCell.Trim());
        }

        parsedKeywords = parsedKeywords
            .Where(k => !string.IsNullOrWhiteSpace(k))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (parsedKeywords.Count == 0) {
            continue;
        }

        if (!grouped.TryGetValue(level, out var accumulator)) {
            accumulator = new CsvRuleAccumulator(level.Trim(), priority, matchMode);
            grouped[level] = accumulator;
        }

        accumulator.Priority = Math.Max(accumulator.Priority, priority);
        if (matchMode == "regex") {
            accumulator.MatchMode = "regex";
        }
        foreach (var keyword in parsedKeywords) {
            accumulator.Keywords.Add(keyword);
        }
    }

    return grouped.Values
        .Select(item => new LevelRule(item.Level, item.Priority, item.MatchMode, item.Keywords.ToList()))
        .ToList();
}

static bool IsRuleEnabled(string? value)
{
    if (string.IsNullOrWhiteSpace(value)) {
        return true;
    }

    return value.Trim().ToLowerInvariant() switch {
        "0" => false,
        "false" => false,
        "no" => false,
        "n" => false,
        "off" => false,
        _ => true
    };
}

static List<Dictionary<string, string>> ParseCsv(string[] lines)
{
    var rows = new List<Dictionary<string, string>>();
    var headers = SplitCsvLine(lines[0]).Select(h => h.Trim()).ToList();

    for (var i = 1; i < lines.Length; i++) {
        if (string.IsNullOrWhiteSpace(lines[i])) {
            continue;
        }

        var values = SplitCsvLine(lines[i]);
        var row = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (var j = 0; j < headers.Count; j++) {
            row[headers[j]] = j < values.Count ? values[j] : string.Empty;
        }

        rows.Add(row);
    }

    return rows;
}

static List<string> SplitCsvLine(string line)
{
    var values = new List<string>();
    var builder = new StringBuilder();
    var inQuotes = false;

    for (var i = 0; i < line.Length; i++) {
        var ch = line[i];
        if (ch == '"') {
            if (inQuotes && i + 1 < line.Length && line[i + 1] == '"') {
                builder.Append('"');
                i++;
            }
            else {
                inQuotes = !inQuotes;
            }
            continue;
        }

        if (ch == ',' && !inQuotes) {
            values.Add(builder.ToString());
            builder.Clear();
            continue;
        }

        builder.Append(ch);
    }

    values.Add(builder.ToString());
    return values;
}

static string GetCsvValue(Dictionary<string, string> row, string columnName)
{
    return row.TryGetValue(columnName, out var value) ? value.Trim() : string.Empty;
}

static IEnumerable<string> SplitKeywords(string value)
{
    return value
        .Split(['|', ',', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
        .Where(item => !string.IsNullOrWhiteSpace(item));
}

static IEnumerable<string> ExpandExcludePaths(IEnumerable<string> rawPaths)
{
    foreach (var rawPath in rawPaths) {
        if (string.IsNullOrWhiteSpace(rawPath)) {
            continue;
        }

        foreach (var part in rawPath.Split([',', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)) {
            if (!string.IsNullOrWhiteSpace(part)) {
                yield return part;
            }
        }
    }
}

static string NormalizePrefix(string path)
{
    var cleanPath = path.Trim().Trim('"', '\'');
    if (string.IsNullOrWhiteSpace(cleanPath)) {
        throw new InvalidOperationException("Exclude path is empty.");
    }

    var fullPath = Path.GetFullPath(cleanPath).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    return fullPath + Path.DirectorySeparatorChar;
}

static bool IsExcludedPath(string targetPath, IReadOnlyList<string> excludedPrefixes)
{
    foreach (var prefix in excludedPrefixes) {
        if (targetPath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) {
            return true;
        }
    }

    return false;
}

static IEnumerable<FileInfo> EnumerateFiles(string rootPath, bool recurse, IReadOnlyList<string> excludedPrefixes)
{
    if (!recurse) {
        foreach (var filePath in Directory.EnumerateFiles(rootPath, "*", SearchOption.TopDirectoryOnly)) {
            if (!IsExcludedPath(filePath, excludedPrefixes)) {
                yield return new FileInfo(filePath);
            }
        }
        yield break;
    }

    var stack = new Stack<string>();
    stack.Push(rootPath);

    while (stack.Count > 0) {
        var currentPath = stack.Pop();

        IEnumerable<string> directories;
        try {
            directories = Directory.EnumerateDirectories(currentPath);
        }
        catch {
            continue;
        }

        foreach (var directoryPath in directories) {
            var normalizedDirectory = NormalizePrefix(directoryPath);
            if (!IsExcludedPath(normalizedDirectory, excludedPrefixes)) {
                stack.Push(directoryPath);
            }
        }

        IEnumerable<string> files;
        try {
            files = Directory.EnumerateFiles(currentPath);
        }
        catch {
            continue;
        }

        foreach (var filePath in files) {
            if (!IsExcludedPath(filePath, excludedPrefixes)) {
                yield return new FileInfo(filePath);
            }
        }
    }
}

static MatchResult? FindMatch(string fileName, IReadOnlyList<LevelRule> rules)
{
    foreach (var rule in rules) {
        var matched = new List<string>();
        foreach (var keyword in rule.Keywords) {
            if (rule.MatchMode == "regex") {
                if (System.Text.RegularExpressions.Regex.IsMatch(fileName, keyword, System.Text.RegularExpressions.RegexOptions.IgnoreCase)) {
                    matched.Add(keyword);
                }
            }
            else {
                if (fileName.Contains(keyword, StringComparison.OrdinalIgnoreCase)) {
                    matched.Add(keyword);
                }
            }
        }

        matched = matched
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (matched.Count > 0) {
            return new MatchResult(rule.Level, matched);
        }
    }

    return null;
}

static ScanSummary ScanFiles(string scanPath, IReadOnlyList<LevelRule> rules, string outputPath, AppOptions options, IReadOnlyList<string> excludedPrefixes)
{
    using var writer = new StreamWriter(outputPath, false, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
    writer.WriteLine("Index,FilePath,FileName,FileSize,FileType,SensitiveLevel,MatchedKeywords");

    var scannedCount = 0;
    var matchedCount = 0;
    var index = 1;

    foreach (var file in EnumerateFiles(scanPath, options.Recurse, excludedPrefixes)) {
        scannedCount++;

        if (options.ProgressInterval > 0 && scannedCount % options.ProgressInterval == 0) {
            Console.WriteLine($"Progress: scanned {scannedCount} files, matched {matchedCount} files.");
            if (options.PauseMilliseconds > 0) {
                Thread.Sleep(options.PauseMilliseconds);
            }
        }

        var match = FindMatch(file.Name, rules);
        if (match is null) {
            continue;
        }

        writer.WriteLine(string.Join(",", new[] {
            EscapeCsv(index.ToString(CultureInfo.InvariantCulture)),
            EscapeCsv(file.FullName),
            EscapeCsv(file.Name),
            EscapeCsv(file.Length.ToString(CultureInfo.InvariantCulture)),
            EscapeCsv(string.IsNullOrWhiteSpace(file.Extension) ? "no-extension" : file.Extension.TrimStart('.').ToLowerInvariant()),
            EscapeCsv(match.Level),
            EscapeCsv(string.Join("|", match.Keywords))
        }));

        matchedCount++;
        index++;
    }

    return new ScanSummary(scannedCount, matchedCount);
}

static string EscapeCsv(string value)
{
    if (value.Contains('"')) {
        value = value.Replace("\"", "\"\"");
    }

    return value.IndexOfAny([',', '"', '\r', '\n']) >= 0
        ? $"\"{value}\""
        : value;
}

sealed class AppOptions
{
    public string? ScanPath { get; set; }
    public string? ConfigPath { get; set; }
    public string? OutputPath { get; set; }
    public string? LicensePath { get; set; }
    public bool Recurse { get; set; }
    public List<string> ExcludePaths { get; set; } = [];
    public int ProgressInterval { get; set; }
    public int PauseMilliseconds { get; set; }
}

sealed class LicenseInfo
{
    public string? IssuedTo { get; set; }
    public string? MachineCode { get; set; }
    public string? ExpiresOnRaw { get; set; }
    public DateTime ExpiresOn { get; set; }

    [JsonPropertyName("expiresOn")]
    public string? ExpiresOnAlias {
        get => ExpiresOnRaw;
        set => ExpiresOnRaw = value;
    }

    [JsonPropertyName("machineCode")]
    public string? MachineCodeAlias {
        get => MachineCode;
        set => MachineCode = value;
    }
}

sealed class RuleConfig
{
    public string? Level { get; set; }
    public int Priority { get; set; }
    public string? MatchMode { get; set; }
    public List<string?>? Keywords { get; set; }
}

sealed class CsvRuleAccumulator
{
    public CsvRuleAccumulator(string level, int priority, string matchMode)
    {
        Level = level;
        Priority = priority;
        MatchMode = matchMode;
        Keywords = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    }

    public string Level { get; }
    public int Priority { get; set; }
    public string MatchMode { get; set; }
    public HashSet<string> Keywords { get; }
}

sealed record LevelRule(string Level, int Priority, string MatchMode, List<string> Keywords);

sealed record MatchResult(string Level, List<string> Keywords);

sealed record ScanSummary(int ScannedCount, int MatchedCount);
