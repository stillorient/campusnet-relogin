#Requires -Version 5.1
<#
    校园网断网自动恢复守护脚本（Windows / 网页 Portal 认证）

    用法：
        # 手动检查一次（在线时直接退出）
        powershell -ExecutionPolicy Bypass -File .\CampusNetAutoLogin.ps1

        # 跳过初次在线检查，用于排查（可能重启客户端等）
        powershell -ExecutionPolicy Bypass -File .\CampusNetAutoLogin.ps1 -Force

    日志：%LOCALAPPDATA%\CampusNetAutoLogin\autologin.log
#>
[CmdletBinding()]
param(
    [string]$ConfigPath    = (Join-Path $PSScriptRoot 'Config.psd1'),
    [string]$LoginHookPath = (Join-Path $PSScriptRoot 'PortalLogin.ps1'),
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- 日志
$script:LogDir  = Join-Path $env:LOCALAPPDATA 'CampusNetAutoLogin'
$script:LogFile = Join-Path $script:LogDir 'autologin.log'

if (-not (Test-Path -LiteralPath $script:LogDir)) {
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
}
# 日志超过 1MB 就轮转一次，避免无限增长
if ((Test-Path -LiteralPath $script:LogFile) -and
    (Get-Item -LiteralPath $script:LogFile).Length -gt 1MB) {
    Move-Item -LiteralPath $script:LogFile -Destination ($script:LogFile + '.1') -Force
}

function Write-Log {
    param(
        [Parameter(Position = 0)][string]$Message,
        [Parameter(Position = 1)][ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

# ---------------------------------------------------------------- 网络探测
function Test-TcpEndpoint {
    param(
        [Parameter(Mandatory)][string]$Target,
        [int]$Port = 443,
        [int]$TimeoutMs = 3000
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Target, $Port, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected) {
            $client.EndConnect($async)
            return $true
        }
        return $false
    }
    catch { return $false }
    finally { try { $client.Close() } catch { } }
}

function Test-Online {
    param($Targets)
    foreach ($t in $Targets) {
        $port = 443
        if ($t.ContainsKey('Port')) { $port = [int]$t.Port }
        if (Test-TcpEndpoint -Target ([string]$t.Host) -Port $port) { return $true }
    }
    return $false
}

# 未认证时，网关会把 HTTP 请求 302 到认证页；这里把那个地址取出来
function Get-PortalRedirectUrl {
    $probe = 'http://connect.rom.miui.com/generate_204'
    try {
        $null = Invoke-WebRequest -Uri $probe -MaximumRedirection 0 -TimeoutSec 6 -UseBasicParsing
        return $null          # 拿到 204/200，说明没被劫持
    }
    catch {
        $resp = $null
        try { $resp = $_.Exception.Response } catch { }
        if ($resp) {
            try {
                $code = [int]$resp.StatusCode
                if ($code -ge 300 -and $code -lt 400) {
                    $loc = $resp.Headers['Location']
                    if ($loc) { return [string]$loc }
                }
            }
            catch { }
        }
        return $null
    }
}

# ---------------------------------------------------------------- 认证动作
function Invoke-PortalLoginDefault {
    param($Config, [string]$RedirectUrl)

    $uri = [string]$Config.PortalLoginUrl
    if ([string]::IsNullOrWhiteSpace($uri)) { return $null }

    $headers = @{}
    if ($Config.PortalLoginHeaders) {
        foreach ($k in $Config.PortalLoginHeaders.Keys) {
            $headers[$k] = [string]$Config.PortalLoginHeaders[$k]
        }
    }
    $body = $Config.PortalLoginBody

    try {
        if ([string]$Config.PortalLoginMethod -eq 'GET') {
            $resp = Invoke-WebRequest -Uri $uri -Method Get -Headers $headers `
                -TimeoutSec 15 -UseBasicParsing
        }
        else {
            $resp = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $body `
                -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 15 -UseBasicParsing
        }
        $content = [string]$resp.Content
        # 响应正文可能带会话令牌或个人信息，只记录 HTTP 状态。
        Write-Log ("认证响应 HTTP {0}。" -f [int]$resp.StatusCode)

        if (-not [string]::IsNullOrWhiteSpace([string]$Config.PortalLoginSuccessPattern)) {
            return ($content -match [string]$Config.PortalLoginSuccessPattern)
        }
        return $true
    }
    catch {
        Write-Log ("认证请求失败（{0}），请在本机检查请求。" -f $_.Exception.GetType().Name) 'ERROR'
        return $false
    }
}

# 调用 PortalLogin.ps1 里定义的 Invoke-PortalLogin
function Invoke-LoginHook {
    param([string]$HookPath, [string]$RedirectUrl, $Config)

    if (-not (Test-Path -LiteralPath $HookPath)) { return $null }
    try {
        . $HookPath
    }
    catch {
        Write-Log ("加载登录钩子失败（{0}）。" -f $_.Exception.GetType().Name) 'ERROR'
        return $null
    }
    if (Get-Command -Name 'Invoke-PortalLogin' -ErrorAction SilentlyContinue) {
        try {
            return (Invoke-PortalLogin -RedirectUrl $RedirectUrl -Config $Config)
        }
        catch {
            Write-Log ("登录钩子执行出错（{0}）。" -f $_.Exception.GetType().Name) 'ERROR'
            return $false
        }
    }
    return $null
}

# ---------------------------------------------------------------- 主流程
Write-Log '==================== 开始检查 ===================='

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Log '找不到配置文件。请先将 Config.example.psd1 复制为 Config.psd1 并填写。' 'ERROR'
    exit 2
}

try {
    $cfg = Import-PowerShellDataFile -Path $ConfigPath -ErrorAction Stop
}
catch {
    Write-Log ("配置文件解析失败（{0}），请在本机检查文件。" -f $_.Exception.GetType().Name) 'ERROR'
    exit 2
}

$targets = $cfg.TestTargets
if (-not $targets) { $targets = @(@{ Host = '223.5.5.5'; Port = 443 }) }

if ((Test-Online -Targets $targets) -and -not $Force) {
    Write-Log '网络正常，无需处理。'
    exit 0
}
if ($Force) { Write-Log '指定了 -Force，跳过初次在线检查并进入恢复流程。' }
else { Write-Log '检测到断网。' 'WARN' }

# --- 先看看是不是被 Portal 拦截，顺便拿到认证页地址 ---
$redirectUrl = Get-PortalRedirectUrl
if ($redirectUrl) { Write-Log '检测到 Portal 重定向。' }
else { Write-Log '未捕获到 Portal 重定向（网关可能不做 HTTP 劫持，或已经没有网络层连接）。' 'WARN' }

# --- 步骤 1：重启学校客户端 ---
if (-not [string]::IsNullOrWhiteSpace([string]$cfg.ClientProcessName)) {
    Write-Log ("重启校园网客户端：{0}" -f $cfg.ClientProcessName)
    Get-Process -Name ([string]$cfg.ClientProcessName) -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not [string]::IsNullOrWhiteSpace([string]$cfg.ClientPath) -and
        (Test-Path -LiteralPath $cfg.ClientPath)) {
        Start-Process -FilePath $cfg.ClientPath -WindowStyle Hidden
        Start-Sleep -Seconds 15
    }
    if (Test-Online -Targets $targets) {
        Write-Log '客户端重启后网络已恢复。' 'OK'
        exit 0
    }
}

# --- 步骤 2：重连无线 ---
if (-not [string]::IsNullOrWhiteSpace([string]$cfg.WifiProfileName)) {
    Write-Log ("尝试重连无线：{0}" -f $cfg.WifiProfileName)
    try {
        & netsh wlan connect name="$([string]$cfg.WifiProfileName)" | Out-Null
    }
    catch { Write-Log ("netsh 重连失败：{0}" -f $_.Exception.Message) 'WARN' }
    Start-Sleep -Seconds 8
    if (Test-Online -Targets $targets) {
        Write-Log '无线重连成功。' 'OK'
        exit 0
    }
}

# --- 步骤 3：认证（钩子优先，其次配置里的通用请求）---
$attempts = 3
if ($cfg.PortalLoginAttempts) { $attempts = [int]$cfg.PortalLoginAttempts }
$delay = 5
if ($cfg.PortalLoginRetryDelaySeconds) { $delay = [int]$cfg.PortalLoginRetryDelaySeconds }

for ($i = 1; $i -le $attempts; $i++) {
    if (Test-Online -Targets $targets) { break }
    Write-Log ("第 {0}/{1} 次认证尝试" -f $i, $attempts)

    $hookResult = Invoke-LoginHook -HookPath $LoginHookPath -RedirectUrl $redirectUrl -Config $cfg
    if ($null -eq $hookResult) {
        $defaultResult = Invoke-PortalLoginDefault -Config $cfg -RedirectUrl $redirectUrl
        if ($null -eq $defaultResult) {
            Write-Log '未配置任何自动认证方式（Config.psd1 的 PortalLoginUrl 为空，PortalLogin.ps1 也没配置）。' 'WARN'
        }
    }
    else {
        Write-Log ("自定义认证返回：{0}" -f [bool]$hookResult)
    }

    Start-Sleep -Seconds $delay
}

if (Test-Online -Targets $targets) {
    Write-Log '网络已恢复。' 'OK'
    exit 0
}

# --- 步骤 4：兜底，打开认证页（配合浏览器记住密码，或等人手动点一下）---
if (-not [string]::IsNullOrWhiteSpace([string]$cfg.PortalLoginPageUrl)) {
    $page = [string]$cfg.PortalLoginPageUrl
    if ($redirectUrl -and $redirectUrl -match '^https?://') { $page = $redirectUrl }
    Write-Log '尝试打开认证页，需要已登录的交互式桌面。'
    try { Start-Process $page } catch { Write-Log ("打开认证页失败（{0}）。" -f $_.Exception.GetType().Name) 'WARN' }
    Start-Sleep -Seconds 5
}

# --- 步骤 5：最后手段，重启网卡 ---
if ($cfg.RestartAdapterLast -and -not [string]::IsNullOrWhiteSpace([string]$cfg.RestartAdapterName)) {
    Write-Log ("重启网卡：{0}" -f $cfg.RestartAdapterName)
    try {
        Restart-NetAdapter -Name ([string]$cfg.RestartAdapterName) -Confirm:$false
        Start-Sleep -Seconds 12
    }
    catch {
        Write-Log ("重启网卡失败（可能不是管理员）：{0}" -f $_.Exception.Message) 'ERROR'
    }
}

# --- 收尾复检 ---
$wait = 4
if ($cfg.OnlineCheckAfterLoginSeconds) { $wait = [int]$cfg.OnlineCheckAfterLoginSeconds }
Start-Sleep -Seconds $wait

if (Test-Online -Targets $targets) {
    Write-Log '网络已恢复。' 'OK'
    exit 0
}

Write-Log '仍未恢复，请检查配置或查看 PortalLogin.ps1 是否已填写。' 'ERROR'
exit 1
