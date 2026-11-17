# t01 枢纽健康检查：服务/端口/认证/防火墙规则
. (Join-Path $PSScriptRoot '_lib.ps1')
Write-TLog '=== t01 枢纽健康检查 ==='

$svc = (Get-Service DevSyncGitea -ErrorAction SilentlyContinue).Status
Assert-Eq 'Windows服务 DevSyncGitea 状态' "$svc" 'Running'

$listen = Get-NetTCPConnection -LocalPort 3300 -State Listen -ErrorAction SilentlyContinue
Assert-True '端口3300监听中' ($null -ne $listen)

$ver = Invoke-RestMethod -Uri "$($script:HUB)/api/v1/version" -TimeoutSec 10
Write-TLog "Gitea 版本: $($ver.version)"
Assert-True 'Gitea API 可访问' ($ver.version -match '^\d')

$tok = Get-TokenPlain
$me = Invoke-RestMethod -Uri "$($script:HUB)/api/v1/user" -Headers @{ Authorization = "token $tok" } -TimeoutSec 10
Assert-Eq '令牌认证用户' $me.login 'dev'

$fw = netsh advfirewall firewall show rule name="DevSync Gitea 3300" 2>$null | Out-String
Assert-True '防火墙规则存在(仅限本网段)' ($fw -match '192\.168\.168\.0/24')

Save-TestReport 't01-hub-health'
