# HANDOFF · 交接文档

> 写给下一次接管这台机器/这个项目的你（人或 AI）。本文档描述**截至 2026-11-18 00:20 的实际部署状态**。

## 一、现状一句话

DevSync v1.0.0 已完整部署并测试通过：枢纽机 = 本机（G32，192.168.168.199），Gitea 服务运行中，28/28 测试全绿，GitHub 仓库与演示网站已发布。

## 二、关键资产位置

| 资产 | 位置 |
|---|---|
| Gitea 程序+数据 | `E:\devsync\gitea\`（app.ini 在 custom\conf\） |
| 裸仓库 | `E:\devsync\gitea-repos\`（dev/demo-app、dev/secrets-sync） |
| devsync CLI（装机副本） | `E:\devsync\bin\`（已加用户 PATH） |
| devsync CLI（仓库源） | 本仓库 `bin\` |
| **管理员凭据** | `E:\devsync\secrets\gitea-admin.txt`（用户 dev，密码在其中）⚠ 勿提交/勿外传 |
| **CLI 令牌** | `E:\devsync\secrets\devsync-cli-token.txt` + 各机 `%USERPROFILE%\.devsync\token.dpapi`（DPAPI 加密） |
| 服务 | Windows 服务 `DevSyncGitea`（NSSM，自启） |
| 日志 | `E:\devsync\logs\`（服务捕获）+ `E:\devsync\gitea\data\log\`（Gitea 文件日志） |
| 测试 | 本仓库 `test\run-all.ps1`，证据在 `evidence\` |
| 枢纽网页 | http://192.168.168.199:3300 （仅局域网） |

## 三、已完成验收

- [x] Gitea 28.4.0 部署 + SHA256 校验 + SQLite/WAL
- [x] 服务自启 + 端口 3300 监听 + 防火墙网段限制
- [x] devsync CLI 全命令可用（init/clone/save/sync/take/handoff/secrets/status/doctor/open）
- [x] 三机接力端到端验证（t02，8 断言）
- [x] 冲突检测 + 防呆（t03）
- [x] secrets 私库同步（t04）
- [x] 安全四断言（t05：无凭据拒绝/私库隐藏/注册禁用/网段防火墙）
- [x] 文档全套（README/CHANGELOG/docs/8 篇/handoff）
- [x] GitHub 仓库 https://github.com/openclawzhangchong/lan-devsync-kit
- [x] 演示网站（地址见 README 顶部）

## 四、给你的待办（按优先级）

1. **改管理员密码**：登录 http://192.168.168.199:3300 → 设置 → 修改密码（当前是自动生成的 16 位，在 secrets\gitea-admin.txt）
2. **另外两台电脑接入**：拷本仓库 `install\` 目录过去，跑 `install-another-pc.ps1`（见 docs/03）
3. **把手头项目接入**：在项目目录跑 `devsync init`；换机接手用 `devsync take <项目>`
4. **（可选）安全加码**：BitLocker 开启；局域网不可信则启用 Gitea 内置 SSH
5. **（可选）备份**：把 `E:\devsync\` 整目录纳入定期备份

## 五、已知限制

- 局域网 HTTP 明文传输（可信内网前提下可接受；更严要求启用内置 SSH，见 docs/05）
- secrets 文件在磁盘为明文（BitLocker 缓解）
- 枢纽机单点（备份 E:\devsync\ 即可完整恢复）
- devsync 假定 main 分支为默认分支（其他分支用原生 git 操作即可，devsync 命令兼容）

## 六、快速排障入口

```bash
devsync doctor                 # 第一句话
sc query DevSyncGitea          # 服务状态
netsh advfirewall firewall show rule name="DevSync Gitea 3300"   # 防火墙
type E:\devsync\logs\gitea-service.err.log                       # 服务日志
```

更多：docs\06-故障排查FAQ.md
