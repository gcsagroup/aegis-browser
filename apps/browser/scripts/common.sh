#!/usr/bin/env bash
# Resolve where the Chromium src checkout lives.
# Default: ~/Projects/GCSA-aegis-chromium (outside the git repo — large)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
DEFAULT_CHROMIUM_ROOT="${HOME}/Projects/GCSA-aegis-chromium"
MARKER="$ROOT_DIR/.chromium-root"

if [[ -f "$MARKER" ]]; then
  CHROMIUM_ROOT="$(cat "$MARKER" | tr -d '[:space:]')"
else
  CHROMIUM_ROOT="$DEFAULT_CHROMIUM_ROOT"
fi

DEPOT_TOOLS_DIR="${DEPOT_TOOLS_DIR:-$HOME/depot_tools}"
VERSION_FILE="$ROOT_DIR/CHROMIUM_VERSION"
COMMIT_FILE="$ROOT_DIR/CHROMIUM_COMMIT"

export ROOT_DIR REPO_ROOT CHROMIUM_ROOT DEPOT_TOOLS_DIR VERSION_FILE COMMIT_FILE MARKER
export DEPOT_TOOLS_UPDATE="${DEPOT_TOOLS_UPDATE:-0}"

read_pinned_value() {
  # first non-empty, non-comment line
  grep -vE '^\s*(#|$)' "$1" | head -n 1 | tr -d '[:space:]'
}

ensure_depot_tools_on_path() {
  if [[ -d "$DEPOT_TOOLS_DIR" ]]; then
    export PATH="$DEPOT_TOOLS_DIR:$PATH"
  fi
}

# Prefer GitHub for chromium/src — googlesource ls-remote advertises ~100MB+ of
# refs/changes/* and stalls hard behind many proxies / fake-ip DNS setups.
CHROMIUM_SRC_URL="${CHROMIUM_SRC_URL:-https://github.com/chromium/chromium.git}"
CHROMIUM_SRC_GOOGLESURCE_URL="${CHROMIUM_SRC_GOOGLESURCE_URL:-https://chromium.googlesource.com/chromium/src.git}"

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
