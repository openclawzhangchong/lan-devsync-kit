# 06 · 故障排查 FAQ

## 枢纽类

**Q: 网页打不开 http://192.168.168.199:3300**
1. 枢纽机上 `sc query DevSyncGitea` 看 STATE 是否 RUNNING；没跑就 `net start DevSyncGitea`
2. 枢纽机是不是关机/休眠了——枢纽机尽量不关机（服务已设开机自启）
3. 你的电脑和枢纽是否同网段（`ipconfig` 看是否 192.168.168.x）
4. 枢纽机防火墙规则是否还在：`netsh advfirewall firewall show rule name="DevSync Gitea 3300"`

**Q: 服务启动失败**
看 `E:\devsync\logs\gitea-service.err.log` 和 Gitea 自身日志 `E:\devsync\gitea\data\log\`。最常见：app.ini 路径改错、端口被占（改 app.ini 的 HTTP_PORT 后 `nssm restart DevSyncGitea`）。

**Q: 想改密码/建新仓库/看提交图谱**
`devsync open` 打开枢纽网页，一切在网页上操作。

## devsync 类

**Q: `devsync` 提示不是内部或外部命令**
新装的 PATH 还没生效——**新开一个终端**再试；或重跑 `install\install-another-pc.ps1`。

**Q: save 时报"存在未解决冲突"/"上一次 rebase 未完成"**
上次操作因冲突中断了。按提示手工处理：
```bash
git status                    # 看冲突文件
# 编辑冲突文件解决后：
git add <文件>
git rebase --continue         # 或 git rebase --abort 放弃本次
devsync save "裁决后推送"
git stash drop                # 确认无用后清掉暂存
```

**Q: 报 RESULT: CONFLICT 是什么意思**
远端有别人推的新提交和你的改动冲突。devsync **拒绝自动覆盖**，你的改动安全地留在 `git stash`。按上一条手工裁决。

**Q: take 之后密钥目录没东西**
枢纽上还没有 secrets-sync 仓库（从没在旧机器上 `devsync secrets push` 过）。先在旧机器推一次。

**Q: 克隆弹用户名密码框**
令牌没进凭据管理器：重跑 `devsync setup`（见接入指南）。

## 迁移/备份

**Q: 枢纽机要重装系统，怎么搬家**
1. 备份整个 `E:\devsync\`（含 gitea-repos、data、secrets、bin）
2. 新机上跑 `install\install-hub.ps1`（端口/IP 参数按需改）
3. 停新服务 → 拷回 gitea-repos + data + secrets → 起服务
4. 其他电脑 `devsync setup -Hub http://新IP:3300 ...`

**Q: 想彻底删除某个项目**
```bash
devsync open    # 网页上：仓库→设置→删除
devsync status  # 本机登记还在的话，编辑 %USERPROFILE%\.devsync\config.json 删掉那行
```

## 与"映射盘假死"的关系

DevSync 的设计初衷就是**替代**映射盘方案：
- 映射盘假死 = SMB 持久会话 + 文件锁模型在网速波动/空闲断连时的必然结果（微软官方文档承认该问题，社区方案是保活脚本类补丁）
- DevSync = git over HTTP，请求-响应式：没有挂载盘符、没有持久句柄，网络抖动只会让单次请求重试，**不存在"整个盘假死拖死资源管理器"的机制**
- 如果你现在还有旧的映射盘在用，建议移除（`net use * /delete`），避免资源管理器继续被旧会话卡住
