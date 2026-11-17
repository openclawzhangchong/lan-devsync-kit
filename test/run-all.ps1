# ============ DevSync 测试总入口 ============
# 用法: powershell -ExecutionPolicy Bypass -File run-all.ps1
# 按顺序跑 t01~t06，输出汇总到 evidence\test-summary.md
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$tests = @('t01-hub-health','t02-git-relay','t03-conflict','t04-secrets','t05-security','t06-doctor')
$results = @()
$sw = [Diagnostics.Stopwatch]::StartNew()

foreach ($t in $tests) {
  Write-Host ""
  Write-Host "########## $t ##########" -ForegroundColor Magenta
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "$t.ps1") 2>&1
  $out | ForEach-Object { Write-Host "$_" }
  # 汇总该套件结果（断言行形如 "[HH:mm:ss] PASS  名称"）
  $suiteFail = @($out | Where-Object { "$_" -match '^\[[\d:]+\] FAIL' }).Count
  $suitePass = @($out | Where-Object { "$_" -match '^\[[\d:]+\] PASS' }).Count
  $results += [PSCustomObject]@{ suite = $t; pass = $suitePass; fail = $suiteFail }
}

$sw.Stop()
Write-Host ""
Write-Host '================ 测试汇总 ================' -ForegroundColor White
$totalPass = 0; $totalFail = 0
foreach ($r in $results) {
  $color = if ($r.fail -eq 0) { 'Green' } else { 'Red' }
  Write-Host ("  {0,-20} PASS {1}  FAIL {2}" -f $r.suite, $r.pass, $r.fail) -ForegroundColor $color
  $totalPass += $r.pass; $totalFail += $r.fail
}
$verdict = if ($totalFail -eq 0) { '全部通过 ✔' } else { "有 $totalFail 项失败 ✘" }
Write-Host "  合计: PASS $totalPass / FAIL $totalFail —— $verdict (耗时 $([math]::Round($sw.Elapsed.TotalSeconds,1))s)" -ForegroundColor $(if ($totalFail -eq 0) {'Green'} else {'Red'})

# 写汇总报告
$evidence = Join-Path $PSScriptRoot '..\evidence'
$report = @"
# DevSync 测试汇总报告
- 运行时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
- 环境: $env:COMPUTERNAME / PowerShell $($PSVersionTable.PSVersion)

| 测试套件 | PASS | FAIL |
|---|---|---|
$($results | ForEach-Object { "| $($_.suite) | $($_.pass) | $($_.fail) |" } | Out-String)

**合计: PASS $totalPass / FAIL $totalFail —— $verdict**

详细断言见各 tXX-*.txt
"@
$report | Set-Content (Join-Path $evidence 'test-summary.md') -Encoding UTF8
Write-Host "汇总已写入 evidence\test-summary.md"
exit $(if ($totalFail -gt 0) { 1 } else { 0 })
