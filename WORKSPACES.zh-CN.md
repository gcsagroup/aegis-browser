# 开发与验收入口

主仓库是唯一产品源码入口，只在main维护当前实现。本机顶层目录收敛为产品主仓库和GCSA-aegis-build构建资料区。旧工作目录移入可恢复归档或废纸篓，不再作为开发入口，也不双向同步。

## 目录职责

| 目录或入口 | 用途 |
|---|---|
| 本仓库的apps/browser | Chromium固定版本、overlay、有序补丁、构建和验证脚本 |
| packages/core | 共享策略与合同 |
| prototypes/browser-agent-v2 | 隔离的历史实验；不是生产Runtime |
| GCSA-aegis-build/upstream-candidate/src | 当前153内核源码与唯一Mac构建输出，复用已验收044的缓存 |
| GCSA-aegis-build/macos/src | 旧151源码与恢复资料；本轮不作为构建入口 |
| GCSA-aegis-build/android/src及depot_tools | Android源码、工具与缓存，由唯一aegis-android-builder容器使用 |
| GCSA-aegis-build/shared/chromium/src | 共享Git主库及依赖；不是可以随意删除的重复副本 |
| 本机固定的Mac验收App | 开发、运行和验收沿用同一路径、签名身份与独立资料目录 |

本机Chromium位置由apps/browser/.chromium-root或CHROMIUM_ROOT配置，不随Git分发。不要按旧路径、同名App或截图判断当前产物。

本机macOS通过`.chromium-root`指向`upstream-candidate`，复用现有`src/out/AegisRelease`；未设置marker的脚本默认值仍为macos，不表示本机当前入口。Android和共享依赖操作分别显式指定android、shared/chromium。更新依赖前核对该目录的.gclient配置，不在仅有src的链接工作树中重新下载另一份源码。

固定验收App仍使用本机Applications中的GCSA Aegis Test.app，不随源码工作区迁移。旧的验收清单保留原始路径和容器ID，后续真实构建应创建绑定新布局的新记录，不能改写旧证据或跳过冻结校验。2026-09-16已在此固定入口完成Ver 1.1 (044)的完整构建、211项原生测试及关键实机验收。

## 构建与版本

每次真实Mac App编译、打包前更新版本号：小修复使用Ver 1.0 (xxx)递增构建号；新增特性使用Ver 1.1；多个功能或大范围调整使用Ver 2.0。版本显示、包元数据和验收记录应一致，不能只改文件名。源码提交与真实构建须分别记账，不能把提交本身当作已完成编译或版本校验。

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

当前补丁为202个Chromium补丁和3个V8补丁，正式pin为153.0.8010.53。固定App为Ver 2.0 (061)，539项原生回归与已知P1、P2定向验收通过；057的75/90保留为历史，整体门槛未重新关闭。见[本批修复与后续范围](docs/audit/p1-p2-followup-2026-09-22.zh-CN.md)。

以下保留为2026-09-16历史记录（153个Chromium补丁、pin 153.0.8010.37）：固定App为Ver 2.0 (013)，完整构建、quality:fast与435项原生执行单次通过；同签名更新及版本/资料路径已核对。013修复中途接管后的旧批准入口，实机接管、暂停恢复不重放、取消与冷启动摘要通过。012已验证空/有效点击、脚本/302限制和规划换页。旧包及匹配资料与失败证据保留，详见[013本地验收](docs/audit/m2-local-acceptance-013-2026-09-16.zh-CN.md)。历史合并提交和备份边界见[main合并记录](docs/audit/main-consolidation-2026-09-10.md)。本机备份、资料、模型和失败证据保留在Git忽略目录，不等于远程备份或发行包。

[最新macOS修复与验证](docs/audit/summary-latency-2026-09-10.md)和[跨平台十项标准](docs/audit/aegis-browser-agent-v2-cross-platform-acceptance-2026-09-05.md)分别记录。源码提交不缩小实机、隐私、反钓鱼和本地Qwen验收要求，也不授权修改系统权限、生产发布或清理用户资料。

## 153升级后的单一写入口

2026-09-16将已验收044的pin、补丁和overlay共160个差异文件精确收敛到主仓库，恢复副本位于本机`.artifacts/integration-20260915/m1-main-before-convergence`。`upstream-candidate/product`冻结为044的历史构建输入，不再双向同步或承接新功能开发。后续产品修改只写本仓库；Chromium源码及Ninja输出保持现址，新构建从本仓库重新冻结输入并递增产品版本，不能改写044的清单。上游观察任务继续只读。

SDK27使用原Chromium LLVM版本加单个上游链接器兼容回补，原工具和验证证据保留。执行更新依赖或bootstrap前须检查回补身份，不得静默覆盖该工具或另建一套源码。详情见[044本地验收](docs/audit/m1-local-acceptance-044-2026-09-16.zh-CN.md)。
