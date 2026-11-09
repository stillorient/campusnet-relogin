@{
    # 复制为 Config.psd1 后填写；个人文件已被 .gitignore 排除。
    # 任意一个 TCP 端点可连接即视为在线；请选当地可达的公网端点。
    TestTargets = @(
        @{ Host = '223.5.5.5';    Port = 443 }
        @{ Host = '119.29.29.29'; Port = 443 }
    )

    # 按需选择恢复方式；未填写的步骤跳过。
    # 1. 重启官方客户端。进程名不含 .exe，客户端需自行支持自动登录。
    ClientProcessName = ''
    ClientPath = ''

    # 2. 重连已有的 Wi-Fi 配置。查看方式：netsh wlan show profiles
    WifiProfileName = ''

    # 3. 通用 Portal 请求。自定义 PortalLogin.ps1 返回 $null 时才使用这里。
    # URL、字段名和成功标志必须来自实际登录请求；此处没有学校专用协议。
    PortalLoginUrl = ''
    PortalLoginMethod = 'POST'     # GET 或 POST
    PortalLoginBody = @{}          # @{ userName = 'YOUR_ACCOUNT'; pwd = 'YOUR_PASSWORD' }
    PortalLoginHeaders = @{}       # @{ Referer = 'https://portal.example.edu/' }
    PortalLoginSuccessPattern = '' # 例如 'success'；最终仍以外网探测为准。

    # 4. 需要手动操作时打开认证页。此动作需要已登录的交互式桌面。
    PortalLoginPageUrl = ''

    # 5. 最后尝试重启指定网卡；默认关闭，需要时显式启用并填写网卡名。
    RestartAdapterLast = $false
    RestartAdapterName = ''       # Get-NetAdapter | Select-Object Name, Status

    PortalLoginAttempts = 3
    PortalLoginRetryDelaySeconds = 5
    OnlineCheckAfterLoginSeconds = 4
}
