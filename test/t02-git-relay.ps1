# t02 三机接力：A机init→B机clone改→A机sync收到B的成果→C机take接手
. (Join-Path $PSScriptRoot '_lib.ps1')
Write-TLog '=== t02 三机接力测试 ==='

$stamp = Get-Date -Format 'HHmmss'
$base = Join-Path $env:TEMP "devsync-test-$stamp"
$repo = 'demo'   # init 用目录名作为仓库名，这里保持一致
$A = Join-Path $base 'machineA'
$B = Join-Path $base 'machineB'
$C = Join-Path $base 'machineC'
@($base, $A, $B, $C) | ForEach-Object { New-Item -ItemType Directory -Path $_ -Force | Out-Null }

try {
  # 前置清理：确保同名测试仓库不存在（历史失败运行可能留下带提交的仓库）
  Remove-HubRepo $repo

  # 机器A：创建项目并接入枢纽（仓库自动按目录名 demo 创建）
  $projA = Join-Path $A $repo
  New-Item -ItemType Directory -Path $projA -Force | Out-Null
  Set-Content (Join-Path $projA 'app.js') "console.log('v1-A')"
  $rc = Invoke-Devsync init $projA
  Assert-Eq 'A机 init 推送成功' $rc 0

  # 机器B：克隆→改→save（save 显式传目录，模拟"在项目目录里执行"）
  $projB = Join-Path $B $repo
  $rc = Invoke-Devsync clone $repo $projB
  Assert-Eq 'B机 clone 成功' $rc 0
  Add-Content (Join-Path $projB 'app.js') "// B优化"
  $rc = Invoke-Devsync save $projB -Msg 'B机: v2'
  Assert-Eq 'B机 save 推送成功' $rc 0

  # 机器A：sync 拿到 B 的成果（核心场景：无需重新克隆）
  $rc = Invoke-Devsync sync $projA
  Assert-Eq 'A机 sync 成功' $rc 0
  $aContent = Get-Content (Join-Path $projA 'app.js') -Raw
  Assert-True 'A机已收到B机的优化内容' ($aContent -match 'B优化')

  # 机器C：take 一键接手
  $projC = Join-Path $C $repo
  $rc = Invoke-Devsync take $repo $projC
  Assert-Eq 'C机 take 接手成功' $rc 0
  $cContent = Get-Content (Join-Path $projC 'app.js') -Raw
  Assert-True 'C机拿到全部两轮优化' ($cContent -match 'v1-A' -and $cContent -match 'B优化')

  # 登记状态可见（文本从套件日志读取）
  Invoke-Devsync status | Out-Null
  $statusText = Get-SuiteLog
  Assert-True 'status 能看到接力项目' ($statusText -match '\[demo\]')
} finally {
  Write-TLog '清理测试现场...'
  Remove-HubRepo $repo
  Remove-ProjectRegistrations $base
  Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
  Write-TLog '清理完成'
}
Save-TestReport 't02-git-relay'
