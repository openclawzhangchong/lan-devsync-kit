# ============================================================
# install-another-pc —— 其他电脑一键接入 DevSync 枢纽
# 用法（在该电脑上执行）:
#   powershell -ExecutionPolicy Bypass -File install-another-pc.ps1 ^
#     -Hub http://192.168.168.199:3300 -User dev
# Token 会在提示时输入（枢纽网页 头像->设置->应用->生成新令牌，勾选 repository 读写）
# 或直接带 -Token 参数执行
# ============================================================
param(
  [string]$Hub = 'http://192.168.168.199:3300',
  [string]$User = 'dev',
  [string]$Token,
  [string]$SourceDir = $PSScriptRoot
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

Write-Host '[install] DevSync 接入安装开始' -ForegroundColor Cyan

# 1. 检查 git
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
  Write-Host '[install] 未检测到 git，请先安装 Git for Windows: https://git-scm.com/download/win' -ForegroundColor Red
  exit 1
}
Write-Host "[install] git OK: $((& git --version))"

# 2. 安装 devsync 到用户目录（不依赖本仓库位置）
$binDir = Join-Path $env:USERPROFILE '.devsync\bin'
New-Item -ItemType Directory -Path $binDir -Force | Out-Null
Copy-Item (Join-Path $SourceDir '..\bin\devsync.ps1') $binDir -Force
Copy-Item (Join-Path $SourceDir '..\bin\devsync.bat') $binDir -Force
Write-Host "[install] devsync 已安装到 $binDir"

# 3. 加入用户 PATH（若未在）
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $binDir) {
  [Environment]::SetEnvironmentVariable('Path', "$userPath;$binDir", 'User')
  Write-Host '[install] 已加入用户 PATH（新开的终端生效）'
}

# 4. Token（未给则交互输入）
if (-not $Token) {
  Write-Host '[install] 请先在枢纽网页生成令牌: 头像 -> 设置 -> 应用 -> 生成新令牌（勾选 repository 读写权限）' -ForegroundColor Yellow
  $Token = Read-Host '粘贴令牌 Token'
}
if (-not $Token) { Write-Host '[install] 未提供令牌，中止' -ForegroundColor Red; exit 1 }

# 5. 配置 + 令牌（DPAPI 加密）
& (Join-Path $binDir 'devsync.ps1') setup -Hub $Hub -User $User -Token $Token

# 6. 体检
& (Join-Path $binDir 'devsync.ps1') doctor

Write-Host ''
Write-Host '[install] 完成! 新开终端即可使用:' -ForegroundColor Green
Write-Host '   devsync clone <仓库名>          # 克隆项目'
Write-Host '   devsync init C:\path\to\project # 接入现有项目'
Write-Host '   devsync save "说明"             # 保存推送'
Write-Host '   devsync take <仓库名>           # 接手项目'
