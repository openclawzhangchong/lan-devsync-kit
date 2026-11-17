# ============================================================
# devsync —— 局域网多电脑代码接力工具
# 架构：枢纽机 Gitea (HTTP) + 私有仓库 + secrets 私库同步
# 详见 https://github.com/openclawzhangchong/lan-devsync-kit
# 兼容 PowerShell 5.1+
# ============================================================
param(
  [Parameter(Position = 0)][string]$Command,
  [Parameter(Position = 1)][string]$Arg1,
  [Parameter(Position = 2)][string]$Arg2,
  [string]$Hub,      # setup 用：枢纽地址 http://IP:3300
  [string]$User,     # setup 用：Gitea 用户名
  [string]$Token,    # setup 用：Gitea 访问令牌
  [string]$Msg,      # handoff/save 用：交接说明
  [switch]$NonInteractive
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ProgressPreference = 'SilentlyContinue'

$DS_DIR = Join-Path $env:USERPROFILE '.devsync'
$CFG_FILE = Join-Path $DS_DIR 'config.json'
$TOKEN_FILE = Join-Path $DS_DIR 'token.dpapi'
$SECRETS_DIR = Join-Path $env:USERPROFILE '.devsync-secrets'
$SECRETS_REPO = 'secrets-sync'

function Write-Info($m) { Write-Host "[devsync] $m" -ForegroundColor Cyan }
function Write-Ok($m) { Write-Host "[devsync] ✔ $m" -ForegroundColor Green }
function Write-Warn2($m) { Write-Host "[devsync] ⚠ $m" -ForegroundColor Yellow }
function Write-Err($m) { Write-Host "[devsync] ✘ $m" -ForegroundColor Red }

# ---------- git 辅助 ----------
# PS5.1 在 EAP=Stop 下会把 git 的 stderr 当异常；这里统一降级处理。
# 注意：git 输出走 Write-Host（宿主流），保证调用方 $rc = Invoke-Git ... 只捕获退出码
function Invoke-Git {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    & git @args 2>&1 | ForEach-Object { Write-Host "$_" }
    return $LASTEXITCODE
  } finally { $ErrorActionPreference = $old }
}
function Invoke-GitQuiet {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { & git @args 2>&1 | Out-Null; return $LASTEXITCODE } finally { $ErrorActionPreference = $old }
}

# ---------- 配置 ----------
function Get-Cfg {
  if (Test-Path $CFG_FILE) {
    return Get-Content $CFG_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
  }
  return $null
}
function Save-Cfg($cfg) {
  if (-not (Test-Path $DS_DIR)) { New-Item -ItemType Directory -Path $DS_DIR -Force | Out-Null }
  $cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $CFG_FILE -Encoding UTF8
}

# ---------- Token（DPAPI 加密，仅当前 Windows 用户可解） ----------
function Save-Token($plainToken) {
  if (-not (Test-Path $DS_DIR)) { New-Item -ItemType Directory -Path $DS_DIR -Force | Out-Null }
  $sec = ConvertTo-SecureString $plainToken -AsPlainText -Force
  ConvertFrom-SecureString $sec | Set-Content -Path $TOKEN_FILE -Encoding ASCII
}
function Get-Token {
  if (-not (Test-Path $TOKEN_FILE)) { return $null }
  $enc = (Get-Content $TOKEN_FILE -Raw).Trim()
  if (-not $enc) { return $null }
  $sec = ConvertTo-SecureString $enc
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  $t = [Runtime.InteropServices.Marshal]::PtrToStringAuto($b)
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)
  return $t
}

# ---------- Gitea API ----------
function Invoke-GiteaApi($Method, $Path, $Body = $null) {
  $cfg = Get-Cfg
  if (-not $cfg) { throw '尚未初始化配置，请先运行: devsync setup' }
  $tok = Get-Token
  if (-not $tok) { throw '尚未保存访问令牌，请先运行: devsync setup' }
  $headers = @{ Authorization = "token $tok" }
  $uri = "$($cfg.hub.TrimEnd('/'))$Path"
  if ($Body) {
    return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -Body ($Body | ConvertTo-Json -Depth 5) -ContentType 'application/json' -TimeoutSec 30
  }
  return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -TimeoutSec 30
}
# 判断异常是否为指定 HTTP 状态码
function Test-HttpStatus($ex, $code) {
  $r = $ex.Exception.Response
  if ($r -and $r.StatusCode -eq [System.Net.HttpStatusCode]::$code) { return $true }
  return $false
}

# ---------- git 凭据：把 token 喂给 credential helper ----------
function Set-GitCredential($hub, $user, $tok) {
  $hostport = ([Uri]$hub).Authority
  $stdin = "protocol=http`nhost=$hostport`nusername=$user`npassword=$tok`n`n"
  $stdin | & git credential approve *> $null
  if ($LASTEXITCODE -ne 0) { Write-Warn2 'git credential approve 失败，克隆时可能需要手动输入'; return $false }
  return $true
}

# ---------- git 安全推送（先 rebase 再 push，防分叉） ----------
function Invoke-SafePush($repoPath, $branch = 'main') {
  Push-Location $repoPath
  try {
    if ((Invoke-GitQuiet rev-parse --is-inside-work-tree) -ne 0) { throw "目录不是 git 仓库: $repoPath" }
    if (-not $branch) { $branch = 'main' }
    # 上次操作若有残留冲突/进行中的 rebase，拒绝继续，让用户手工处理
    $unmerged = & git diff --name-only --diff-filter=U 2>$null
    if ($unmerged) { throw "存在未解决冲突: $($unmerged -join ', ')。请手工解决后 git add 再运行 save" }
    if (Test-Path '.git/rebase-merge') { throw '上一次 rebase 未完成，请手工处理后（git rebase --continue/abort）再运行' }
    # 有暂存/未提交的改动，先自动提交（把 autostash 冲突概率降到最低）
    $dirty = & git status --porcelain
    if ($dirty) { Invoke-GitQuiet -c user.name='devsync' -c user.email='devsync@local.lan' commit -m 'devsync: 自动提交本地改动' --allow-empty | Out-Null }
    # rebase 到远端最新再推
    if ((Invoke-GitQuiet rev-parse --abbrev-ref '@{u}') -eq 0) {
      $rc = Invoke-Git pull --rebase --autostash origin $branch
      # 退出码不可靠（autostash 冲突时 git 可能返回 0），改为状态检查
      $unmerged = & git diff --name-only --diff-filter=U 2>$null
      $stashLeft = & git stash list 2>$null | Select-String 'autostash'
      if ($unmerged) { throw "远端有冲突的新改动，涉及文件: $($unmerged -join ', ')。本机改动已保留在 git stash 里，请手工裁决后 git stash drop" }
      if ($stashLeft) { throw "本机未提交改动与远端冲突（改动已暂存在 git stash），请手工处理: git stash pop 解决后提交，再 git stash drop" }
      if ($rc -ne 0) { throw 'pull --rebase 失败，请手工处理后再 save/sync' }
    }
    $rc = Invoke-Git push -u origin $branch
    if ($rc -ne 0) { throw 'git push 失败' }
    Write-Ok "已推送到枢纽 ($branch)"
  } finally { Pop-Location }
}

# ---------- 项目登记 ----------
function Register-Project($name, $path) {
  $cfg = Get-Cfg
  if (-not $cfg.projects) { $cfg | Add-Member -MemberType NoteProperty -Name projects -Value @() -Force }
  $list = @($cfg.projects)
  $existing = $list | Where-Object { $_.name -eq $name }
  if ($existing) { $existing.path = $path }
  else {
    $obj = New-Object PSObject -Property @{ name = $name; path = $path }
    $cfg.projects = @($list) + @($obj)
  }
  Save-Cfg $cfg
}

# ---------- secrets 本地仓库 ----------
function Initialize-SecretsRepo($cfg) {
  if (-not (Test-Path (Join-Path $SECRETS_DIR '.git'))) {
    if (-not (Test-Path $SECRETS_DIR)) { New-Item -ItemType Directory -Path $SECRETS_DIR -Force | Out-Null }
    Push-Location $SECRETS_DIR
    Invoke-GitQuiet init -b main | Out-Null
    '# devsync secrets 本地目录：放 .env / 账号密码 / 配置等敏感文件' | Set-Content (Join-Path $SECRETS_DIR 'README.txt') -Encoding UTF8
    Invoke-GitQuiet add -A | Out-Null
    Invoke-GitQuiet -c user.name="$($cfg.user)" -c user.email="$($cfg.user)@devsync.local" commit -m 'devsync secrets 初始化' | Out-Null
    Invoke-GitQuiet remote add origin "$($cfg.hub.TrimEnd('/'))/$($cfg.user)/$SECRETS_REPO.git" | Out-Null
    Pop-Location
    Write-Ok "已初始化本地密钥目录: $SECRETS_DIR"
  }
}

# ============================================================
# 命令分发（机器可读结果行：结尾输出 RESULT: OK / CONFLICT / ERROR，
# 便于脚本与测试断言；中文消息仅供人读，跨进程编码可能失真）
# ============================================================
$cfg = Get-Cfg

try {
switch ($Command) {

  # ---------- 初始化/配置 ----------
  'setup' {
    if (-not $Hub) { if ($NonInteractive) { throw '缺少 -Hub 参数' }; $Hub = Read-Host '枢纽地址 (如 http://192.168.168.199:3300)' }
    if (-not $User) { if ($NonInteractive) { throw '缺少 -User 参数' }; $User = Read-Host 'Gitea 用户名' }
    if (-not $Token) { if ($NonInteractive) { throw '缺少 -Token 参数（枢纽网页 设置->应用->生成令牌，勾选 repository 读写）' }; $Token = Read-Host '访问令牌 Token' }
    $newCfg = New-Object PSObject -Property @{ hub = $Hub.TrimEnd('/'); user = $User; projects = @() }
    Save-Cfg $newCfg
    Save-Token $Token
    $credOk = Set-GitCredential $Hub $User $Token
    try {
      $me = Invoke-RestMethod -Uri "$($Hub.TrimEnd('/'))/api/v1/user" -Headers @{ Authorization = "token $Token" } -TimeoutSec 15
      Write-Ok "认证通过，当前用户: $($me.login)"
    } catch { Write-Err '令牌验证失败：请检查地址/用户名/令牌'; throw }
    if (-not $credOk) { Write-Warn2 '令牌未能写入 git 凭据管理器' }
    Write-Ok "配置已保存到 $CFG_FILE（令牌经 DPAPI 加密，仅本 Windows 用户可解）"
    Write-Host '下一步：devsync clone <仓库名> 克隆项目；devsync init 把现有项目接入枢纽' -ForegroundColor White
  }

  # ---------- 新项目上枢纽 ----------
  'init' {
    if (-not $cfg) { Write-Err '请先运行 devsync setup'; exit 1 }
    $dir = if ($Arg1) { (Resolve-Path $Arg1).Path } else { (Get-Location).Path }
    $name = Split-Path $dir -Leaf
    $name = $name -replace '[^\w\.-]', '-'
    $remote = "$($cfg.hub.TrimEnd('/'))/$($cfg.user)/$name.git"
    # 枢纽上建私库（已存在则跳过）
    try {
      Invoke-GiteaApi 'POST' '/api/v1/user/repos' @{ name = $name; private = $true; auto_init = $false; description = "devsync: $name" } | Out-Null
      Write-Ok "枢纽已创建私有仓库 $name"
    } catch {
      if ($_.Exception.Response) {
        $code = [int]$_.Exception.Response.StatusCode
        if ($code -eq 409) { Write-Warn2 "枢纽仓库 $name 已存在，直接使用" } else { throw }
      } else { throw }
    }
    # 本地仓库准备
    Push-Location $dir
    try {
      if ((Invoke-GitQuiet rev-parse --is-inside-work-tree) -ne 0) {
        Invoke-GitQuiet init -b main | Out-Null
        Write-Info '已 git init（main 分支）'
      }
      $branch = & git symbolic-ref --short HEAD 2>$null
      if (-not $branch -or $branch -eq 'HEAD') { $branch = 'main' }
      Invoke-GitQuiet remote remove origin | Out-Null
      Invoke-GitQuiet remote add origin $remote | Out-Null
      # 还没有提交 → 自动提交全部文件
      if ((Invoke-GitQuiet rev-parse HEAD) -ne 0) {
        Invoke-GitQuiet add -A | Out-Null
        $rc = Invoke-GitQuiet -c user.name="$($cfg.user)" -c user.email="$($cfg.user)@devsync.local" commit -m "devsync init: 首次接入枢纽"
        if ($rc -ne 0) { Write-Warn2 '没有可提交的文件（空目录）' }
      }
      $rc = Invoke-Git push -u origin $branch
      if ($rc -ne 0) { throw '首次推送失败（检查凭据/网络）' }
    } finally { Pop-Location }
    Register-Project $name $dir
    Write-Ok "项目 [$name] 已接入枢纽（私有），登记路径 $dir"
    Write-Host "  日常用: devsync save / devsync sync；换电脑用: devsync take $name" -ForegroundColor White
  }

  # ---------- 克隆 ----------
  'clone' {
    if (-not $cfg) { Write-Err '请先运行 devsync setup'; exit 1 }
    if (-not $Arg1) { Write-Err '用法: devsync clone <仓库名> [目标目录]'; exit 1 }
    $repo = $Arg1
    $dest = if ($Arg2) { $Arg2 } else { $repo }
    $remote = "$($cfg.hub.TrimEnd('/'))/$($cfg.user)/$repo.git"
    $rc = Invoke-Git clone $remote $dest
    if ($rc -ne 0) { Write-Err '克隆失败（检查仓库名/凭据/网络）'; exit 1 }
    Register-Project $repo (Resolve-Path $dest).Path
    Write-Ok "已克隆并登记 [$repo] → $dest"
  }

  # ---------- 保存并推送 ----------
  'save' {
    if (-not $cfg) { Write-Err '请先运行 devsync setup'; exit 1 }
    $dir = if ($Arg1 -and (Test-Path $Arg1)) { (Resolve-Path $Arg1).Path } else { (Get-Location).Path }
    $msg = if ($Msg) { $Msg } elseif ($Arg2) { $Arg2 } else { "devsync save $(Get-Date -Format 'yyyy-MM-dd HH:mm')" }
    Push-Location $dir
    Invoke-GitQuiet add -A | Out-Null
    $pending = & git status --porcelain
    if (-not $pending -and (-not $Msg)) { Write-Warn2 '没有需要提交的改动'; Pop-Location; exit 0 }
    Invoke-GitQuiet commit -m $msg | Out-Null
    Pop-Location
    $branch = & git -C $dir symbolic-ref --short HEAD 2>$null
    Invoke-SafePush $dir $branch
  }

  # ---------- 同步（拉取+推送） ----------
  'sync' {
    if (-not $cfg) { Write-Err '请先运行 devsync setup'; exit 1 }
    $dir = if ($Arg1 -and (Test-Path $Arg1)) { (Resolve-Path $Arg1).Path } else { (Get-Location).Path }
    $branch = & git -C $dir symbolic-ref --short HEAD 2>$null
    Invoke-SafePush $dir $branch
    Write-Ok "同步完成 [$dir]"
  }

  # ---------- 接手（换电脑继续干活） ----------
  'take' {
    if (-not $cfg) { Write-Err '请先运行 devsync setup'; exit 1 }
    if (-not $Arg1) { Write-Err '用法: devsync take <仓库名> [目录]'; exit 1 }
    $repo = $Arg1
    $dest = if ($Arg2) { $Arg2 } else { Join-Path (Get-Location).Path $repo }
    if (Test-Path (Join-Path $dest '.git')) {
      Write-Info "本地已有 [$repo]，执行增量同步..."
      $branch = & git -C $dest symbolic-ref --short HEAD 2>$null
      Invoke-SafePush $dest $branch
    } else {
      & $PSCommandPath clone $repo $dest
    }
    & $PSCommandPath secrets pull
    Write-Host ''
    Write-Host "===== 接手摘要 [$repo] =====" -ForegroundColor White
    Invoke-Git -C $dest log --oneline -5 | Out-Null
    $dirty = & git -C $dest status --porcelain
    if ($dirty) { Write-Warn2 '工作区还有未提交改动：'; $dirty | ForEach-Object { Write-Host "  $_" } }
    Write-Ok '接手完成，可以继续干活'
  }

  # ---------- 交接（存档+密钥+交接笔记，一键推走） ----------
  'handoff' {
    if (-not $cfg) { Write-Err '请先运行 devsync setup'; exit 1 }
    $dir = if ($Arg1 -and (Test-Path $Arg1)) { (Resolve-Path $Arg1).Path } else { (Get-Location).Path }
    $note = if ($Msg) { $Msg } elseif ($Arg2) { $Arg2 } else { '常规交接：工作进度与当前状态已全部推送' }
    & $PSCommandPath save -Msg $note
    & $PSCommandPath secrets push
    $hdDir = Join-Path $dir '.devsync/handoff'
    if (-not (Test-Path $hdDir)) { New-Item -ItemType Directory -Path $hdDir -Force | Out-Null }
    $file = Join-Path $hdDir "$(Get-Date -Format 'yyyy-MM-dd_HHmmss').md"
    $recent = & git -C $dir log --oneline -5 2>$null
    @"
# 交接记录 · $(Get-Date -Format 'yyyy-MM-dd HH:mm')
- 机器: $env:COMPUTERNAME
- 项目: $(Split-Path $dir -Leaf)
- 说明: $note
- 最近提交:
$($recent | ForEach-Object { "  - $_" } | Out-String)
"@ | Set-Content $file -Encoding UTF8
    Invoke-GitQuiet -C $dir add .devsync | Out-Null
    Invoke-GitQuiet -C $dir commit -m "handoff: $note" | Out-Null
    $branch = & git -C $dir symbolic-ref --short HEAD 2>$null
    Invoke-SafePush $dir $branch
    Write-Ok '交接完成：代码+密钥+交接笔记 全部已推送到枢纽'
    Write-Host "  另一台电脑执行: devsync take $(Split-Path $dir -Leaf)" -ForegroundColor White
  }

  # ---------- secrets：密钥/凭据同步 ----------
  'secrets' {
    if (-not $cfg) { Write-Err '请先运行 devsync setup'; exit 1 }
    $sub = if ($Arg1) { $Arg1 } else { 'push' }
    Initialize-SecretsRepo $cfg
    switch ($sub) {
      'init' { Write-Ok "密钥目录: $SECRETS_DIR （把 .env、账号密码文件放进去）" }
      'push' {
        # 枢纽上确保私库存在
        try { Invoke-GiteaApi 'POST' '/api/v1/user/repos' @{ name = $SECRETS_REPO; private = $true; auto_init = $false } | Out-Null }
        catch {
          if (-not ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 409)) { throw }
        }
        Push-Location $SECRETS_DIR
        Invoke-GitQuiet add -A | Out-Null
        $dirty = & git status --porcelain
        if ($dirty) { Invoke-GitQuiet -c user.name="$($cfg.user)" -c user.email="$($cfg.user)@devsync.local" commit -m "secrets push $(Get-Date -Format 'yyyy-MM-dd HH:mm')" | Out-Null }
        $rc = Invoke-Git push -u origin main
        Pop-Location
        if ($rc -ne 0) { throw 'secrets push 失败' }
        Write-Ok "密钥已推送到枢纽私库 [$SECRETS_REPO]（仅本人可读）"
      }
      'pull' {
        Push-Location $SECRETS_DIR
        $rc = Invoke-GitQuiet pull --rebase --autostash origin main
        Pop-Location
        if ($rc -ne 0) { Write-Warn2 'secrets pull 失败（枢纽上还没有该库可跳过）'; exit 0 }
        Write-Ok "密钥已拉取到 $SECRETS_DIR"
      }
      default { Write-Err '用法: devsync secrets [init|push|pull]' }
    }
  }

  # ---------- 状态总览 ----------
  'status' {
    if (-not $cfg) { Write-Err '请先运行 devsync setup'; exit 1 }
    Write-Host "枢纽: $($cfg.hub)   用户: $($cfg.user)" -ForegroundColor White
    $projects = @($cfg.projects) | Where-Object { $_ }
    if (-not $projects) { Write-Warn2 '还没有登记任何项目（devsync init / devsync clone 会自动登记）'; exit 0 }
    foreach ($p in $projects) {
      if (-not (Test-Path $p.path)) { Write-Warn2 "[$($p.name)] 路径不存在: $($p.path)"; continue }
      $count = & git -C $p.path rev-list --left-right --count 'HEAD...@{u}' 2>$null
      if ($LASTEXITCODE -ne 0) { Write-Host "  [$($p.name)] 未跟踪远程分支（先 push 一次）" }
      else {
        $ahead = ($count -split '\s+')[0]; $behind = ($count -split '\s+')[1]
        $dirty = if (& git -C $p.path status --porcelain) { ' (有未提交改动)' } else { '' }
        Write-Host "  [$($p.name)] 领先 $ahead / 落后 $behind$dirty"
      }
    }
  }

  # ---------- 体检 ----------
  'doctor' {
    Write-Host '===== devsync 体检 =====' -ForegroundColor White
    $fail = 0
    $gv = & git --version 2>$null
    if ($gv) { Write-Ok "git: $gv" } else { Write-Err 'git 未安装'; $fail++ }
    if ($cfg) {
      Write-Ok "配置: 枢纽 $($cfg.hub) / 用户 $($cfg.user) / 登记 $(@($cfg.projects).Count) 个项目"
      try {
        $v = Invoke-RestMethod -Uri "$($cfg.hub.TrimEnd('/'))/api/v1/version" -TimeoutSec 10
        Write-Ok "枢纽连通: Gitea $($v.version)"
      } catch { Write-Err "枢纽连不上: $($cfg.hub)"; $fail++ }
      $tok = Get-Token
      if ($tok) {
        try {
          Invoke-RestMethod -Uri "$($cfg.hub.TrimEnd('/'))/api/v1/user" -Headers @{ Authorization = "token $tok" } -TimeoutSec 10 | Out-Null
          Write-Ok '令牌有效'
        } catch { Write-Err '令牌无效或过期（重新 devsync setup）'; $fail++ }
      } else { Write-Err '令牌未保存'; $fail++ }
    } else { Write-Warn2 '未初始化（devsync setup）'; $fail++ }
    if (Test-Path (Join-Path $SECRETS_DIR '.git')) { Write-Ok "密钥目录: $SECRETS_DIR" }
    else { Write-Warn2 '密钥目录未初始化（devsync secrets init）' }
    Write-Host ''
    if ($fail -eq 0) { Write-Ok '体检全部通过 ✔' } else { Write-Err "体检发现 $fail 项问题"; exit 1 }
  }

  # ---------- 打开枢纽网页 ----------
  'open' {
    if (-not $cfg) { Write-Err '请先运行 devsync setup'; exit 1 }
    Start-Process $cfg.hub
  }

  '' {
    Write-Host @'
devsync —— 局域网多电脑代码接力工具

  首次使用（每台电脑一次）:
    devsync setup -Hub http://IP:3300 -User dev -Token <令牌>

  日常:
    devsync init [目录]      把现有项目接入枢纽（自动建私库并首推）
    devsync clone <仓库>     从枢纽克隆项目
    devsync save [说明]      提交全部改动并安全推送（自动 rebase 防分叉）
    devsync sync             拉取远端最新并推送本地
    devsync take <仓库>      换电脑接手：克隆/同步 + 密钥拉取 + 摘要
    devsync handoff "说明"   交接：代码+密钥+交接笔记 一键推走

  密钥同步:
    devsync secrets init     初始化密钥目录 (~\.devsync-secrets)
    devsync secrets push/pull  推送/拉取账号密码、.env 等敏感文件

  其他:
    devsync status           查看所有项目领先/落后状态
    devsync doctor           全面体检（连通性/令牌/git）
    devsync open             打开枢纽网页
'@
  }

  default { Write-Err "未知命令: $Command"; & $PSCommandPath ''; exit 1 }
}
Write-Output '[devsync] RESULT: OK'
} catch {
  $msg = "$_"
  if ($msg -match '冲突|conflict') { Write-Output '[devsync] RESULT: CONFLICT' }
  else { Write-Output "[devsync] RESULT: ERROR" }
  Write-Err $msg
  exit 1
}
