# Overlay 源码与补丁同步规则

`overlay/` 保存 Browser 集成层的期望源码。它不是可独立运行的产品，也不能只修改这里而不更新 Chromium 补丁序列。

本地开发流程是：先在固定 Chromium base 上重放 `patches/series`，再把本次 overlay 差异同步到本地 Chromium 开发分支，编译并测试，最后把通过的本地提交导出为新的顺序补丁。旧补丁不原地改写；`status` 必须同时验证 patch-id、checkout 和 overlay 一致性。

当前阶段禁止 fetch、push 或使用 GitHub。完整目录边界见 [tree-layout.md](./tree-layout.md)。
