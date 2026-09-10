# 开发与验收入口

主仓库是唯一产品源码入口，只在main维护当前实现。其他旧工作目录保留为脱离分支的历史快照，不再双向同步。

## 目录职责

| 目录或入口 | 用途 |
|---|---|
| 本仓库的apps/browser | Chromium固定版本、overlay、有序补丁、构建和验证脚本 |
| packages/core | 共享策略与合同 |
| prototypes/browser-agent-v2 | 隔离的历史实验；不是生产Runtime |
| 本机指定的macOS构建区 | 接收已核验源码并复用构建缓存 |
| 本项目唯一Android构建容器 | 复用既有镜像、依赖和缓存，不为每轮任务创建新容器 |
| 本机固定的Mac验收App | 开发、运行和验收沿用同一路径、签名身份与独立资料目录 |

本机Chromium位置由apps/browser/.chromium-root或CHROMIUM_ROOT配置，不随Git分发。不要按旧路径、同名App或截图判断当前产物。

## 构建与版本

每次真实Mac App编译、打包前更新版本号：小修复使用Ver 1.0 (xxx)递增构建号；新增特性使用Ver 1.1；多个功能或大范围调整使用Ver 2.0。版本显示、包元数据和验收记录应一致，不能只改文件名。本次Git源码合并未构建App，也没有声称版本递增已自动接入脚本。

保持固定App路径，不把旧版本的系统权限、模型运行结果或签名验证移用于新产物。需要替换时先确认进程停止、保留旧包与资料，再验证同一入口的新包。

## 验证与恢复

在仓库根目录运行：

```bash
pnpm install --frozen-lockfile
pnpm run quality:fast
```

历史原型独立验证：

```bash
cd prototypes/browser-agent-v2
npm ci --ignore-scripts
npm run test:unit
```

当前补丁为108个Chromium补丁和2个V8补丁。完整重放结果、合并提交和备份边界见[main合并记录](docs/audit/main-consolidation-2026-09-10.md)。本机备份、资料、模型和失败证据保留在Git忽略目录，不等于远程备份或发行包。

[最新macOS修复与验证](docs/audit/summary-latency-2026-09-10.md)和[跨平台十项标准](docs/audit/aegis-browser-agent-v2-cross-platform-acceptance-2026-09-05.md)分别记录。源码提交不缩小实机、隐私、反钓鱼和本地Qwen验收要求，也不授权修改系统权限、生产发布或清理用户资料。
