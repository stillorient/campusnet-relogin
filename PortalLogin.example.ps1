#Requires -Version 5.1
# 复制为 PortalLogin.ps1 后编辑；个人文件已被 .gitignore 排除。
# 自定义认证优先于 Config.psd1 中的 PortalLoginUrl。

function Invoke-PortalLogin {
    param(
        [string]$RedirectUrl,
        $Config
    )

    # 在此填写本机浏览器开发者工具中捕获的登录请求。
    # 若需要 Cookie、User-Agent 或动态参数，请保留并按实际协议刷新它们。
    # 下面只有占位示例，不包含任何学校的已验证认证协议。
    #
    # $resp = Invoke-WebRequest -Uri 'https://portal.example.edu/login' `
    #     -Method Post -Body $Config.PortalLoginBody `
    #     -ContentType 'application/x-www-form-urlencoded' `
    #     -UseBasicParsing -TimeoutSec 15
    # return ($resp.Content -match 'success')
    #
    # $null：尚未配置，回退到 Config.psd1 中的通用请求。
    # $true / $false：已尝试自定义认证；主脚本仍以外网探测确认恢复。
    # 函数请只返回一个结果对象；其他诊断信息使用 Write-Host。
    return $null
}
