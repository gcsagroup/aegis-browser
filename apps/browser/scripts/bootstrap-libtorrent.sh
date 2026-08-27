#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../../.." && pwd)"
chromium_src="${GCSA_CHROMIUM_SRC:-$(cd -- "$repo_root/.." && pwd)/GCSA-aegis-chromium/src}"
dependency_root="$chromium_src/third_party/aegis_libtorrent"
archive_dir="$dependency_root/dist"
archive_path="$archive_dir/libtorrent-rasterbar-2.1.1.tar.gz"
source_dir="$dependency_root/source"
version="2.1.1"
expected_sha256="0f163516ecef2e3331500266751de3098835a3c3ae0c2290448046c632bc0e93"
source_url="https://sourceforge.net/projects/libtorrent.mirror/files/v2.1.1/libtorrent-rasterbar-2.1.1.tar.gz/download"

if [[ ! -d "$chromium_src" || ! -f "$chromium_src/BUILD.gn" ]]; then
  echo "未找到 Chromium src：$chromium_src" >&2
  echo "可通过 GCSA_CHROMIUM_SRC 指定源码目录。" >&2
  exit 1
fi

for command_name in curl shasum tar brew; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "缺少命令：$command_name" >&2
    exit 1
  fi
done

boost_prefix="$(brew --prefix boost)"
if [[ ! -f "$boost_prefix/include/boost/asio.hpp" ]]; then
  echo "缺少 Homebrew Boost 头文件。" >&2
  exit 1
fi

mkdir -p "$archive_dir"
if [[ ! -f "$archive_path" ]]; then
  curl --fail --location --proto '=https' --tlsv1.2 \
    --output "$archive_path" "$source_url"
fi

actual_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
  echo "libtorrent 源码包 SHA-256 不匹配。" >&2
  echo "期望：$expected_sha256" >&2
  echo "实际：$actual_sha256" >&2
  exit 1
fi

if [[ ! -f "$source_dir/CMakeLists.txt" ]]; then
  staging_dir="$(mktemp -d "$dependency_root/source-staging.XXXXXX")"
  cleanup_staging() {
    if [[ -d "$staging_dir" ]]; then
      find "$staging_dir" -depth -delete
    fi
  }
  trap cleanup_staging EXIT
  tar -xzf "$archive_path" -C "$staging_dir"
  extracted_dir="$staging_dir/libtorrent-rasterbar-$version"
  if [[ ! -f "$extracted_dir/CMakeLists.txt" ]]; then
    echo "源码包结构不符合预期。" >&2
    exit 1
  fi
  mv "$extracted_dir" "$source_dir"
  trap - EXIT
  cleanup_staging
fi

if [[ ! -f "$source_dir/src/session.cpp" ||
      ! -f "$source_dir/include/libtorrent/session.hpp" ||
      ! -f "$source_dir/COPYING" ]]; then
  echo "libtorrent 源码不完整。" >&2
  exit 1
fi

echo "libtorrent $version 已完成源码校验，Chromium GN 将使用同一 libc++ 编译。"
echo "source_sha256=$actual_sha256"
echo "tls_trackers=disabled (避免与 Chromium BoringSSL 混链；发布前需完成专门集成)"
