# GCSA-aegis Browser — Chromium fork

这是**产品浏览器**宿主。目标是 fork Chromium，在引擎内置安全/隐私策略。  
**不做 Electron。不做「装扩展当浏览器」。**

`apps/extension` 仅作策略原型与参考实现；逻辑以 `packages/core` 为准，最终通过补丁接到 Chromium。

## 钉扎版本

| 文件 | 含义 |
|------|------|
| [CHROMIUM_VERSION](./CHROMIUM_VERSION) | Mac Stable 版本号（当前 `151.0.7922.77`） |
| [CHROMIUM_COMMIT](./CHROMIUM_COMMIT) | 对应 Chromium git commit |

## 目录

```text
apps/browser/
  args/aegis.gn          GN 参数
  patches/               打在 Chromium 上的补丁（series）
  scripts/               bootstrap / fetch / apply / build / run
  docs/                  fork 架构与桥接说明
```

Chromium 源码默认落在仓库外：

```text
~/Projects/GCSA-aegis-chromium/src
```

路径可写在 `apps/browser/.chromium-root`（已 gitignore）。

## 命令

在仓库根目录：

```bash
# 1) depot_tools
pnpm --filter @gcsa-aegis/browser bootstrap

# 2) 拉源码并 sync 到钉扎 commit（数十 GB，数小时）
pnpm --filter @gcsa-aegis/browser fetch

# 3) 应用补丁（0001–0023，见 patches/series）
pnpm --filter @gcsa-aegis/browser apply-patches

# 4) 开发编译（component，迭代快）
pnpm --filter @gcsa-aegis/browser build

# 4b) 分发编译（单个自包含 .app，慢）
pnpm --filter @gcsa-aegis/browser build:release

# 5) 运行开发包 / 分发包
pnpm --filter @gcsa-aegis/browser run
pnpm --filter @gcsa-aegis/browser run:release

# 6) 打包（默认要求 build:release 产物 → dist/GCSA-aegis.app + zip/dmg）
pnpm --filter @gcsa-aegis/browser package

# 7) 从 packages/core 同步规则快照 → overlay C++ .inc + JSON
pnpm --filter @gcsa-aegis/browser sync-core-snapshot

# 7b) 预编译 EasyList（可选；浏览器也会在运行时拉取）
pnpm --filter @gcsa-aegis/browser sync-easylist

# 7c) 打包 packages/core → JS 策略 worker（chrome://aegis + C++ 字面量）
pnpm --filter @gcsa-aegis/browser sync-policy-worker

# 状态
pnpm --filter @gcsa-aegis/browser status
```

- **开发**：`args/aegis.gn` → `out/Aegis`（component，快，不能当正式单包）
- **分发**：`args/aegis-release.gn` → `out/AegisRelease`（非 component，打成 `GCSA-aegis.app`）

也可直接：

```bash
export PATH="$HOME/depot_tools:$PATH"
bash apps/browser/scripts/bootstrap-depot-tools.sh
bash apps/browser/scripts/fetch-chromium.sh
```

## 架构原则

1. **策略在 `packages/core`**（TypeScript）— 检测、PII、设置模型  
2. **执行在 Chromium C++/Blink** — 网络、Cookie、指纹、UI  
3. Bridge：嵌入式 JS/WASM 策略 worker，或 C++ 调用导出的规则快照  
4. 设置面：`chrome://aegis` WebUI（补丁引入）

详见 [docs/fork-architecture.md](./docs/fork-architecture.md)。

## Android

只做 Android，跟桌面同一 Chromium 钉扎。macOS **不能**编 APK。说明与 Play 包名见 [docs/android.md](./docs/android.md)、[docs/play-store.md](./docs/play-store.md)。

```bash
# 仅 Linux
pnpm --filter @gcsa-aegis/browser build:android
pnpm --filter @gcsa-aegis/browser package:android
```

## 网络说明（macOS / 受限网络）

脚本会自动处理常见卡点：

1. **系统 HTTPS 代理**（如 Clash `127.0.0.1:6152`）— 未设 `https_proxy` 时从 `scutil --proxy` 读取
2. **`src` 从 GitHub 浅拉钉扎 tag** — 避免 googlesource 上百 MB 的 `refs/changes/*` 广告把 `ls-remote` 拖死
3. **vpython** — `VPYTHON_AR_URL=https://pypi.org/simple/`，并把私有 pin `pyyaml==5.4.1+chromium.1` 改成公开的 `pyyaml==6.0.2`

手动：

```bash
bash apps/browser/scripts/fix-vpython-network.sh
pnpm --filter @gcsa-aegis/browser fetch
```

进度：

```bash
du -sh ~/Projects/GCSA-aegis-chromium/src/.git
tail -f ~/Projects/GCSA-aegis-chromium-fetch.log
pnpm --filter @gcsa-aegis/browser status
```

源码目录：`~/Projects/GCSA-aegis-chromium/src`  
依赖仍可能从 googlesource 拉；请保持代理可用。

