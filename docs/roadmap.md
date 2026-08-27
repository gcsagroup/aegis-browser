# Roadmap

## Phase 0 — Scaffold ✅

- Monorepo、三语、core 策略、扩展原型

## Phase 1 — Extension prototype ✅

- Tracker / Phish / Privacy AI 在 MV3 扩展上可演示（参考实现）

## Phase 2 — Harden (core) ✅（初始）

- 链接清洗、Cookie 策略、Ollama/WebLLM 适配、轻量钓鱼加权

## Phase 3 — Chromium fork（当前主线）

- [x] 废弃 Electron 路线
- [x] 钉扎 Chromium Mac Stable `151.0.7922.77` + commit
- [x] depot_tools / fetch / build / run 脚本 + overlay 模板
- [x] 受限网络下 vpython workaround（PyPI + PyYAML pin）
- [x] 完成源码 `gclient sync` + `runhooks`（`~/Projects/GCSA-aegis-chromium/src` @ `151.0.7922.77`）
- [x] 补丁 0001：`AegisService` stub + feature flags（已进 `patches/series`）
- [x] 首次 `out/Aegis` 编译（`pnpm --filter @gcsa-aegis/browser build`）+ 冒烟验证
- [x] 补丁 0002：Net throttle（内置 tracker host 拦截子资源）
- [x] 补丁 0003：`chrome://aegis` WebUI（模块开关 + prefs）
- [x] 补丁 0004：钓鱼 interstitial
- [x] 补丁 0005：FingerprintGuard
- [x] 打包分发（.dmg / .zip）
- [x] 将 `packages/core` 规则快照打进树（0006）
- [x] 补丁 0007：EasyList 编译 + 运行时过滤列表更新器
- [x] 补丁 0008：导航清洗跟踪参数 + Cookie 分类清理
- [x] 补丁 0009：CNAME 伪装揭开 + bounce tracking 立即清 Cookie
- [x] 补丁 0010：钓鱼 URL 启发式评分 + 拦截页原因码
- [x] 补丁 0011：页面特征（密码框/紧迫文案）补强钓鱼评分
- [x] 补丁 0012：JS 策略 worker（gin + packages/core）+ 本地 Privacy AI / Ollama sidecar
- [x] 补丁 0013：WebGPU adapter.info farbling
- [x] 补丁 0014：启动 DCHECK 修复；策略 worker 在 chrome://aegis 运行
- [x] 补丁 0015：设置页 / 应用菜单 / macOS 菜单增加 `chrome://aegis` 入口
- [x] 补丁 0016：开关说明 + 本机 Ollama 地址/模型设置
- [x] 补丁 0017：启动后推迟过滤列表编译与 Cookie 清扫
- [x] 补丁 0018：EasyList 启动使用本地 compiled.json 缓存，24h 内不重新下载
- [x] 补丁 0019：EasyList 缓存更新策略（定时检查、条件请求、失败保留旧缓存）
- [x] 补丁 0020：拦截页人话与分数拆解、摘要未离机证明、会话清理清单
- [x] 补丁 0021：Cookie 精确名单（保留登录 Cookie）+ 第一方 /g/collect 等收集路径拦截
- [x] 补丁 0022：会话清单实时刷新、bounce 入日志、Canvas 自检、GA4 收集假象
- [x] 补丁 0023：拦截行可见、Referer 去参、Cookie 标注、本机 CDP/AI 控制
- [x] 补丁 0024：远程 CDP 隐藏内部页，并显示本机 agent 连接
- [x] 补丁 0025：本机 CDP 连接显示浏览器横幅，按钮打开 chrome://aegis
- [x] 补丁 0026：chrome://aegis 一次检测 Canvas / WebGL / Audio / WebGPU
- [x] 补丁 0027：Audio 指纹按站点只扰动一次，copyFromChannel 同样生效
- [x] 补丁 0028：WebGPU limits / subgroup 数值按站点稳定化
- [x] 补丁 0029：Android 可编入 chrome://aegis，显示名预留 Play 包名
- [x] 补丁 0030：Android 设置打开 chrome://aegis；手机上关掉 CDP/Ollama
- [x] Android M1a：Linux（UTM ARM64）编出 `chrome_public_apk` → `ChromePublic.apk`（包名 `app.gcsa.aegis`）
- [x] Android M1b：`package:android` → `apps/browser/dist/GCSA-aegis.apk`
- [x] Android M1c：真机侧载安装并启动（Pixel 9 Pro Fold；进入 FirstRun）
- [ ] Android M1d：完成首次运行向导后，打开网页 + `chrome://aegis` / 设置入口冒烟

## Later

- Android：同一 Chromium 151 钉扎，产物为侧载 APK，包名 `app.gcsa.aegis` 预留 Play。本机 Mac 只改补丁，编译在 Linux。
- Android 构建可复现：优先 x86_64 Linux；ARM64+qemu 路径需固化 workaround 文档。
- （无）桌面 Phase 3 主线已完成。后续增强见研究地图（WebLLM in-process、联邦指纹检测等）。
