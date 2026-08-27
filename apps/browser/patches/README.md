# Patches

Patches in this directory are applied on top of the pinned Chromium commit
(`../CHROMIUM_COMMIT`) inside the local checkout.

## Conventions

1. Name files `0001-short-title.patch`, `0002-...`
2. List them in `series` in apply order
3. Prefer small, reviewable diffs that call into `aegis/` glue rather than rewriting Blink wholesale
4. Never vendor the full Chromium tree in this git repo

## First planned patches

| ID | Intent | Status |
|----|--------|--------|
| 0001 | Add `chrome/browser/aegis/` stub + feature flag | landed |
| 0002 | Wire network throttle / request cancel for tracker hosts | landed |
| 0003 | Embed `chrome://aegis` WebUI settings surface | landed |
| 0004 | Phish interstitial via navigation throttle | landed |
| 0005 | FingerprintGuard farbling hooks (canvas/audio/WebGL) | landed |
| 0006 | Bundle `packages/core` policy snapshot → C++ `.inc` + JSON | landed |
| 0007 | EasyList compiler + runtime filter-list updater | landed |
| 0008 | Strip tracking query params + cookie janitor | landed |
| 0009 | CNAME uncloak + bounce-tracker cookie clearing | landed |
| 0010 | Phish URL heuristics + explainable interstitial | landed |
| 0011 | Phish page-sense (password forms + urgency copy) | landed |
| 0012 | JS policy worker (gin) + Privacy AI / Ollama sidecar | landed |
| 0013 | WebGPU adapter.info farbling | landed |
| 0014 | 启动 DCHECK 修复；策略 worker 改在 chrome://aegis 运行 | landed |
| 0015 | 设置 / 菜单增加 chrome://aegis 入口 | landed |
| 0016 | 模块说明文案 + Ollama 模型设置 | landed |
| 0017 | 启动后推迟过滤列表/Cookie 清扫 | landed |
| 0018 | EasyList 启动走本地 compiled.json 缓存 | landed |
| 0019 | EasyList 缓存更新：24h 检查 / 304 / 失败退避 | landed |
| 0020 | 拦截页人话、摘要未离机证明、会话清理清单 | landed |
| 0021 | Cookie 精确名单 + 第一方收集路径拦截 | landed |
| 0022 | 会话清单实时刷新、Canvas 自检、GA4 收集假象 | landed |
| 0023 | 拦截可见、Referer 去参、Cookie 标注、本机 CDP/AI 控制 | landed |
| 0024 | 远程 CDP 隐藏内部页，会话清单显示 agent 连接 | landed |
| 0025 | 本机 CDP 连接显示浏览器横幅，按钮打开 chrome://aegis | landed |
| 0026 | chrome://aegis 一次检测 Canvas / WebGL / Audio / WebGPU | landed |
| 0027 | Audio 指纹按站点只扰动一次；copyFromChannel 同样生效 | landed |
| 0028 | WebGPU limits / subgroup 数值按站点稳定化 | landed |
| 0029 | Android：chrome://aegis 可进包，显示名/包名预留 Play | landed |
| 0030 | Android 设置打开 chrome://aegis；手机上关掉 CDP/Ollama | landed |

Apply with `pnpm --filter @gcsa-aegis/browser apply-patches` on a clean pin checkout.
