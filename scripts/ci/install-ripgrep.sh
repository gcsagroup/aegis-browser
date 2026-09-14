#!/usr/bin/env bash
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"

version=15.2.0
case "$(uname -m)" in
  arm64)
    target=aarch64-apple-darwin
    expected=3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4
    ;;
  x86_64)
    target=x86_64-apple-darwin
    expected=af7825fcc69a2afc7a7aea55fc9af90e26421d8f20fe59df32e233c0b8a231c1
    ;;
  *)
    echo "Unsupported macOS architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

name="ripgrep-${version}-${target}"
archive="${RUNNER_TEMP}/${name}.tar.gz"
url="https://github.com/BurntSushi/ripgrep/releases/download/${version}/${name}.tar.gz"
curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "${archive}" "${url}"
printf '%s  %s\n' "${expected}" "${archive}" | shasum -a 256 --check --status
tar -xzf "${archive}" -C "${RUNNER_TEMP}"
"${RUNNER_TEMP}/${name}/rg" --version
printf '%s\n' "${RUNNER_TEMP}/${name}" >> "${GITHUB_PATH}"
