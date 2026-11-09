#Requires -Version 5.1
# Run with Windows PowerShell's bundled Pester 3.4 or Pester 4.
$projectRoot = Split-Path -Parent $PSScriptRoot

Describe 'Campus network recovery' {
    BeforeEach {
        $script:previousLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $global:CampusTestOnline = $false
        $configPath = Join-Path $TestDrive 'Config.psd1'
        @'
@{
    TestTargets = @(@{ Host = '127.0.0.1'; Port = 1 })
    PortalLoginUrl = 'https://portal.example.invalid/login'
    PortalLoginMethod = 'POST'
    PortalLoginBody = @{ userName = 'example'; pwd = 'EXAMPLE_SECRET' }
    PortalLoginSuccessPattern = 'success'
    PortalLoginAttempts = 1
    PortalLoginRetryDelaySeconds = 1
    OnlineCheckAfterLoginSeconds = 1
}
'@ | Set-Content -LiteralPath $configPath -Encoding UTF8

        # Replace OS/network boundaries; exercise the real script and config loader.
        Mock New-Object {
            $client = [pscustomobject]@{ Connected = $global:CampusTestOnline }
            $client | Add-Member ScriptMethod BeginConnect {
                [pscustomobject]@{ AsyncWaitHandle = [System.Threading.ManualResetEvent]::new($true) }
            }
            $client | Add-Member ScriptMethod EndConnect { }
            $client | Add-Member ScriptMethod Close { }
            $client
        } -ParameterFilter { $TypeName -eq 'System.Net.Sockets.TcpClient' }
        Mock Start-Sleep { }
        Mock Invoke-WebRequest {
            if ($Method -eq 'Post') {
                $global:CampusTestOnline = $true
                return [pscustomobject]@{
                    StatusCode = 200
                    Content = '{"success":true,"token":"RESPONSE_SECRET"}'
                }
            }
            [pscustomobject]@{ StatusCode = 204; Content = '' }
        }
    }

    AfterEach {
        $env:LOCALAPPDATA = $script:previousLocalAppData
        Remove-Variable CampusTestOnline -Scope Global -ErrorAction SilentlyContinue
    }

    It 'falls back to the configured login request when the hook is unconfigured' {
        $exampleHook = Join-Path $projectRoot 'PortalLogin.example.ps1'
        if (-not (Test-Path -LiteralPath $exampleHook)) {
            $exampleHook = Join-Path $projectRoot 'PortalLogin.ps1'
        }
        & (Join-Path $projectRoot 'CampusNetAutoLogin.ps1') -ConfigPath $configPath -LoginHookPath $exampleHook

        $LASTEXITCODE | Should Be 0
        Assert-MockCalled Invoke-WebRequest -Scope It -Times 1 -Exactly -ParameterFilter { $Method -eq 'Post' }
    }

    It 'keeps credentials and authentication responses out of its log' {
        & (Join-Path $projectRoot 'CampusNetAutoLogin.ps1') -ConfigPath $configPath -LoginHookPath (Join-Path $TestDrive 'missing-hook.ps1')

        $log = Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'CampusNetAutoLogin\autologin.log') -Raw
        $log | Should Not Match 'EXAMPLE_SECRET|RESPONSE_SECRET'
        $LASTEXITCODE | Should Be 0
    }

    It 'uses a configured custom hook before the generic request' {
        $customHook = Join-Path $TestDrive 'custom-hook.ps1'
        @'
function Invoke-PortalLogin {
    param($RedirectUrl, $Config)
    $null = Invoke-WebRequest -Uri 'https://custom.example.invalid/login' -Method Post
    return $true
}
'@ | Set-Content -LiteralPath $customHook -Encoding UTF8

        & (Join-Path $projectRoot 'CampusNetAutoLogin.ps1') -ConfigPath $configPath -LoginHookPath $customHook

        $LASTEXITCODE | Should Be 0
        Assert-MockCalled Invoke-WebRequest -Scope It -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://custom.example.invalid/login' }
        Assert-MockCalled Invoke-WebRequest -Scope It -Times 0 -Exactly -ParameterFilter { $Uri -eq 'https://portal.example.invalid/login' }
    }

    It 'reports failure when HTTP succeeds but the network is still offline' {
        Mock Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = 200; Content = '{"success":true}' }
        }

        & (Join-Path $projectRoot 'CampusNetAutoLogin.ps1') -ConfigPath $configPath -LoginHookPath (Join-Path $TestDrive 'missing-hook.ps1')

        $LASTEXITCODE | Should Be 1
        $log = Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'CampusNetAutoLogin\autologin.log') -Raw
        $log | Should Not Match '\[OK\]'
    }

    It 'leaves an already online connection alone' {
        $global:CampusTestOnline = $true

        & (Join-Path $projectRoot 'CampusNetAutoLogin.ps1') -ConfigPath $configPath

        $LASTEXITCODE | Should Be 0
        Assert-MockCalled Invoke-WebRequest -Scope It -Times 0 -Exactly
    }

    It 'rejects a missing config without sending a request' {
        & (Join-Path $projectRoot 'CampusNetAutoLogin.ps1') -ConfigPath (Join-Path $TestDrive 'missing-config.psd1')

        $LASTEXITCODE | Should Be 2
        Assert-MockCalled Invoke-WebRequest -Scope It -Times 0 -Exactly
    }

    It 'does not expose a credential in a config parse error' {
        "@{ pwd = 'PARSE_SECRET'" | Set-Content -LiteralPath $configPath -Encoding UTF8

        & (Join-Path $projectRoot 'CampusNetAutoLogin.ps1') -ConfigPath $configPath

        $LASTEXITCODE | Should Be 2
        $log = Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'CampusNetAutoLogin\autologin.log') -Raw
        $log | Should Not Match 'PARSE_SECRET'
        Assert-MockCalled Invoke-WebRequest -Scope It -Times 0 -Exactly
    }

    It 'does not expose credentials carried in an HTTP exception' {
        Mock Invoke-WebRequest { throw 'https://portal.example.invalid/login?pwd=EXCEPTION_SECRET' } -ParameterFilter { $Method -eq 'Post' }

        & (Join-Path $projectRoot 'CampusNetAutoLogin.ps1') -ConfigPath $configPath -LoginHookPath (Join-Path $TestDrive 'missing-hook.ps1')

        $LASTEXITCODE | Should Be 1
        $log = Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'CampusNetAutoLogin\autologin.log') -Raw
        $log | Should Not Match 'EXCEPTION_SECRET'
    }
}
