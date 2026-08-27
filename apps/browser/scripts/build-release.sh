#!/usr/bin/env bash
# Build a self-contained (non-component) Chromium.app for distribution.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ensure_depot_tools_on_path
detect_and_export_proxy >/dev/null 2>&1 || true

SRC="$CHROMIUM_ROOT/src"
OUT_REQUESTED="${OUT_DIR:-}"
ARGS_FILE="$ROOT_DIR/args/aegis-release.gn"

if [[ ! -d "$SRC" ]]; then
  echo "Chromium src missing — run fetch first."
  exit 1
fi

# 在任何 mkdir/mv/gn 写入前规范化并限定正式输出。build:release 只允许
# Chromium checkout 下唯一的 out/AegisRelease，不能借 OUT_DIR 写到别处。
SRC="$(cd "$SRC" && pwd -P)"
EXPECTED_OUT="$SRC/out/AegisRelease"
if [[ -z "$OUT_REQUESTED" ]]; then
  OUT_REQUESTED="$EXPECTED_OUT"
fi
if [[ "$OUT_REQUESTED" != "$EXPECTED_OUT" ]]; then
  echo "build:release OUT_DIR must be exactly: $EXPECTED_OUT" >&2
  echo "Refusing: $OUT_REQUESTED" >&2
  exit 1
fi
out_parent="$SRC/out"
if [[ -L "$out_parent" ]]; then
  echo "Release output parent must not be a symlink: $out_parent" >&2
  exit 1
fi
if [[ ! -e "$out_parent" ]]; then
  mkdir "$out_parent"
fi
if [[ ! -d "$out_parent" || "$(cd "$out_parent" && pwd -P)" != "$out_parent" ]]; then
  echo "Release output parent must be a real directory: $out_parent" >&2
  exit 1
fi
if [[ -L "$OUT_REQUESTED" ]]; then
  echo "Release OUT_DIR must not be a symlink: $OUT_REQUESTED" >&2
  exit 1
fi
OUT="$EXPECTED_OUT"
IDENTITY_DIR="$OUT/.aegis"
IDENTITY_HISTORY_DIR="$IDENTITY_DIR/history"
BUILD_INPUT="$IDENTITY_DIR/build-input.json"
BUILD_MANIFEST="$IDENTITY_DIR/build-manifest.json"
BUILD_LOCK="$IDENTITY_DIR/build.lock"

cd "$SRC"

# .aegis 及 history 是后续所有身份与归档写入的信任边界。先拒绝
# 预置 symlink，再规范化校验，避免在 identity begin 拒绝前已把旧产物
# 移到 OUT 之外。
if [[ -L "$IDENTITY_DIR" || -L "$IDENTITY_HISTORY_DIR" ]]; then
  echo "Release identity directories must not be symlinks: $IDENTITY_DIR" >&2
  exit 1
fi
mkdir -p "$IDENTITY_DIR"
if [[ "$(cd "$IDENTITY_DIR" && pwd -P)" != "$IDENTITY_DIR" ]]; then
  echo "Release identity directory resolves outside OUT: $IDENTITY_DIR" >&2
  exit 1
fi
for identity_file in \
  "$BUILD_INPUT" "$BUILD_INPUT.sha256" \
  "$BUILD_MANIFEST" "$BUILD_MANIFEST.sha256"; do
  if [[ -L "$identity_file" ]]; then
    echo "Release identity files must not be symlinks: $identity_file" >&2
    exit 1
  fi
done
if ! mkdir "$BUILD_LOCK" 2>/dev/null; then
  echo "Another build or package operation holds: $BUILD_LOCK" >&2
  exit 1
fi
release_build_lock() {
  rmdir "$BUILD_LOCK" 2>/dev/null || true
}
trap release_build_lock EXIT

# 一旦开始新构建，旧清单与旧 App 都不再代表“当前构建尝试”。在锁内
# 移到唯一 history 目录，确保 begin 阶段亲自观察到目标 App 不存在。
if [[ -f "$BUILD_INPUT" || -f "$BUILD_MANIFEST" || \
      -e "$OUT/Chromium.app" || -L "$OUT/Chromium.app" ]]; then
  if [[ -L "$IDENTITY_HISTORY_DIR" ]]; then
    echo "Release identity history must not be a symlink: $IDENTITY_HISTORY_DIR" >&2
    exit 1
  fi
  mkdir -p "$IDENTITY_HISTORY_DIR"
  if [[ "$(cd "$IDENTITY_HISTORY_DIR" && pwd -P)" != "$IDENTITY_HISTORY_DIR" ]]; then
    echo "Release identity history resolves outside OUT: $IDENTITY_HISTORY_DIR" >&2
    exit 1
  fi
  history="$IDENTITY_HISTORY_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  if [[ -e "$history" || -L "$history" ]] || ! mkdir "$history"; then
    echo "Refusing existing build history attempt: $history" >&2
    exit 1
  fi
  if [[ "$(cd "$history" && pwd -P)" != "$history" ]]; then
    echo "Build history attempt resolves outside OUT: $history" >&2
    exit 1
  fi
  for identity_file in \
    "$BUILD_INPUT" "$BUILD_INPUT.sha256" \
    "$BUILD_MANIFEST" "$BUILD_MANIFEST.sha256"; do
    if [[ -f "$identity_file" ]]; then
      mv "$identity_file" "$history/$(basename "$identity_file")"
    fi
  done
  if [[ -e "$OUT/Chromium.app" || -L "$OUT/Chromium.app" ]]; then
    mv "$OUT/Chromium.app" "$history/previous-Chromium.app"
  fi
fi
if [[ -e "$OUT/Chromium.app" || -L "$OUT/Chromium.app" ]]; then
  echo "Refusing to begin while the target App still exists: $OUT/Chromium.app" >&2
  exit 1
fi

echo "Generating $OUT with aegis-release.gn (is_component_build=false)…"
gn gen "$OUT" --args="$(cat "$ARGS_FILE")"

identity_begin=(
  --phase begin
  --output "$BUILD_INPUT"
  --out-dir "$OUT"
  --lock "$BUILD_LOCK"
  --artifact "$OUT/Chromium.app"
)
if [[ "${AEGIS_ALLOW_DIRTY_IDENTITY:-0}" == "1" ]]; then
  identity_begin+=(--allow-dirty)
fi
echo "Freezing build inputs before compilation…"
node "$ROOT_DIR/scripts/write-build-identity.mjs" "${identity_begin[@]}"

echo "Building chrome at $OUT (this can take a long time)…"
autoninja -C "$OUT" chrome

# 本地 ad-hoc 签名会修改 App 内的 Mach-O 字节，必须发生在身份清单
# finalize 之前。启动流程不得再对已绑定产物做任何签名或修补。
if [[ "$(uname -s)" == Darwin ]]; then
  bash "$ROOT_DIR/scripts/sign-chromium-app.sh" "$OUT/Chromium.app" "$OUT"
fi

echo "Finalizing source-to-artifact identity…"
node "$ROOT_DIR/scripts/write-build-identity.mjs" \
  --phase finalize \
  --input "$BUILD_INPUT" \
  --output "$BUILD_MANIFEST" \
  --out-dir "$OUT" \
  --artifact "$OUT/Chromium.app" \
  --lock "$BUILD_LOCK"
echo "Build complete: $OUT/Chromium.app"
du -sh "$OUT/Chromium.app"
echo "Build identity: $BUILD_MANIFEST"
