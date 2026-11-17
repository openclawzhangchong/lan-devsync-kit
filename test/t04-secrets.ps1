# t04 密钥同步：push→（模拟另一台电脑）pull→内容一致
. (Join-Path $PSScriptRoot '_lib.ps1')
Write-TLog '=== t04 密钥同步测试 ==='

$stamp = Get-Date -Format 'HHmmss'
$secretsDir = Join-Path $env:USERPROFILE '.devsync-secrets'
$testFile = Join-Path $secretsDir "test-$stamp.env"
$fakeSecret = "FAKE_SECRET_NOT_REAL_$stamp"

# 1. 本机写入"密钥"并推送
Set-Content $testFile "password=$fakeSecret"
$rc = Invoke-Devsync secrets push
Assert-Eq 'secrets push 成功' $rc 0

# 2. 模拟另一台电脑：把本地 secrets 目录改名 → pull → 内容一致
$backup = "$secretsDir.bak-$stamp"
Move-Item $secretsDir $backup
$rc = Invoke-Devsync secrets pull
Assert-Eq 'secrets pull 成功(模拟新电脑)' $rc 0
$pulled = (Get-Content (Join-Path $secretsDir "test-$stamp.env") -Raw -ErrorAction SilentlyContinue).Trim()
Assert-Eq '拉取的密钥内容一致' $pulled "password=$fakeSecret"

# 3. 枢纽私库确实存在且为私有
$tok = Get-TokenPlain
$repoInfo = Invoke-RestMethod -Uri "$($script:HUB)/api/v1/repos/dev/secrets-sync" -Headers @{ Authorization = "token $tok" } -TimeoutSec 10
Assert-Eq 'secrets-sync 私库私有' $repoInfo.private 'True'

# 4. 清理测试密钥文件 + 恢复原目录
Remove-Item $testFile -Force -ErrorAction SilentlyContinue
Remove-Item $secretsDir -Recurse -Force -ErrorAction SilentlyContinue
Move-Item $backup $secretsDir
Invoke-Devsync secrets push | Out-Null   # 把删除同步到枢纽
Write-TLog '测试密钥文件已清理并同步'
Save-TestReport 't04-secrets'
