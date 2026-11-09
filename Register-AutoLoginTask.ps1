#Requires -Version 5.1
<#
    注册 / 删除「校园网断网自动恢复」计划任务

    必须以管理员身份运行 PowerShell。

    注册：
        powershell -ExecutionPolicy Bypass -File .\Register-AutoLoginTask.ps1
        # 一并关掉睡眠、并在 3:55 唤醒电脑（推荐，怕 4 点电脑睡着）
        powershell -ExecutionPolicy Bypass -File .\Register-AutoLoginTask.ps1 -DisableSleep -WakeBefore4AM

    删除：
        powershell -ExecutionPolicy Bypass -File .\Register-AutoLoginTask.ps1 -Remove

    默认触发器：
      1) 网络断开事件（Microsoft-Windows-NetworkProfile/Operational 事件 10001）
      2) 开机时
      3) 当前用户登录时
      4) 每 N 分钟兜底一次（默认 2 分钟）
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'CampusNet-AutoLogin-Watchdog',
    [ValidateRange(1, 1440)][int]$RepeatMinutes = 2,

    # Interactive：用户已登录即可，锁屏仍可运行；S4U 有网络访问限制。
    [ValidateSet('S4U', 'Interactive')][string]$LogonType = 'Interactive',

    # 关掉交流电下的睡眠/休眠
    [switch]$DisableSleep,

    # 每天 03:55 唤醒电脑并跑一次（配合 -DisableSleep 更保险）
    [switch]$WakeBefore4AM,
    [string]$WakeTime = '03:55',

    # 顺便关掉网卡的省电关闭（填网卡名，例如 '以太网'）
    [string]$AdapterName = '',

    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host '请以【管理员身份】运行 PowerShell 后再执行本脚本。' -ForegroundColor Red
    exit 1
}

if ($Remove) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "已删除计划任务：$TaskName"
    exit 0
}

$scriptPath = Join-Path $PSScriptRoot 'CampusNetAutoLogin.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) {
    Write-Host "找不到 $scriptPath" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Config.psd1'))) {
    Write-Host '请先将 Config.example.psd1 复制为 Config.psd1 并填写配置。' -ForegroundColor Red
    exit 1
}

$userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
if ($LogonType -eq 'S4U') {
    Write-Warning 'S4U 有网络访问限制且不提供交互式桌面，请实际验证认证；一般建议使用默认 Interactive。'
}

# ---------------- 动作 ----------------
$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath) `
    -WorkingDirectory $PSScriptRoot

# ---------------- 触发器 ----------------
$triggers = @()

# 1) 网络断开事件
$evtClass = Get-CimClass -Namespace Root/Microsoft/Windows/TaskScheduler -ClassName MSFT_TaskEventTrigger
$evtTrigger = New-CimInstance -CimClass $evtClass -ClientOnly
$evtTrigger.Enabled = $true
$evtTrigger.Subscription = @'
<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[EventID=10001]]</Select></Query></QueryList>
'@
$triggers += $evtTrigger

# 2) 开机
$triggers += New-ScheduledTaskTrigger -AtStartup

# 3) 登录；Interactive 身份在开机尚未登录时无法运行，因此单独监听登录。
$triggers += New-ScheduledTaskTrigger -AtLogOn -User $userId

# 4) 每 N 分钟兜底；省略 Duration 表示无限重复，避免 MaxValue 的兼容问题。
$triggers += New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes $RepeatMinutes)

# 5) 可选：每天固定时间唤醒
if ($WakeBefore4AM) {
    try {
        $wakeAt = [datetime]::ParseExact($WakeTime, 'HH:mm', $null)
    }
    catch {
        Write-Host "WakeTime 格式不对，应为 HH:mm，例如 03:55" -ForegroundColor Red
        exit 1
    }
    $triggers += New-ScheduledTaskTrigger -Daily -At $wakeAt
}

# ---------------- 设置 ----------------
$settingsParams = @{
    AllowStartIfOnBatteries    = $true
    DontStopIfGoingOnBatteries = $true
    StartWhenAvailable         = $true
    ExecutionTimeLimit         = [TimeSpan]::Zero
    MultipleInstances          = 'IgnoreNew'
    RestartCount               = 3
    RestartInterval            = (New-TimeSpan -Minutes 1)
}
if ($WakeBefore4AM) { $settingsParams['WakeToRun'] = $true }
$settings = New-ScheduledTaskSettingsSet @settingsParams

# ---------------- 运行身份 ----------------
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType $LogonType -RunLevel Highest

# ---------------- 注册 ----------------
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
    -Settings $settings -Principal $principal -Force | Out-Null

Write-Host "已注册计划任务：$TaskName" -ForegroundColor Green
Write-Host ("  运行身份：{0}（LogonType={1}，最高权限）" -f $userId, $LogonType)
Write-Host ("  触发器：网络断开(10001) / 开机 / 登录 / 每 {0} 分钟" -f $RepeatMinutes)
if ($WakeBefore4AM) { Write-Host ("  额外：每天 {0} 唤醒电脑" -f $WakeTime) }
Write-Host ''
Write-Host '验证：' -ForegroundColor Cyan
Write-Host ("  Get-ScheduledTask -TaskName '{0}' | Get-ScheduledTaskInfo" -f $TaskName)
Write-Host ("  Start-ScheduledTask -TaskName '{0}'" -f $TaskName)
Write-Host ("  Get-Content `"$env:LOCALAPPDATA\CampusNetAutoLogin\autologin.log`" -Tail 30")

# ---------------- 可选的省电设置 ----------------
if ($DisableSleep) {
    powercfg /change standby-timeout-ac 0  | Out-Null
    powercfg /change hibernate-timeout-ac 0 | Out-Null
    Write-Host '已关闭交流电下的睡眠与休眠。' -ForegroundColor Green
}

if ($AdapterName) {
    try {
        Set-NetAdapterPowerManagement -Name $AdapterName -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop
        Write-Host ("已关闭网卡省电：{0}" -f $AdapterName) -ForegroundColor Green
    }
    catch {
        Write-Host ("关闭网卡省电失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}
