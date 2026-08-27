#!/usr/bin/env bash
# 给现有 checkout 打开 Android 依赖。只应在 Linux 上跑，避免撑爆这台 Mac 的磁盘。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "不要在 macOS 上给这份 checkout 加 target_os=android。"
  echo "会再拉数十 GB 依赖，且仍然编不出 APK。见 apps/browser/docs/android.md"
  exit 2
fi

if [[ ! -f "$CHROMIUM_ROOT/.gclient" ]]; then
  echo "没有 $CHROMIUM_ROOT/.gclient — 先 fetch。"
  exit 1
fi

# Linux 主机上 checkout_linux 仍为 true，会去拉 GTK 等桌面仓；Android APK 不需要。
# ARM64 没有 gperf 的 linux-arm64 CIPD，改用系统 gperf。
python3 - "$CHROMIUM_ROOT/.gclient" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
changed = False
# 旧键名无效：CIPD 实际名字带 :package
if '"src/third_party/gperf/cipd": None' in text and "gperf/linux-arm64" not in text:
    text = text.replace('      "src/third_party/gperf/cipd": None,\n', "")
    changed = True
if "target_os" not in text:
    text = text.rstrip() + '\n\ntarget_os = ["android"]\n'
    changed = True
wanted = {
    '"src/third_party/wayland-protocols/gtk": None',
    '"src/third_party/wayland-protocols/kde": None',
    '"src/third_party/gperf/cipd:infra/3pp/tools/gperf/linux-arm64": None',
    # 侧载 APK 不需要 CTS 包 / orderfile / mold；CIPD 经代理常 400。
    '"src/android_webview/tools/cts_archive/cipd:chromium/android_webview/tools/cts_archive": None',
    '"src/android_webview/tools/orderfiles/arm64:chromium/android_webview/tools/orderfiles/arm64": None',
    '"src/chrome/android/orderfiles/arm64:chromium/chrome/android/orderfiles/arm64": None',
    '"src/buildtools/third_party/mold/cipd:chromium/buildtools/third_party/mold/mold": None',
}
if '"custom_deps": {}' in text:
    text = text.replace(
        '"custom_deps": {}',
        '''"custom_deps": {
      "src/third_party/wayland-protocols/gtk": None,
      "src/third_party/wayland-protocols/kde": None,
      "src/third_party/gperf/cipd:infra/3pp/tools/gperf/linux-arm64": None,
      "src/android_webview/tools/cts_archive/cipd:chromium/android_webview/tools/cts_archive": None,
      "src/android_webview/tools/orderfiles/arm64:chromium/android_webview/tools/orderfiles/arm64": None,
      "src/chrome/android/orderfiles/arm64:chromium/chrome/android/orderfiles/arm64": None,
      "src/buildtools/third_party/mold/cipd:chromium/buildtools/third_party/mold/mold": None,
    }''',
        1,
    )
    changed = True
else:
    for item in wanted:
        if item not in text:
            text = text.replace(
                '"custom_deps": {',
                '"custom_deps": {\n      ' + item + ",",
                1,
            )
            changed = True
if changed:
    p.write_text(text)
    print("已更新 .gclient（android + 跳过 GTK/KDE/gperf CIPD）")
else:
    print(".gclient 已是 Android 配置")
print(p.read_text())
PY

if [[ "$(uname -m)" == "aarch64" ]]; then
  if ! command -v gperf >/dev/null; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gperf
  fi
  gperf_bin="$(command -v gperf)"
  dest="$CHROMIUM_ROOT/src/third_party/gperf/cipd/bin"
  mkdir -p "$dest"
  ln -sfn "$gperf_bin" "$dest/gperf"
  echo "gperf -> $dest/gperf"
fi
echo "下一步：pnpm --filter @gcsa-aegis/browser sync"
echo "然后：pnpm --filter @gcsa-aegis/browser build:android"
