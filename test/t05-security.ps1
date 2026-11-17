# t05 安全测试：未认证拒绝 / 注册禁用 / 私库对外不可见 / 防火墙限制
. (Join-Path $PSScriptRoot '_lib.ps1')
Write-TLog '=== t05 安全测试 ==='

# 1. 无凭据克隆私有仓库必须失败（显式禁用 credential helper，模拟他人电脑）
$cloneDir = Join-Path $env:TEMP "sec-clone-$(Get-Date -Format 'HHmmss')"
& git -c credential.helper= clone "$($script:HUB)/dev/demo-app.git" $cloneDir 2>&1 | Out-Null
Assert-True '无凭据克隆私有仓库被拒绝' ($LASTEXITCODE -ne 0)
Remove-Item $cloneDir -Recurse -Force -ErrorAction SilentlyContinue

# 2. 无凭据 API 访问私有仓库 → 404(隐藏) 或 401(拒绝)
$code = 0
try { Invoke-RestMethod -Uri "$($script:HUB)/api/v1/repos/dev/demo-app" -TimeoutSec 10 | Out-Null }
catch { $code = [int]$_.Exception.Response.StatusCode }
Assert-True "无凭据API访问私库不可见(HTTP $code)" ($code -eq 404 -or $code -eq 401)

# 3. 带凭据访问同一私库 → 可见且私有
$tok = Get-TokenPlain
$repoInfo = Invoke-RestMethod -Uri "$($script:HUB)/api/v1/repos/dev/demo-app" -Headers @{ Authorization = "token $tok" } -TimeoutSec 10
Assert-Eq '带凭据访问私库可见且私有' $repoInfo.private 'True'

# 4. 注册已禁用：注册接口必须失败
$regCode = 0
try {
  Invoke-RestMethod -Uri "$($script:HUB)/api/v1/users/sign_up" -Method Post -ContentType 'application/json' -Body '{"username":"intruder","password":"TryPassw0rd123","email":"intruder@x.com"}' -TimeoutSec 10 | Out-Null
} catch { $regCode = [int]$_.Exception.Response.StatusCode }
Assert-True "注册接口被拒(HTTP $regCode)" ($regCode -ge 400)

# 5. 防火墙只放行本网段
$fw = netsh advfirewall firewall show rule name="DevSync Gitea 3300" 2>$null | Out-String
Assert-True '防火墙规则限制来源IP(仅本网段+回环)' ($fw -match '192\.168\.168\.0/24' -and $fw -match '127\.0\.0\.1')

Save-TestReport 't05-security'
