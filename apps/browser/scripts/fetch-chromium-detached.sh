#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
LOG="${AEGIS_CHROMIUM_FETCH_LOG:-${CHROMIUM_ROOT}-fetch.log}"
exec >>"$LOG" 2>&1
echo "==== fetch start $(date -Iseconds) pid=$$ ===="
# shellcheck disable=SC1091
source "$SCRIPT_DIR/fix-vpython-network.sh"
configure_git_for_chromium_fetch
export PATH="${HOME}/depot_tools:$PATH"
export DEPOT_TOOLS_UPDATE=0
export PYTHONUNBUFFERED=1
echo "proxy=${https_proxy:-none}"
echo "src_url=$CHROMIUM_SRC_URL"
bash "$SCRIPT_DIR/fetch-chromium.sh"
echo "==== fetch done $(date -Iseconds) exit=$? ===="
