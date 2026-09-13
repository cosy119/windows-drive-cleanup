# Windows Drive Cleanup Skill

一个用于 Codex 的 Windows 磁盘空间审计技能。它先以只读方式扫描指定磁盘，生成可以人工检查的候选清单；只有用户明确批准具体文件编号后，才会移动文件或将低风险文件送入回收站。

默认目标是 `C:\`，也可以在对话中改成其他本地磁盘，例如 `D:\` 或 `E:\`。

## 主要功能

- 只读扫描，不在检查阶段修改任何文件。
- 找出较旧的临时文件、崩溃报告和诊断文件，标记为低风险删除候选。
- 找出体积较大的个人文档、图片、音视频、压缩包和安装包，标记为人工确认的移动候选。
- 自动排除 Windows、Program Files、ProgramData、恢复目录、应用数据、浏览器资料、代码仓库、数据库、密钥、云端占位文件和重解析点等高风险内容。
- 为每个候选文件记录完整路径、大小、修改时间、原因和唯一编号；仅在批准移动后计算 SHA-256。
- 执行前再次核对文件大小和修改时间；移动时校验复制前后的 SHA-256，扫描后发生变化的文件会被跳过。
- 移动操作使用另一磁盘上的日期隔离目录，不覆盖已有文件。
- 删除默认进入 Windows 回收站，不提供静默永久删除。

## 安装

在 PowerShell 中进入仓库目录：

```powershell
cd "仓库所在目录\windows-drive-cleanup"
```

运行安装脚本：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-skill.ps1
```

默认安装到 `$CODEX_HOME\skills`；如果没有设置 `CODEX_HOME`，则安装到 `%USERPROFILE%\.codex\skills`。也可以指定技能目录：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-skill.ps1 -DestinationRoot "D:\Codex\skills"
```

安装到 WorkBuddy 的自动发现目录：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-skill.ps1 -Platform WorkBuddy
```

这会安装到 `%USERPROFILE%\.workbuddy\skills\windows-drive-cleanup`。仅把仓库放在 `D:\skills\WorkBuddy` 不会被 WorkBuddy 自动发现。

安装完成后重新打开 Codex 会话。

## 在 Codex 对话中使用

可以直接说：

```text
使用 $windows-drive-cleanup 扫描 C 盘，先列出候选文件，不要移动或删除。
```

更换磁盘：

```text
使用 $windows-drive-cleanup 扫描 D 盘，找出可以移动的大文件。
```

扫描完成后，Codex 会列出类似 `D0001`、`M0001` 的编号。检查路径和风险说明后，再明确批准：

```text
同意把 M0001 和 M0003 移动到 E:\Drive-quarantine；同意将 D0002 放入回收站。
```

没有明确批准编号时，技能不应执行任何移动或删除操作。

## 手动运行扫描脚本

扫描 C 盘并把报告保存到当前目录：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\scan-drive.ps1 `
  -DriveRoot C:\ `
  -OutputDirectory .\drive-audit
```

扫描其他磁盘：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\scan-drive.ps1 `
  -DriveRoot D:\ `
  -OutputDirectory .\drive-audit
```

可调整的参数：

- `TempMinimumAgeDays`：临时文件最小保留天数，默认 14 天。
- `UserFileMinimumAgeDays`：个人大文件最小未修改天数，默认 30 天。
- `MoveMinimumBytes`：移动候选的最小体积，默认 256 MiB。
- `SkipUserContentScan`：只检查低风险临时目录，跳过个人大文件扫描，可用于快速测试。
- `MaxCandidates`：扫描过程中保留的最大候选数量，默认 5000，并始终保留体积最大的文件；设为 `0` 可返回全部候选，但会增加内存和报告体积。
- `MaxScanSeconds`：最长扫描时间，默认 300 秒；超时表示磁盘尚未扫描完整，并会与输出数量截断分别标记。
- `AdditionalCloudRoot`：补充自定义云同步根目录，可重复传入。

扫描会生成：

- `drive-report.md`：适合人工阅读的报告。
- `drive-candidates.csv`：适合表格查看的清单。
- `drive-candidates.json`：执行脚本使用的不可随意修改的清单。

## 预览和执行

先预览，不修改文件：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\apply-approved.ps1 `
  -Manifest .\drive-audit\drive-candidates.json `
  -Ids "D0001, M0003" `
  -MoveRoot E:\Drive-quarantine
```

确认编号无误后执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\apply-approved.ps1 `
  -Manifest .\drive-audit\drive-candidates.json `
  -Ids "D0001, M0003" `
  -MoveRoot E:\Drive-quarantine `
  -Execute `
  -ConfirmToken CONFIRM
```

`move-review` 文件会保留原目录结构并移动到隔离目录。程序先复制文件并校验源文件和目标文件的 SHA-256，校验成功后使用 `Remove-Item` 永久移除原路径；这一步不进入回收站，但隔离目录保留已校验副本。`delete-low-risk` 文件会进入回收站。每次预览或执行都会在清单目录生成名称唯一的 `drive-operation-*.json`，可以根据 `path` 和 `destination` 字段核对或手动恢复文件。

## 安全说明

任何工具都无法证明任意文件被移动或删除后对所有软件“绝对没有影响”。本技能采用保守策略，只把有较强依据的内容列为候选，并要求逐项确认。完整判断规则见 [references/classification.md](references/classification.md)。

建议先查看报告、执行预览，再处理少量文件。不要修改 JSON 清单中的路径、大小、时间或哈希。

## 验证仓库

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\validate.ps1
```

该检查会验证仓库必要文件、PowerShell 语法和技能入口格式。
