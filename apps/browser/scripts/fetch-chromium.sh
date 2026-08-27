#!/usr/bin/env bash
# Fetch or sync Chromium at the pinned commit.
# Checkout lives OUTSIDE the GCSA-aegis git repo by default (~ /Projects/GCSA-aegis-chromium).
#
# Bootstraps src from GitHub (not googlesource) to avoid 100MB+ refs/changes ads.
# Uses a shallow tag fetch + retries — full partial clones often drop mid-transfer via proxy.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

SYNC_ONLY=0
if [[ "${1:-}" == "--sync-only" ]]; then
  SYNC_ONLY=1
fi

ensure_depot_tools_on_path
configure_git_for_chromium_fetch
export DEPOT_TOOLS_UPDATE="${DEPOT_TOOLS_UPDATE:-0}"
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fix-vpython-network.sh"

if ! command -v gclient >/dev/null; then
  echo "depot_tools missing — run: pnpm --filter @gcsa-aegis/browser bootstrap"
  exit 1
fi

COMMIT="$(read_pinned_value "$COMMIT_FILE")"
VERSION="$(read_pinned_value "$VERSION_FILE")"
echo "Pinned Chromium $VERSION @ $COMMIT"
echo "Checkout root: $CHROMIUM_ROOT"
echo "src remote: $CHROMIUM_SRC_URL"
mkdir -p "$CHROMIUM_ROOT"
echo "$CHROMIUM_ROOT" > "$MARKER"

cd "$CHROMIUM_ROOT"

write_gclient_config() {
  cat > "$CHROMIUM_ROOT/.gclient" <<EOF
solutions = [
  {
    "name": "src",
    "url": "${CHROMIUM_SRC_URL}",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {},
  },
]
EOF
}

git_retry() {
  local attempt=1
  local max="${FETCH_MAX_ATTEMPTS:-8}"
  local delay=5
  while true; do
    echo "→ git $*  (attempt ${attempt}/${max})"
    if git -c http.version=HTTP/1.1 \
      -c http.postBuffer=524288000 \
      -c http.lowSpeedLimit=1000 \
      -c http.lowSpeedTime=120 \
      "$@"; then
      return 0
    fi
    if [[ "$attempt" -ge "$max" ]]; then
      echo "git failed after ${max} attempts: $*"
      return 1
    fi
    echo "retry in ${delay}s..."
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay < 120 ? delay * 2 : 120))
  done
}

bootstrap_src_shallow() {
  write_gclient_config
  rm -rf "$CHROMIUM_ROOT/src"
  mkdir -p "$CHROMIUM_ROOT/src"
  cd "$CHROMIUM_ROOT/src"
  git init
  git remote add origin "$CHROMIUM_SRC_URL"
  # Shallow tag only — avoids multi-GB full history transfer that dies mid-proxy.
  git_retry fetch --depth 1 --no-tags origin "refs/tags/${VERSION}:refs/tags/${VERSION}"
  git checkout --force "$COMMIT"
  # Confirm pin
  local head
  head="$(git rev-parse HEAD)"
  if [[ "$head" != "$COMMIT" ]]; then
    echo "ERROR: checked out $head, expected $COMMIT"
    exit 1
  fi
  echo "src @ $(git rev-parse --short HEAD) (shallow tag ${VERSION})"
}

update_src_to_pin() {
  cd "$CHROMIUM_ROOT/src"
  if [[ ! -f "$CHROMIUM_ROOT/.gclient" ]]; then
    write_gclient_config
  fi
  echo "Updating existing checkout to $COMMIT..."
  git remote set-url origin "$CHROMIUM_SRC_URL" || true
  if [[ "$(git rev-parse HEAD 2>/dev/null || true)" == "$COMMIT" ]]; then
    echo "src 已在 $COMMIT，跳过 checkout --force（避免冲掉已 rsync 的 v8 等嵌套仓）"
  elif git cat-file -e "${COMMIT}^{commit}" 2>/dev/null; then
    git checkout --force "$COMMIT"
  else
    git_retry fetch --depth 1 --no-tags origin "refs/tags/${VERSION}:refs/tags/${VERSION}" \
      || git_retry fetch --depth 1 origin "$COMMIT"
    git checkout --force "$COMMIT"
  fi
}

if [[ ! -d "$CHROMIUM_ROOT/src/.git" ]]; then
  if [[ "$SYNC_ONLY" -eq 1 ]]; then
    echo "No checkout found; refusing --sync-only. Run without the flag first."
    exit 1
  fi
  echo "Bootstrapping chromium src (shallow tag ${VERSION})..."
  bootstrap_src_shallow
else
  update_src_to_pin
fi

cd "$CHROMIUM_ROOT"
echo "gclient sync to src@$COMMIT (deps still come from googlesource; proxy helps)..."

# Chromium 151 的 gperf CIPD 没有 linux-arm64；ARM 主机改拉 linux-amd64，靠 qemu-user 跑。
if [[ "$(uname -m)" == "aarch64" && -f "$CHROMIUM_ROOT/src/DEPS" ]]; then
  python3 - "$CHROMIUM_ROOT/src/DEPS" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old, new = "infra/3pp/tools/gperf/${{platform}}", "infra/3pp/tools/gperf/linux-amd64"
if old in t:
    p.write_text(t.replace(old, new, 1))
    print("DEPS: gperf CIPD -> linux-amd64")
PY
  git -C "$CHROMIUM_ROOT/src" update-index --skip-worktree DEPS || true
fi

gclient_sync_with_retries() {
  local attempt=1
  local max="${GCLIENT_MAX_ATTEMPTS:-6}"
  local delay=15
  while true; do
    echo "→ gclient sync (attempt ${attempt}/${max})"
    # Re-apply vpython pin fixes each attempt — new wheel bundles may appear mid-sync.
    # shellcheck disable=SC1091
    # ROOT_DIR 在 common.sh 里已是绝对路径；cwd 此时已在 Chromium 根目录。
    source "$ROOT_DIR/scripts/fix-vpython-network.sh"
    if gclient sync --jobs=8 --with_branch_heads --with_tags -D --revision "src@$COMMIT"; then
      return 0
    fi
    if [[ "$attempt" -ge "$max" ]]; then
      echo "gclient sync failed after ${max} attempts"
      return 1
    fi
    echo "gclient failed; retry in ${delay}s..."
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay < 180 ? delay * 2 : 180))
  done
}

gclient_sync_with_retries

echo "Chromium tree ready at $CHROMIUM_ROOT/src"
echo "Next:"
echo "  pnpm --filter @gcsa-aegis/browser apply-patches"
echo "  pnpm --filter @gcsa-aegis/browser build"
