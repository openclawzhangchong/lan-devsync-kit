# DevSync · 局域网多电脑代码接力工具

> 一句话：**在你自己的一台电脑上搭一个私有 Git 枢纽（Gitea），三台电脑互为同事——A 机干完 `save`，B 机 `take` 接手，秒级接力，永不重新克隆，账号密码一并同步，别人进不来。**

- 演示网站：**https://lan-devsync-2ylq.zai.site**
- 枢纽网页（仅限局域网）：http://192.168.168.199:3300
- 测试：**28/28 全部通过**（见 [docs/07-测试报告.md](docs/07-测试报告.md)）

---

## 它解决什么问题

| 你原来的痛点 | DevSync 的解法 |
|---|---|
| B 机接手要重新 clone 一遍 | 枢纽保存全部历史，B 机 `devsync take` 一条命令接手（没有就克隆、有就增量同步） |
| 映射盘共享文件夹经常假死 | 彻底弃用 SMB 挂载。git 走 HTTP 协议（请求-响应式，无持久句柄，不存在假死），传输还带增量压缩 |
| 共享文件夹局域网里的其他人也能看 | 私有仓库 + 禁止注册 + 令牌认证（凭据 DPAPI 加密存本机）+ 防火墙只放行你自己的网段 |
| 账号密码、.env 这类东西没法跟着代码走 | `devsync secrets` 用一个独立私库同步敏感文件，仅本人账号可读 |
| 局域网带宽有限，传大项目慢 | git 增量传输只传差异对象，比整目录拷贝快一个量级；再克隆可配 partial clone |

## 架构

```
 机器A (优化机1)          枢纽机 = 你的电脑                机器B (优化机2)
┌────────────┐   push    ┌──────────────────┐   pull    ┌────────────┐
│ E:\项目\foo ├──────────▶│ Gitea (端口3300)  │◀──────────┤ E:\项目\foo │
│            │◀───pull───│ E:\devsync\      ├───push───▶│            │
└────────────┘           │  ├ gitea\ 程序+DB │           └────────────┘
      ▲                  │  ├ gitea-repos\  │                   ▲
      │  devsync CLI     │  │  (私有裸仓库)  │     devsync CLI   │
      └──────────────────┤  ├ secrets-sync  │◀──────────────────┘
   （凭据 DPAPI 加密）     │  │  (密钥私库)   │  （凭据 DPAPI 加密）
                          │  └ bin\ devsync  │
                          └──────────────────┘
  防火墙：3300 端口仅放行 192.168.168.0/24 + 127.0.0.1
  开机自启：Windows 服务 DevSyncGitea (NSSM)
```

三台电脑中**任意一台装枢纽**（推荐你白天常用、不关机的那台），其余两台只装 `devsync` 命令行（约 2 分钟）。

## 快速开始

### ① 枢纽机（已部署完毕，本仓库安装脚本可复现）

```powershell
# 全新机器重装/迁移时执行（需要能下载 dl.gitea.com 与 nssm.cc）：
powershell -ExecutionPolicy Bypass -File install\install-hub.ps1
# 产物：E:\devsync\{gitea, gitea-repos, bin, secrets} + 服务 DevSyncGitea + 防火墙规则
# 管理员账号密码在 E:\devsync\secrets\gitea-admin.txt（勿提交到任何仓库）
```

### ② 其他电脑接入（每台一次，约 2 分钟）

```powershell
# 把本仓库的 install\ 目录拷过去（U盘/devsync clone 都行），然后：
powershell -ExecutionPolicy Bypass -File install\install-another-pc.ps1
# 按提示粘贴令牌（枢纽网页 头像→设置→应用→生成新令牌，勾选 repository 读写）
```

### ③ 日常接力（就三个动作）

```bash
devsync save "完成了XX优化"     # 在干活的电脑上：提交+安全推送
devsync take foo                # 换到另一台电脑：接手（克隆/同步+密钥+摘要）
devsync handoff "下班交接"      # 可选：代码+密钥+交接笔记一键推走再走人
```

## devsync 命令一览

| 命令 | 作用 |
|---|---|
| `devsync setup -Hub http://IP:3300 -User dev -Token xxx` | 每台电脑初始化一次（令牌 DPAPI 加密保存） |
| `devsync init [目录]` | 把现有项目接入枢纽：自动建私库+首次推送 |
| `devsync clone <仓库>` | 从枢纽克隆并登记 |
| `devsync save [说明]` | 提交全部改动并安全推送（自动 rebase 防分叉，冲突时明确报错并教你怎么处理） |
| `devsync sync` | 拉取远端最新 + 推送本地 |
| `devsync take <仓库>` | **接力核心**：克隆/增量同步 + 拉取密钥 + 打印接手摘要 |
| `devsync handoff "说明"` | 交接三件套：代码 + 密钥 + 交接笔记（`.devsync/handoff/*.md`） |
| `devsync secrets init/push/pull` | 同步账号密码/.env 等敏感文件（独立私库 secrets-sync） |
| `devsync status` | 所有项目的领先/落后状态 |
| `devsync doctor` | 全面体检（git/枢纽连通/令牌/密钥目录） |
| `devsync open` | 打开枢纽网页 |

脚本/CI 可依赖机器可读结果行：命令结束输出 `RESULT: OK` / `RESULT: CONFLICT` / `RESULT: ERROR`。

## 目录说明

```
├── bin/          devsync.ps1 + devsync.bat（命令行工具本体）
├── install/      install-hub.ps1（枢纽安装）/ install-another-pc.ps1（电脑接入）/ app.ini.template
├── test/         run-all.ps1 总入口 + t01~t06 六个测试套件
├── evidence/     测试运行证据（断言结果、控制台日志、汇总报告）
├── docs/         方案调研/部署手册/接入指南/使用与交接/安全设计/FAQ/测试报告/知识库总结
├── handoff/      HANDOFF.md 交接文档（当前部署状态、凭据位置、待办）
└── website/      演示网站源码（部署地址见 README 顶部）
```

## 文档导航

1. [方案调研与选型](docs/01-方案调研与选型.md) —— 为什么是 Gitea 而不是共享文件夹/Syncthing/GitLab
2. [部署手册·枢纽机](docs/02-部署手册-枢纽机.md) —— 手动步骤全记录（今晚实际执行路径）
3. [接入指南·其他电脑](docs/03-接入指南-其他电脑.md)
4. [日常使用与交接流程](docs/04-日常使用与交接流程.md)
5. [安全与隐私设计](docs/05-安全与隐私设计.md) —— 四层防线详解
6. [故障排查 FAQ](docs/06-故障排查FAQ.md) —— 含"映射盘假死"对照说明
7. [测试报告](docs/07-测试报告.md) —— 28 项断言与修复过程
8. [知识库经验总结](docs/知识库经验总结.md) —— 本次踩坑沉淀，可回写 zhishiku

## 环境要求

- Windows 10/11（PowerShell 5.1 即可，无需升级）
- Git for Windows（其他两台电脑需要；枢纽机需要）
- 枢纽机磁盘 ~200MB（Gitea 单文件 122MB + 数据）
- 无需公网、无需 Docker、无需数据库服务（SQLite 内置）

## License

MIT
