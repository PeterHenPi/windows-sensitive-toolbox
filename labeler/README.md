# Windows 商密文件批量打标签脚本

用途：业务只在最顶层文件夹名前面标注 `【商密二级】` 时，用本脚本递归给该文件夹下面的所有子文件和子文件夹名称前面加上同样标识。

## 文件

- `Add-SecretLevel2Label.ps1`：PowerShell 脚本。
- `Add-SecretLevel2Suffix.ps1`：把标签追加到文件名末尾、扩展名前面的 PowerShell 脚本。

## 预演执行

先预演，不实际修改文件名：

```powershell
powershell -ExecutionPolicy Bypass -File .\Add-SecretLevel2Label.ps1 -RootPath "D:\共享文件\【商密二级】项目资料" -Preview
```

## 正式执行

确认预演结果无误后执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\Add-SecretLevel2Label.ps1 -RootPath "D:\共享文件\【商密二级】项目资料"
```

## 后缀标签版本

示例：`1.txt` 会改成 `1_商密二级.txt`，文件夹 `资料` 会改成 `资料_商密二级`。

这个版本已加入长路径处理，适合深层目录较多的 Windows Server 文件夹。

先预演：

```powershell
powershell -ExecutionPolicy Bypass -File .\Add-SecretLevel2Suffix.ps1 -RootPath "D:\共享文件\【商密二级】项目资料" -Preview
```

确认无误后正式执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\Add-SecretLevel2Suffix.ps1 -RootPath "D:\共享文件\【商密二级】项目资料"
```

## 说明

- 脚本不会修改 `RootPath` 指定的顶层目录本身，只处理它下面的子文件和子文件夹。
- 已经以 `【商密二级】` 开头的文件或文件夹会自动跳过。
- 如果目标名称已存在，会跳过并输出警告，避免覆盖。
- 如果路径过长，建议先在 Windows Server 2019 上开启 Win32 长路径支持。
