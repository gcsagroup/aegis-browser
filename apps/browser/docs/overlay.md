[**English**](./overlay.md) | [简体中文](./overlay.zh-CN.md) | [繁體中文](./overlay.zh-TW.md)

# Overlay source and patch synchronization rules

`overlay/` stores the intended source for the Browser integration layer. It is not a standalone product, and changes made here must also be reflected in the Chromium patch series.

The local development flow is to replay `patches/series` on the pinned Chromium base, synchronize the current overlay differences into a local Chromium development branch, build and test them, and finally export the validated local commits as new sequential patches. Existing patches are not rewritten in place; `status` must verify patch-id, checkout, and overlay consistency together.

At the current stage, fetching, pushing, or using GitHub is prohibited. See [tree-layout.md](./tree-layout.md) for the complete directory boundary.
