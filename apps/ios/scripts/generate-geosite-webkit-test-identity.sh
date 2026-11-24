#!/bin/sh
# Generate a loopback server identity only for the AegisTests bundle.
set -eu
umask 077

scratch=$(mktemp -d "${TMPDIR:-/tmp}/geosite-webkit-tls.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
output=${SCRIPT_OUTPUT_FILE_0:?}

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 2 \
  -subj '/CN=Aegis loopback XCTest' \
  -addext 'subjectAltName=DNS:www.douban.com,DNS:beta-hold-control.invalid' \
  -addext 'basicConstraints=critical,CA:FALSE' \
  -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
  -addext 'extendedKeyUsage=serverAuth' \
  -out "$scratch/cert.pem" -keyout "$scratch/key.pem" 2> "$scratch/openssl.log" || {
  cat "$scratch/openssl.log" >&2
  exit 1
}
/usr/bin/openssl pkcs12 -export -in "$scratch/cert.pem" -inkey "$scratch/key.pem" \
  -passout pass:web-kit-fixture -out "$scratch/identity.p12"
mkdir -p "$(dirname "$output")"
mv "$scratch/identity.p12" "$output"
