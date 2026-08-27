# GCSA-aegis

本地优先的隐私安全**浏览器**（Chromium fork）：内置本地隐私 AI、反钓鱼、去广告/反追踪。

- **主产品**：Chromium fork（`apps/browser`）— 不做 Electron、不以扩展当产品
- **参考实现**：MV3 扩展（`apps/extension`）用于策略验证
- UI 语言：简体中文（默认）/ 繁体中文 / English

## 产品形态

**主产品：Chromium fork 浏览器**（`apps/browser`）。不做 Electron。  
`apps/extension` 仅作策略原型 / 参考实现。

## 快速开始（Chromium fork）

```bash
pnpm install
pnpm --filter @gcsa-aegis/browser bootstrap   # 安装 depot_tools
pnpm --filter @gcsa-aegis/browser fetch       # 拉 Chromium（数十 GB，耗时长）
pnpm --filter @gcsa-aegis/browser build
pnpm --filter @gcsa-aegis/browser run
```

详情见 [apps/browser/README.md](apps/browser/README.md)。

### 扩展原型（可选）

```bash
pnpm --filter @gcsa-aegis/extension build
# Chrome → 加载 apps/extension/dist
```

## 仓库结构

```text
apps/browser       Chromium fork（产品主线：脚本 / GN / patches）
apps/extension     MV3 策略原型（参考）
packages/core      策略与检测（无 chrome.*）
packages/i18n      zh-CN / zh-TW / en
packages/model-runtime
packages/ui
docs/              架构 / 路线图 / 论文映射
```

## 文档

- [产品介绍](docs/product.html)
- [Architecture](docs/architecture.md)
- [Roadmap](docs/roadmap.md)
- [Browser fork](apps/browser/README.md)
- [Android / Play 预留](apps/browser/docs/android.md)
- [Research map](docs/research-map.md)

## 许可

Apache-2.0 — 见 [LICENSE](LICENSE)。

## 测试

```bash
pnpm test
```

`packages/core` 与 `packages/i18n` / `model-runtime` 含 Vitest 单测。
