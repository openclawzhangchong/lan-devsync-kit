# t06 devsync doctor 体检必须全绿
. (Join-Path $PSScriptRoot '_lib.ps1')
Write-TLog '=== t06 doctor 体检 ==='

$rc = Invoke-Devsync doctor
Write-TLog '--- doctor 输出见上方 ---'
Assert-Eq 'doctor 退出码 0' $rc 0
$logText = Get-SuiteLog
Assert-True '体检输出含枢纽连通' ($logText -match '枢纽连通')
Assert-True '体检输出含令牌有效' ($logText -match '令牌有效')
Save-TestReport 't06-doctor'
