# ============================================================
# install-hub —— 枢纽机一键安装（Gitea + 服务 + 防火墙）
# 在枢纽机上以普通 PowerShell 执行（会自动静默提权做需要管理员的步骤）:
#   powershell -ExecutionPolicy Bypass -File install-hub.ps1 ^
#     -GiteaUrl https://dl.gitea.com/gitea/28.4.0/gitea-28.4.0-windows-amd64.exe ^
#     -ListenIp 192.168.168.199
# 产物:
#   E:\devsync\gitea\          程序与数据
#   E:\devsync\gitea-repos\    裸仓库存储
#   E:\devsync\secrets\        管理员凭据（本地保存，勿入库）
#   Windows 服务 DevSyncGitea（开机自启）
# ============================================================
param(
  [string]$GiteaUrl = 'https://dl.gitea.com/gitea/28.4.0/gitea-28.4.0-windows-amd64.exe',
  [string]$ListenIp = '192.168.168.199',
  [int]$Port = 3300,
  [string]$Root = 'E:\devsync'
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

Write-Host "[hub] DevSync 枢纽安装开始 (目标 $Root)" -ForegroundColor Cyan

# 0. 目录
$dirs = @("$Root\tools", "$Root\gitea\custom\conf", "$Root\gitea-repos", "$Root\logs", "$Root\secrets")
$dirs | ForEach-Object { if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null } }

# 1. 下载 Gitea
$exe = "$Root\gitea\gitea.exe"
if (-not (Test-Path $exe)) {
  Write-Host "[hub] 下载 Gitea: $GiteaUrl"
  Invoke-WebRequest -Uri $GiteaUrl -OutFile $exe -TimeoutSec 600
}
Write-Host "[hub] Gitea 版本: $((& $exe --version | Select-Object -First 1))"

# 2. NSSM
$nssm = "$Root\tools\nssm.exe"
if (-not (Test-Path $nssm)) {
  Write-Host '[hub] 下载 NSSM...'
  Invoke-WebRequest -Uri 'https://nssm.cc/release/nssm-2.24.zip' -OutFile "$Root\tools\nssm.zip" -TimeoutSec 120
  Expand-Archive "$Root\tools\nssm.zip" "$Root\tools\nssm-extract" -Force
  Copy-Item "$Root\tools\nssm-extract\nssm-2.24\win64\nssm.exe" $nssm -Force
}

# 3. app.ini（幂等：已存在则不覆盖）
$ini = "$Root\gitea\custom\conf\app.ini"
if (-not (Test-Path $ini)) {
  Write-Host '[hub] 生成 app.ini ...'
  $secret = -join ((1..64) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
  $tpl = Join-Path $PSScriptRoot 'app.ini.template'
  (Get-Content $tpl -Raw) -replace '@@SECRET@@', $secret -replace '@@ROOT@@', ($Root -replace '\\', '/') -replace '@@IP@@', $ListenIp -replace '@@PORT@@', "$Port" | Set-Content $ini -Encoding ASCII
}

# 4. 数据库迁移
Write-Host '[hub] 初始化数据库...'
& $exe migrate --config $ini | Out-Null

# 5. 管理员账号（已存在则跳过）
$credFile = "$Root\secrets\gitea-admin.txt"
if (-not (Test-Path $credFile)) {
  $chars = (48..57) + (65..90) + (97..122)
  $pass = -join (1..16 | ForEach-Object { [char]($chars | Get-Random) })
  & $exe admin user create --config $ini --admin --username dev --password $pass --email dev@local.lan --must-change-password=false | Out-Null
  Set-Content -Path $credFile -Encoding UTF8 -Value @"
DevSync Gitea 枢纽管理员
用户名: dev
密码: $pass
地址: http://$ListenIp`:$Port/
生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
注意: 此文件仅存于本机，请勿提交到任何仓库；建议登录后修改密码。
"@
  Write-Host "[hub] 管理员已创建，凭据保存在 $credFile"
} else {
  Write-Host '[hub] 管理员凭据已存在，跳过创建'
}

# 6. NSSM 服务（幂等）
& $nssm install DevSyncGitea $exe | Out-Null
& $nssm set DevSyncGitea AppParameters "web --config $ini" | Out-Null
& $nssm set DevSyncGitea AppDirectory "$Root\gitea" | Out-Null
& $nssm set DevSyncGitea AppStdout "$Root\logs\gitea-service.out.log" | Out-Null
& $nssm set DevSyncGitea AppStderr "$Root\logs\gitea-service.err.log" | Out-Null
& $nssm set DevSyncGitea AppRotateFiles 1 | Out-Null
& $nssm set DevSyncGitea Start SERVICE_AUTO_START | Out-Null

# 7. 需要管理员的步骤（防火墙 + 服务启动）→ 写成脚本后静默提权执行
$elevateScript = "$Root\tools\elevate-setup.ps1"
@"
`$ErrorActionPreference='Continue'
`$log='$Root\logs\elevate-setup.log'
"[$(Get-Date -Format o)] elevated setup started" | Out-File `$log -Encoding ascii
netsh advfirewall firewall delete rule name="DevSync Gitea $Port" | Out-Null
netsh advfirewall firewall add rule name="DevSync Gitea $Port" dir=in action=allow protocol=TCP localport=$Port remoteip=$ListenIp/24,127.0.0.1 | Out-File `$log -Append -Encoding ascii
Start-Service -Name 'DevSyncGitea' -ErrorAction Continue
"service: " + (Get-Service DevSyncGitea).Status | Out-File `$log -Append -Encoding ascii
Set-Service -Name 'DevSyncGitea' -StartupType Automatic
"done" | Out-File `$log -Append -Encoding ascii
"@ | Set-Content $elevateScript -Encoding ASCII

$runner = "$Root\tools\elevate-runner.ps1"
@"
Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$elevateScript'
"@ | Set-Content $runner -Encoding ASCII
Write-Host '[hub] 静默提权执行防火墙+服务启动 ...'
& powershell -NoProfile -ExecutionPolicy Bypass -File $runner

# 8. 验证
Start-Sleep 5
$state = (Get-Service DevSyncGitea).Status
$listening = (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) -ne $null
Write-Host "[hub] 服务状态: $state / 端口 ${Port}: $listening"
try {
  $code = (Invoke-WebRequest -Uri "http://127.0.0.1:$Port" -UseBasicParsing -MaximumRedirection 0 -ErrorAction SilentlyContinue).StatusCode
  Write-Host "[hub] HTTP 首页响应: $code (303=正常, 跳转登录页)"
} catch { Write-Host "[hub] HTTP 响应: $($_.Exception.Response.StatusCode.value__)" }
Write-Host ''
Write-Host '[hub] 安装完成! 接下来:' -ForegroundColor Green
Write-Host "  1. 浏览器打开 http://$ListenIp`:$Port 用 dev 登录（密码在 $credFile）"
Write-Host '  2. 头像->设置->应用->生成新令牌（repository 读写）'
Write-Host "  3. 本机执行: devsync setup -Hub http://$ListenIp`:$Port -User dev -Token <令牌>"
Write-Host '  4. 其他电脑执行 install\install-another-pc.ps1'
