#!/usr/bin/env bash
# Resolve where the Chromium src checkout lives.
# Default: ~/Projects/GCSA-aegis-chromium (outside the git repo — large)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
DEFAULT_CHROMIUM_ROOT="${HOME}/Projects/GCSA-aegis-chromium"
MARKER="$ROOT_DIR/.chromium-root"

if [[ -z "${CHROMIUM_ROOT:-}" ]]; then
  if [[ -f "$MARKER" ]]; then
    CHROMIUM_ROOT="$(tr -d '[:space:]' < "$MARKER")"
  else
    CHROMIUM_ROOT="$DEFAULT_CHROMIUM_ROOT"
  fi
fi

DEPOT_TOOLS_DIR="${DEPOT_TOOLS_DIR:-$HOME/depot_tools}"
VERSION_FILE="$ROOT_DIR/CHROMIUM_VERSION"
COMMIT_FILE="$ROOT_DIR/CHROMIUM_COMMIT"

export ROOT_DIR REPO_ROOT CHROMIUM_ROOT DEPOT_TOOLS_DIR VERSION_FILE COMMIT_FILE MARKER
export DEPOT_TOOLS_UPDATE="${DEPOT_TOOLS_UPDATE:-0}"

normalized_gn_args() {
  awk '
    {
      sub(/[[:space:]]*#.*/, "")
      gsub(/[[:space:]]/, "")
      if (length > 0) print
    }
  ' "$1" | sort
}

gn_args_match() {
  local expected="$1"
  local actual="$2"
  diff -q <(normalized_gn_args "$expected") \
    <(normalized_gn_args "$actual") >/dev/null 2>&1
}

desktop_binary_path() {
  local out_dir="$1"
  local host_os="$2"

  case "$host_os" in
    Darwin) printf '%s/Chromium.app/Contents/MacOS/Chromium\n' "$out_dir" ;;
    Linux) printf '%s/chrome\n' "$out_dir" ;;
    *) return 1 ;;
  esac
}

verify_runnable_browser_output() {
  local label="$1"
  local out_dir="$2"
  local expected_component="$3"
  local args_template="$4"
  local src="$CHROMIUM_ROOT/src"
  local args_file="$out_dir/args.gn"
  local binary host actual_component artifact_epoch head_epoch newer_input

  host="$(uname -s)"
  if ! binary="$(desktop_binary_path "$out_dir" "$host")"; then
    printf '不支持当前宿主的桌面启动：%s\n' "$host" >&2
    return 1
  fi
  if [[ ! -x "$binary" ]]; then
    printf '%s 不完整，缺少可执行文件：%s\n' "$label" "$binary" >&2
    return 1
  fi
  if [[ ! -f "$args_file" ]] || ! gn_args_match "$args_template" "$args_file"; then
    printf '%s 的 args.gn 与 %s 不一致，拒绝启动。\n' \
      "$label" "$(basename "$args_template")" >&2
    return 1
  fi
  if grep -Eq '^[[:space:]]*is_component_build[[:space:]]*=[[:space:]]*true' \
    "$args_file"; then
    actual_component=true
  elif grep -Eq '^[[:space:]]*is_component_build[[:space:]]*=[[:space:]]*false' \
    "$args_file"; then
    actual_component=false
  else
    printf '%s 的 args.gn 未声明 is_component_build，拒绝启动。\n' "$label" >&2
    return 1
  fi
  if [[ "$actual_component" != "$expected_component" ]]; then
    printf '%s 构建类型不符：component=%s，预期=%s。\n' \
      "$label" "$actual_component" "$expected_component" >&2
    return 1
  fi

  artifact_epoch="$(stat -f '%m' "$binary" 2>/dev/null || stat -c '%Y' "$binary")"
  head_epoch="$(git -C "$src" show -s --format=%ct HEAD 2>/dev/null || true)"
  if [[ -n "$head_epoch" && "$artifact_epoch" -lt "$head_epoch" ]]; then
    printf '%s 早于 Chromium checkout HEAD，拒绝启动旧产物。\n' "$label" >&2
    return 1
  fi
  newer_input="$(find "$ROOT_DIR/patches" "$ROOT_DIR/overlay" "$args_template" \
    "$VERSION_FILE" "$COMMIT_FILE" -type f -newer "$binary" -print -quit \
    2>/dev/null || true)"
  if [[ -n "$newer_input" ]]; then
    printf '%s 已过期，存在更新输入：%s\n' "$label" "$newer_input" >&2
    return 1
  fi

  if [[ "$expected_component" == false ]]; then
    verify_release_manifest_inputs "$out_dir" || return 1
  fi

  printf '%s\n' "$binary"
}

has_user_data_dir_arg() {
  local arg

  for arg in "$@"; do
    if [[ "$arg" == --user-data-dir || "$arg" == --user-data-dir=* ]]; then
      return 0
    fi
  done
  return 1
}

resolve_user_data_dir_arg() {
  local default_profile="$1"
  shift
  local arg

  while [[ "$#" -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --user-data-dir=*)
        [[ -n "${arg#--user-data-dir=}" ]] || return 1
        printf '%s\n' "${arg#--user-data-dir=}"
        return
        ;;
      --user-data-dir)
        shift
        [[ "$#" -gt 0 && -n "$1" ]] || return 1
        printf '%s\n' "$1"
        return
        ;;
    esac
    shift
  done
  printf '%s\n' "$default_profile"
}

live_browser_pid_for_profile() {
  local profile="$1"
  local lock="$profile/SingletonLock"
  local target pid

  [[ -L "$lock" ]] || return 1
  target="$(readlink "$lock" 2>/dev/null || true)"
  pid="${target##*-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
}

ensure_profile_not_in_use() {
  local profile="$1"
  local pid

  if pid="$(live_browser_pid_for_profile "$profile")"; then
    printf 'Profile 正由 Chromium PID %s 使用，拒绝把请求路由到已有实例：%s\n' \
      "$pid" "$profile" >&2
    return 1
  fi
}

read_pinned_value() {
  # first non-empty, non-comment line
  grep -vE '^\s*(#|$)' "$1" | head -n 1 | tr -d '[:space:]'
}

portable_sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 1
  fi
}

verify_release_manifest_inputs() {
  local out_dir="$1"
  local manifest="$out_dir/.aegis/build-manifest.json"
  local sidecar="$manifest.sha256"
  local artifact expected_sha verification

  if [[ ! -f "$manifest" || ! -f "$sidecar" ]]; then
    printf '缺少 Release 构建身份清单或 SHA-256 sidecar：%s\n' "$manifest" >&2
    return 1
  fi
  expected_sha="$(awk 'NR == 1 {print $1}' "$sidecar" 2>/dev/null || true)"
  if [[ ! "$expected_sha" =~ ^[0-9a-f]{64}$ ]]; then
    printf 'Release 构建身份清单 sidecar 格式无效：%s\n' "$sidecar" >&2
    return 1
  fi

  case "$(uname -s)" in
    Darwin) artifact="$out_dir/Chromium.app" ;;
    Linux) artifact="$out_dir/chrome" ;;
    *)
      printf '当前宿主不支持 Release 产物身份校验：%s\n' "$(uname -s)" >&2
      return 1
      ;;
  esac

  if ! verification="$(node "$ROOT_DIR/scripts/write-build-identity.mjs" \
    --phase verify \
    --manifest "$manifest" \
    --expected-sha256 "$expected_sha" \
    --out-dir "$out_dir" \
    --artifact "$artifact" 2>&1)"; then
    printf 'Release 构建身份、构建图或产物校验失败：%s\n' "$verification" >&2
    return 1
  fi

  if [[ "${AEGIS_ALLOW_DIRTY_IDENTITY:-0}" != 1 ]] &&
    ! node -e '
      const fs = require("node:fs");
      const value = JSON.parse(fs.readFileSync(0, "utf8"));
      if (value.verified !== true || value.localCandidate !== true) process.exit(1);
    ' <<< "$verification"; then
    printf 'Release 构建身份不是干净源码生成的本地候选；诊断流程须显式设置 AEGIS_ALLOW_DIRTY_IDENTITY=1。\n' >&2
    return 1
  fi
}

ensure_depot_tools_on_path() {
  if [[ -d "$DEPOT_TOOLS_DIR" ]]; then
    export PATH="$DEPOT_TOOLS_DIR:$PATH"
  fi
}

# 默认使用 Chromium 官方上游。镜像只能通过 CHROMIUM_SRC_URL 显式指定；
# 本地状态与完整性检查不会发起网络请求。
CHROMIUM_SRC_GOOGLESOURCE_URL="${CHROMIUM_SRC_GOOGLESOURCE_URL:-https://chromium.googlesource.com/chromium/src.git}"
CHROMIUM_SRC_URL="${CHROMIUM_SRC_URL:-$CHROMIUM_SRC_GOOGLESOURCE_URL}"

detect_and_export_proxy() {
  # Always keep loopback off the proxy path (local pypi merge proxy, etc.).
  export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,::1}"
  case ",$NO_PROXY," in
    *,127.0.0.1,*) ;;
    *) export NO_PROXY="$NO_PROXY,127.0.0.1,localhost" ;;
  esac

  # Honor explicit env first.
  if [[ -n "${https_proxy:-${HTTPS_PROXY:-}}" || -n "${http_proxy:-${HTTP_PROXY:-}}" ]]; then
    export http_proxy="${http_proxy:-${HTTP_PROXY:-${https_proxy:-$HTTPS_PROXY}}}"
    export https_proxy="${https_proxy:-${HTTPS_PROXY:-$http_proxy}}"
    export HTTP_PROXY="${HTTP_PROXY:-$http_proxy}"
    export HTTPS_PROXY="${HTTPS_PROXY:-$https_proxy}"
    export ALL_PROXY="${ALL_PROXY:-$https_proxy}"
    return 0
  fi

  # macOS system HTTPS proxy (Clash / Surge / etc.)
  if command -v scutil >/dev/null 2>&1; then
    local proxy_host proxy_port
    proxy_host="$(scutil --proxy 2>/dev/null | awk '/HTTPProxy|HTTPSProxy/ {print $3; exit}')"
    proxy_port="$(scutil --proxy 2>/dev/null | awk '/HTTPPort|HTTPSPort/ {print $3; exit}')"
    if [[ -n "$proxy_host" && -n "$proxy_port" ]]; then
      local url="http://${proxy_host}:${proxy_port}"
      export http_proxy="$url" https_proxy="$url" HTTP_PROXY="$url" HTTPS_PROXY="$url" ALL_PROXY="$url"
      echo "Using system proxy $url"
      return 0
    fi
  fi
  return 0
}

configure_git_for_chromium_fetch() {
  detect_and_export_proxy
  # Session-only git settings (do not touch ~/.gitconfig).
  export GIT_CONFIG_COUNT=4
  export GIT_CONFIG_KEY_0=protocol.version
  export GIT_CONFIG_VALUE_0=2
  export GIT_CONFIG_KEY_1=http.version
  export GIT_CONFIG_VALUE_1=HTTP/1.1
  if [[ -n "${https_proxy:-}" ]]; then
    export GIT_CONFIG_KEY_2=http.proxy
    export GIT_CONFIG_VALUE_2="$https_proxy"
    export GIT_CONFIG_KEY_3=https.proxy
    export GIT_CONFIG_VALUE_3="$https_proxy"
  else
    export GIT_CONFIG_COUNT=2
  fi
  export GIT_TERMINAL_PROMPT=0
}
