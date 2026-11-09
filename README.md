# campusnet-relogin

CPU 校园网凌晨 4 点附近会断电，于是我写了这个校园网自动重连工具，让放在工位的电脑也能自动重连到校园网，方便需要持续联网的自动化任务和远程桌面等应用在网络恢复后继续使用。

本仓库整理了当时的通用恢复框架。公开配置全部使用空值或占位示例，使用前需要自行适配登录请求。它能在断线后尝试恢复。

适用于 Windows 10 / 11，使用系统自带的 Windows PowerShell 5.1。

## 使用

复制并编辑本机配置（已有配置时直接编辑，避免覆盖）：

```powershell
Copy-Item .\Config.example.psd1 .\Config.psd1
notepad .\Config.psd1
```

填写官方客户端进程名与路径，或 Portal 登录地址、请求体和请求头。复杂认证可将 [PortalLogin.example.ps1](PortalLogin.example.ps1) 复制为 `PortalLogin.ps1`，填入实际登录请求。

先手动检查一次：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CampusNetAutoLogin.ps1
```

在项目目录打开**管理员 PowerShell**，注册自动重连任务：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Register-AutoLoginTask.ps1
```

默认每 2 分钟检查，并在断网、开机和登录时触发。用户需保持已登录（可锁屏），电脑需保持可运行。当前在线时直接退出；认证响应成功后仍会复检网络。

需要夜间保持运行时，注册命令可加 `-DisableSleep -WakeBefore4AM`，关闭接通电源时的睡眠与休眠超时，并请求每天 03:55 唤醒。移动项目目录后需重新注册任务。

## 管理

```powershell
# 查看日志
Get-Content "$env:LOCALAPPDATA\CampusNetAutoLogin\autologin.log" -Tail 20

# 暂停，并停止当前实例
Disable-ScheduledTask -TaskName 'CampusNet-AutoLogin-Watchdog'
Stop-ScheduledTask -TaskName 'CampusNet-AutoLogin-Watchdog'

# 恢复
Enable-ScheduledTask -TaskName 'CampusNet-AutoLogin-Watchdog'

# 卸载任务
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Register-AutoLoginTask.ps1 -Remove
```

卸载任务保留本机配置和日志，电源设置需自行恢复。编辑 `.ps1` / `.psd1` 时保持 UTF-8 带 BOM。

`Config.psd1`、`PortalLogin.ps1`、抓包和日志已由 `.gitignore` 排除；账号、密码和 Cookie 只放在本机配置中。

[MIT License](LICENSE)
