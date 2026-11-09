# campusnet-relogin

Windows 校园网断线检查与自动恢复脚本，使用系统自带的 PowerShell 和任务计划程序，无需安装额外运行库。

## 背景与用途

CPU 校园网凌晨 4 点附近会断电，于是我写了这个校园网自动重连工具，让放在工位的电脑也能自动重连到校园网，方便需要持续联网的自动化任务和远程桌面等应用在网络恢复后继续使用。

本仓库整理了当时的通用恢复框架。公开配置全部使用空值或占位示例，使用前需要自行适配登录请求。它能在断线后尝试恢复。

## 工作方式

1. 依次探测配置中的公网 TCP 端点，任意一个可连接即视为在线；正常在线时直接退出。
2. 检测到离线后，尝试获取 Portal 重定向地址。
3. 按配置依次尝试重启官方客户端、重连 Wi-Fi、发送 Portal 认证请求。
4. 仍未恢复时，可打开认证页供手动操作，或按需重启指定网卡。
5. 再次探测网络，通过后记录 `[OK]`；否则返回失败，等待下一次任务触发。

TCP 探测通过只代表指定端点可连接，无法保证所有网站、DNS 和业务连接都正常。若认证前也能访问探测端点，请更换为其他公网端点。

## 文件说明

| 文件 | 用途 | 提交到 Git |
| --- | --- | --- |
| `CampusNetAutoLogin.ps1` | 单次检查与恢复；重复运行由计划任务负责 | 是 |
| `Register-AutoLoginTask.ps1` | 注册、更新或删除计划任务 | 是 |
| `Config.example.psd1` | 公开配置示例 | 是 |
| `PortalLogin.example.ps1` | 自定义认证函数示例 | 是 |
| `Config.psd1` | 本机配置，可含账号密码 | 否，已忽略 |
| `PortalLogin.ps1` | 本机实际登录请求，可含 Cookie、令牌等 | 否，已忽略 |
| `Tests/Autologin.Tests.ps1` | 隔离网络和等待操作的回归测试 | 是 |

运行日志位于 `%LOCALAPPDATA%\CampusNetAutoLogin\autologin.log`。超过 1 MB 时保留一份 `.1` 备份。内置认证逻辑只记录 HTTP 状态，不记录响应正文或 Portal URL；自定义函数也应避免打印凭据。

## 环境要求

- Windows 10 / 11，Windows PowerShell 5.1。
- 注册任务、重启网卡或修改省电设置需要管理员权限。
- 默认任务使用当前用户的交互式登录身份：已登录后锁屏可继续运行，注销后不可运行。
- 自定义认证所需的动态参数、验证码或加密算法需要自行适配。

## 快速开始

在项目目录打开 PowerShell。首次使用时复制示例；已有个人配置时直接编辑，避免覆盖。

```powershell
Copy-Item .\Config.example.psd1 .\Config.psd1
notepad .\Config.psd1
```

按需配置一种或多种恢复方式：

| 配置项 | 说明 |
| --- | --- |
| `TestTargets` | 探测端点的 `Host` 与 `Port`，默认使用两个公网 IP 的 443 端口 |
| `ClientProcessName` / `ClientPath` | 官方客户端进程名与路径，客户端需自行支持自动登录 |
| `WifiProfileName` | 已保存的 Wi-Fi 配置名，有线连接留空 |
| `PortalLoginUrl` / `PortalLoginBody` / `PortalLoginHeaders` | 从真实登录请求填写的地址、请求体与请求头 |
| `PortalLoginSuccessPattern` | 可选响应正则；最终仍以外网探测为准 |
| `PortalLoginPageUrl` | 失败后打开的认证页，需要交互式桌面，可能仍需手动登录 |
| `RestartAdapterLast` / `RestartAdapterName` | 网卡重启兜底，公开示例默认关闭 |

查看网卡与无线配置：

```powershell
Get-NetAdapter | Select-Object Name, InterfaceDescription, Status
netsh wlan show profiles
```

先手动检查一次：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CampusNetAutoLogin.ps1
Get-Content "$env:LOCALAPPDATA\CampusNetAutoLogin\autologin.log" -Tail 40
```

“网络正常，无需处理”表示当前探测通过，不能证明自动认证已经配置成功。

## 适配网页 Portal 登录

简单的 GET / POST 可直接填写 `Config.psd1`。需要自定义会话、动态参数或额外计算时，再复制登录函数示例：

```powershell
Copy-Item .\PortalLogin.example.ps1 .\PortalLogin.ps1
notepad .\PortalLogin.ps1
```

在本机浏览器开发者工具的 Network 面板中保留登录过程，定位登录请求，并参考其 URL、方法、请求头和请求体填写配置或自定义函数。若浏览器提供复制为 PowerShell，可用它辅助适配。

Cookie、User-Agent、时间戳、挑战值等可能参与认证；抓取的请求未必能长期重放。密码、Cookie 和令牌只保存在被忽略的个人文件中。

`Invoke-PortalLogin` 的返回值约定：

| 返回值 | 主脚本行为 |
| --- | --- |
| `$null` | 未配置自定义认证，回退到 `Config.psd1` 中的通用请求 |
| `$true` 或 `$false` | 已执行自定义认证，本次不再发送通用请求；随后重新探测外网 |

函数只返回一个结果，诊断信息可用 `Write-Host`。HTTP 200 或函数返回 `$true` 都不能替代网络复检。

`-Force` 会跳过最初的在线检查，可能重启客户端或触发其他恢复动作。后续步骤仍会复检网络并提前退出，因此它也不能单独证明重新认证成功。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CampusNetAutoLogin.ps1 -Force
```

## 注册计划任务

用当前 Windows 用户提升权限打开管理员 PowerShell，在项目目录执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Register-AutoLoginTask.ps1
```

任务默认名为 `CampusNet-AutoLogin-Watchdog`，再次注册会更新同名任务。任务记录脚本的绝对路径，移动项目目录后需要重新注册；修改本机配置无需重新注册。

| 触发条件 | 作用 |
| --- | --- |
| NetworkProfile 事件 10001 | 网络配置文件断开时检查；Portal 失效不一定产生该事件 |
| Windows 启动 | 身份允许时检查；默认身份仍需用户已登录 |
| 当前用户登录 | 登录后检查 |
| 每 2 分钟 | 持续兜底检查；可用 `-RepeatMinutes 5` 等调整 |
| 每天 03:55，可选 | 配合 `-WakeBefore4AM` 请求唤醒并检查 |

默认使用 `Interactive` 身份。保留 `-LogonType S4U` 兼容旧用法，但微软文档说明 S4U 存在网络访问限制且运行于非交互式桌面，不能假定网页认证和图形客户端都可用。[登录身份文档](https://learn.microsoft.com/en-us/windows/win32/api/taskschd/ne-taskschd-task_logon_type)

需要注销后运行时，可在任务计划程序中手动配置“无论用户是否登录都运行”，按 Windows 要求提供账户凭据，并在该身份下实际验证登录；这里的脚本不保存 Windows 登录密码。

定时重复采用省略持续时间的方式表示无限重复。[重复持续时间文档](https://learn.microsoft.com/en-us/windows/win32/taskschd/taskschedulerschema-duration-repetitiontype-element)

### 按需处理睡眠和网卡省电

睡眠会影响任务执行，唤醒还取决于硬件和电源策略。需要电脑夜间保持可运行时，可执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Register-AutoLoginTask.ps1 -DisableSleep -WakeBefore4AM -AdapterName '以太网'
```

- `-DisableSleep` 关闭接通电源时的睡眠与休眠超时，不修改电池模式。
- `-WakeBefore4AM` 设置每天 03:55 的唤醒任务，可用 `-WakeTime '03:50'` 调整；这不是 4 点强制重新登录。
- `-AdapterName` 尝试禁止系统为省电关闭指定网卡，需驱动支持。

删除任务不会还原这些电源设置。若曾修改，请按自己的需求在 Windows 电源设置和网卡属性中恢复。

## 查看、暂停、恢复与卸载

```powershell
# 查看任务与上次结果
Get-ScheduledTask -TaskName 'CampusNet-AutoLogin-Watchdog'
Get-ScheduledTask -TaskName 'CampusNet-AutoLogin-Watchdog' | Get-ScheduledTaskInfo

# 暂停后续触发，并停止当前可能正在执行的实例
Disable-ScheduledTask -TaskName 'CampusNet-AutoLogin-Watchdog'
Stop-ScheduledTask -TaskName 'CampusNet-AutoLogin-Watchdog'

# 恢复后续触发
Enable-ScheduledTask -TaskName 'CampusNet-AutoLogin-Watchdog'

# 立即运行一次
Start-ScheduledTask -TaskName 'CampusNet-AutoLogin-Watchdog'

# 删除任务；保留本机配置与日志
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Register-AutoLoginTask.ps1 -Remove
```

如使用了自定义 `-TaskName`，查看、启停和删除时也要使用同一名称。

## 验证与排错

在可接受暂时断网的时段，手动断开再恢复网络，观察兜底检查是否执行。次日查看凌晨 4 点附近的日志，确认是否存在“检测到断网 → 执行恢复动作 → `[OK]`”的完整过程。只有“网络正常”记录时，不能将联网归因于脚本。

| 现象 | 检查方向 |
| --- | --- |
| 找不到配置文件 | 先复制并填写 `Config.example.psd1` |
| 未配置任何自动认证方式 | 填写通用请求或自定义函数，公开示例默认不执行认证 |
| 认证响应成功但仍离线 | 检查实际协议、动态字段和探测端点 |
| 没有 Portal 重定向 | 可能没有 HTTP 重定向或网络链路尚未恢复，继续检查其他步骤 |
| 凌晨没有运行日志 | 检查任务是否启用、用户是否登录、电脑是否睡眠以及任务结果 |
| 上次任务结果 0x1 | 脚本结束时仍离线，查看该次日志 |
| 上次任务结果 0x2 | 本机配置缺失或无法解析 |
| 中文乱码 | `.ps1` / `.psd1` 保持 UTF-8 带 BOM，兼容 Windows PowerShell 5.1 |

退出码：`0` 表示探测通过，`1` 表示仍未恢复，`2` 表示配置读取失败。

### 开发验证

使用 Windows PowerShell 5.1 与 Pester 3.4 / 4：

```powershell
Import-Module Pester -MaximumVersion 4.99 -ErrorAction Stop
$result = Invoke-Pester -Script .\Tests\Autologin.Tests.ps1 -PassThru
if ($result.FailedCount -gt 0) { throw '回归测试失败' }
```

测试隔离 TCP、HTTP 和等待操作，日志写入临时测试目录。覆盖认证回退、自定义函数优先级、真实连通性判定、配置错误和日志凭据保护；不注册计划任务或修改真实网卡。真实校园网认证、唤醒及任务调度仍需在部署机器上验证。

## 发布到 GitHub

`.gitignore` 已排除个人配置、抓包和常见运行输出。提交前检查暂存内容，尤其确认没有复制到其他文件里的账号、密码、Cookie 或令牌。Git 忽略规则不会自动移除已经被跟踪的文件。

在项目目录执行；如果已有本地仓库，可跳过初始化：

```powershell
git init -b main
git add .
git status --short
git diff --cached
# 确认暂存内容后提交
git commit -m "Initial public release"
```

在 GitHub 创建空仓库，把下面的 `YOUR_NAME` 替换为自己的账户后推送：

```powershell
git remote add origin https://github.com/YOUR_NAME/campusnet-relogin.git
git push -u origin main
```

## 许可证

[MIT](LICENSE)
