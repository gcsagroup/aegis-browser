# Overlay sources (pre-patch)

Files here are the intended Chromium-tree additions. Once `fetch` finishes, generate
the first real patch with:

```bash
# from chromium src after copying overlay into the tree:
git add chrome/browser/aegis chrome/common/aegis
git commit -m "Aegis: add stub service and feature flag"
git format-patch -1 -o /path/to/GCSA-aegis/apps/browser/patches/
# then list the file in patches/series
```

See [tree-layout.md](./tree-layout.md).
