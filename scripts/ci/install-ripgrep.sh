#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

select_ripgrep_release() {
  local operating_system="$1"
  local architecture="$2"

  case "${operating_system}/${architecture}" in
    Darwin/arm64)
      printf '%s %s\n' \
        aarch64-apple-darwin \
        3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4
      ;;
    Darwin/x86_64)
      printf '%s %s\n' \
        x86_64-apple-darwin \
        af7825fcc69a2afc7a7aea55fc9af90e26421d8f20fe59df32e233c0b8a231c1
      ;;
    Linux/x86_64)
      printf '%s %s\n' \
        x86_64-unknown-linux-musl \
        33e15bcf1624b25cdd2a55813a47a2f95dbe126268203e76aa6a585d1e7b149c
      ;;
    *)
      printf 'Unsupported ripgrep platform: %s/%s\n' "$operating_system" "$architecture" >&2
      return 1
      ;;
  esac
}

main() {
  : "${RUNNER_TEMP:?RUNNER_TEMP is required}"
  : "${GITHUB_PATH:?GITHUB_PATH is required}"

  local version=15.2.0
  local operating_system architecture target expected name archive url
  operating_system="$(uname -s)"
  architecture="$(uname -m)"
  read -r target expected < <(select_ripgrep_release "$operating_system" "$architecture")

  name="ripgrep-${version}-${target}"
  archive="${RUNNER_TEMP}/${name}.tar.gz"
  url="https://github.com/BurntSushi/ripgrep/releases/download/${version}/${name}.tar.gz"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "$archive" "$url"
  printf '%s  %s\n' "$expected" "$archive" | shasum -a 256 --check --status
  tar -xzf "$archive" -C "$RUNNER_TEMP"
  "${RUNNER_TEMP}/${name}/rg" --version
  printf '%s\n' "${RUNNER_TEMP}/${name}" >> "$GITHUB_PATH"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
