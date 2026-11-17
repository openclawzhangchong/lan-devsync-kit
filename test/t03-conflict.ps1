# t03 冲突检测：两台机器改同一行 → devsync 必须明确报错而不是谎报成功
. (Join-Path $PSScriptRoot '_lib.ps1')
Write-TLog '=== t03 冲突检测测试 ==='

$stamp = Get-Date -Format 'HHmmss'
$base = Join-Path $env:TEMP "devsync-test-$stamp"
$repo = 'demo'
$A = Join-Path $base 'A'
$B = Join-Path $base 'B'
@($base, $A, $B) | ForEach-Object { New-Item -ItemType Directory -Path $_ -Force | Out-Null }

try {
  # 前置清理：确保同名测试仓库不存在
  Remove-HubRepo $repo

  $projA = Join-Path $A $repo
  New-Item -ItemType Directory -Path $projA -Force | Out-Null
  Set-Content (Join-Path $projA 'app.js') "console.log('v1')"
  Invoke-Devsync init $projA | Out-Null

  $projB = Join-Path $B $repo
  Invoke-Devsync clone $repo $projB | Out-Null

  # B机改第一行并推送
  Set-Content (Join-Path $projB 'app.js') "console.log('v2-B')"
  Invoke-Devsync save $projB -Msg 'B改第一行' | Out-Null

  # A机也改第一行（已提交状态）→ save 必须失败并给出冲突指引
  Set-Content (Join-Path $projA 'app.js') "console.log('v2-A')"
  $rc = Invoke-Devsync save $projA -Msg 'A改第一行'
  Assert-Eq 'A机 save 因冲突失败(退出码非0)' ($rc -ne 0) 'True'
  $logText1 = Get-SuiteLog
  Assert-True '机器可读结果行为 CONFLICT' ($logText1 -match 'RESULT: CONFLICT')

  # 防呆验证：冲突态下再跑 save 必须被拒绝并给指引（显式传目录，文本从套件日志取）
  Invoke-Devsync save $projA -Msg '再试一次' | Out-Null
  $logText = Get-SuiteLog
  Assert-True '冲突态再save被拒绝(CONFLICT)' ($logText -match 'RESULT: CONFLICT')
} finally {
  Write-TLog '清理测试现场...'
  # 中止可能的进行中 rebase 再清理
  & git -C $projA rebase --abort 2>$null | Out-Null
  Remove-HubRepo $repo
  Remove-ProjectRegistrations $base
  Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
}
Save-TestReport 't03-conflict'
