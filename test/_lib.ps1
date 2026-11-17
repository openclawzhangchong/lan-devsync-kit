# 测试公共库：记录、断言、token 解密、devsync 调用
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}   # 子进程 devsync 输出 UTF-8，父进程必须用 UTF-8 解码
$script:TEST_LOG_DIR = Join-Path $PSScriptRoot '..\evidence'
if (-not (Test-Path $script:TEST_LOG_DIR)) { New-Item -ItemType Directory -Path $script:TEST_LOG_DIR -Force | Out-Null }
$script:TEST_RESULTS = New-Object System.Collections.Generic.List[string]
$script:HUB = 'http://192.168.168.199:3300'

function Write-TLog($m) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" }

# 套件日志：Invoke-Devsync 的输出双写（屏幕 + 文件），供文本断言读取
$script:SUITE_LOG = Join-Path $script:TEST_LOG_DIR 'suite-log.txt'
if (Test-Path $script:SUITE_LOG) { Remove-Item $script:SUITE_LOG -Force -ErrorAction SilentlyContinue }
function Get-SuiteLog { return (Get-Content $script:SUITE_LOG -Raw -Encoding UTF8 -ErrorAction SilentlyContinue) }

function Assert-Eq($name, $actual, $expected) {
  $a = "$actual"; $e = "$expected"
  if ($a -eq $e) {
    Write-TLog "PASS  $name (实际=$a)"
    $script:TEST_RESULTS.Add("PASS  $name") | Out-Null
    return $true
  } else {
    Write-TLog "FAIL  $name (期望=$e 实际=$a)"
    $script:TEST_RESULTS.Add("FAIL  $name (期望=$e 实际=$a)") | Out-Null
    return $false
  }
}
function Assert-True($name, $cond) { Assert-Eq $name ([bool]$cond) 'True' }

function Save-TestReport($suiteName) {
  $file = Join-Path $script:TEST_LOG_DIR "$suiteName.txt"
  $script:TEST_RESULTS | Set-Content $file -Encoding UTF8
  Write-TLog "结果已写入 $file"
}

# 调用已安装的 devsync；输出显示+落盘，返回退出码
function Invoke-Devsync {
  $ds = "$env:USERPROFILE\.devsync\bin\devsync.ps1"
  if (-not (Test-Path $ds)) { $ds = 'E:\devsync\bin\devsync.ps1' }
  $lines = & powershell -NoProfile -ExecutionPolicy Bypass -File $ds @args 2>&1
  foreach ($l in $lines) {
    $s = "$l"
    Write-Host $s
    Add-Content -Path $script:SUITE_LOG -Value $s -Encoding UTF8
  }
  return $LASTEXITCODE
}

# 解出 DPAPI 保护的令牌（纯 PowerShell，避免嵌套引号）
function Get-TokenPlain {
  $enc = (Get-Content "$env:USERPROFILE\.devsync\token.dpapi" -Raw).Trim()
  $sec = ConvertTo-SecureString $enc
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  $t = [Runtime.InteropServices.Marshal]::PtrToStringAuto($b)
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)
  return $t
}

# 从枢纽删除测试仓库
function Remove-HubRepo($repo) {
  $tok = Get-TokenPlain
  try {
    Invoke-RestMethod -Uri "$($script:HUB)/api/v1/repos/dev/$repo" -Method Delete -Headers @{ Authorization = "token $tok" } -TimeoutSec 15 | Out-Null
    Write-TLog "枢纽仓库 $repo 已删除"
  } catch { Write-TLog "删除枢纽仓库 $repo 失败(可忽略): $($_.Exception.Message)" }
}

# 从用户配置中移除登记路径在 $base 下的项目
function Remove-ProjectRegistrations($base) {
  $cfgPath = "$env:USERPROFILE\.devsync\config.json"
  $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
  $cfg.projects = @($cfg.projects | Where-Object { $_.path -and (-not $_.path.StartsWith($base)) })
  $cfg | ConvertTo-Json -Depth 5 | Set-Content $cfgPath -Encoding UTF8
}
