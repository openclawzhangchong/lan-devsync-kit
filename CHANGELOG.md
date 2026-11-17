# 更新日志

本项目的所有重要变更都记录在此文件。
格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循语义化版本。

## [1.1.0] - 2026-11-18

### 新增：DevSyncTray 托盘程序（枢纽状态可视化）

- 托盘常驻：绿点=运行中 / 黄点=启动中 / 红点=停止异常，状态变化弹气泡通知
- 菜单操作：打开枢纽网页 / 启动 / 停止 / 重启服务（UAC 静默提权）/ devsync 体检 / 开机自启开关 / 退出
- 状态探测：每 3 秒同时检查服务状态（sc query）与端口连通（127.0.0.1:3300），端口未就绪单独标黄
- 运行日志：E:\devsync\logs\tray.log
- 已部署到枢纽机 E:\devsync\bin\DevSyncTray.exe，HKCU 开机自启已启用
- 端到端验证：停服→托盘 3 秒内检测并通知→恢复→再次通知，日志三轮状态转换齐全
- 源码 tray\devsync_tray.py，打包 tray\build.bat（PyInstaller onefile）

## [1.0.0] - 2026-11-18

### 首次发布：局域网三机代码接力方案（DevSync）

#### 新增
- **Gitea 枢纽部署**（Windows 原生，非 Docker）
  - Gitea 28.4.0 + SQLite/WAL，监听局域网 3300 端口（3000 被 zcode-hub 占用）
  - NSSM 注册 Windows 服务 `DevSyncGitea`（开机自启、日志轮转）
  - 防火墙规则仅放行本网段 + 回环（192.168.168.0/24, 127.0.0.1）
  - 禁止注册、仓库默认私有、离线模式、SHA256 校验安装包
  - 静默提权安装路径（ConsentPromptBehaviorAdmin=0 场景，无人值守）
  - `install\install-hub.ps1` 一键复现安装
- **devsync 命令行工具**（PowerShell 5.1 兼容，中文输出）
  - `setup / init / clone / save / sync / take / handoff / secrets / status / doctor / open`
  - 凭据 DPAPI 加密存储 + git credential helper 接入
  - 安全推送：自动 rebase 防分叉；冲突三重状态检测 + 防呆拒绝 + 明确指引
  - 机器可读结果行 `RESULT: OK / CONFLICT / ERROR`（供脚本/CI 断言）
  - secrets 独立私库同步账号密码/.env 等敏感文件
  - `install\install-another-pc.ps1` 其他电脑一键接入
- **测试套件**（`test\run-all.ps1`）
  - t01 枢纽健康 / t02 三机接力 / t03 冲突检测 / t04 密钥同步 / t05 安全 / t06 体检
  - **28/28 两轮全绿**，幂等可重复，自动清理现场
- **文档**（docs\）
  - 方案调研与选型（引用 CSDN/GitHub/微软官方等 12 处来源）
  - 部署手册（枢纽机）、接入指南（其他电脑）、日常使用与交接流程
  - 安全与隐私设计、故障排查 FAQ、测试报告、知识库经验总结
- **交接**（handoff\HANDOFF.md：当前部署状态/凭据位置/待办事项）
- **演示网站**（website\，部署地址见 README）

#### 安全
- 全部敏感信息（管理员密码、令牌）仅存枢纽机 E:\devsync\secrets\，不入任何仓库
- 仓库入库内容已脱敏审查

[1.0.0]: https://github.com/openclawzhangchong/lan-devsync-kit/releases/tag/v1.0.0
