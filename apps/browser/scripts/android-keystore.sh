#!/usr/bin/env bash
# 生成 Play 上传密钥（不入库）。侧载 APK 仍用 Chromium 默认 debug 签名即可。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

KEYSTORE="${AEGIS_PLAY_KEYSTORE:-$ROOT_DIR/android/play-upload.keystore}"
ALIAS="${AEGIS_PLAY_KEY_ALIAS:-upload}"
mkdir -p "$(dirname "$KEYSTORE")"

if [[ -f "$KEYSTORE" ]]; then
  echo "已存在 $KEYSTORE — 不覆盖。"
  exit 0
fi

if [[ -z "${AEGIS_PLAY_STORE_PASS:-}" ]]; then
  cat <<EOF
未设置 AEGIS_PLAY_STORE_PASS，不生成密钥。

Play 上传密钥只应出现一次，并备份离线。生成：

  export AEGIS_PLAY_STORE_PASS='…强密码…'
  bash apps/browser/scripts/android-keystore.sh

密钥路径：$KEYSTORE
别名：$ALIAS
EOF
  exit 2
fi

keytool -genkeypair \
  -keystore "$KEYSTORE" \
  -alias "$ALIAS" \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000 \
  -storepass "$AEGIS_PLAY_STORE_PASS" \
  -keypass "$AEGIS_PLAY_STORE_PASS" \
  -dname "CN=GCSA-aegis, OU=GCSA, O=GCSA, L=Local, ST=Local, C=CN"

echo "已写入 $KEYSTORE"
echo "不要提交 git。Play Console 开启 Play App Signing 后，这个文件只当 upload key。"
