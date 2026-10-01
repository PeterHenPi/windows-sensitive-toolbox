# Windows Sensitive Toolbox

Windows 本地敏感文件扫描和文件名标签工具。通过本地网页选择任务、预览结果并查看历史记录。文件和报告保存在本机。

## 功能

- 文件名扫描与文档内容扫描，生成 CSV、摘要及 HTML 报告。
- CSV 关键词和正则规则，以及内置个人信息识别规则。
- 批量添加文件名标签，执行前预览，执行后保存回滚记录。
- 规则测试和提取组件环境检测。
- 独立 PowerShell 扫描器、标签脚本及可选 .NET 命令行版本。

## 启动

在 Windows 中双击 `Start-Toolbox.bat`，或运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\server.ps1
```

打开 <http://127.0.0.1:8787/>。扫描规则示例位于 `scanner/content-scan-version/keywords.sample.csv`。先使用测试目录验证命中和改名结果。

## 目录

| 目录 | 用途 |
| --- | --- |
| `public/` | 本地网页 |
| `scripts/` | 扫描和标签任务执行器 |
| `scanner/powershell-version/` | 文件名扫描器 |
| `scanner/content-scan-version/` | 内容扫描器及详细说明 |
| `scanner/exe-version/` | 可选 .NET 源码，不含构建产物或授权文件 |
| `labeler/` | 独立前缀和后缀标签脚本 |
| `tasks/` | 运行时任务和报告，不纳入版本管理 |

PowerShell UI 已改为读取本仓库内的扫描器，无需创建旁边的项目目录。内容提取能力取决于文件类型和 Office、LibreOffice、PDF 提取组件是否安装，详见 [内容扫描说明](scanner/content-scan-version/README.md)。

## 使用边界

工具是本地工作站用途，未提供多用户登录。命中表示符合规则，需要人工确认文件属性；文件名标签不提供加密或访问权限控制。示例规则不等同于组织的正式分类标准。

## 验证状态

本次整理检查脚本语法、仓库依赖路径，并用虚构文本测试扫描流程。macOS 检查无法代替 Windows Server 的 Office 提取、文件权限及真实目录运行验收。上线前应在目标 Windows 环境完成预览、执行和回滚验证。
