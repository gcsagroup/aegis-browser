#!/usr/bin/env bash
# Called only by the trusted private build job. Additional arguments configure signing/version.
set +x
set -euo pipefail
case "${1:-}" in
  dev|alpha) channel=$1; shift ;;
  *) echo "Private test-node builds require dev or alpha." >&2; exit 2 ;;
esac
node_uri=${AEGIS_ACCESS_TEST_NODE_URI:?Set the private test-node URI in the protected environment}
unset AEGIS_ACCESS_TEST_NODE_URI
# Xcode may log build settings and phase environments. Give it a path only.
original_umask=$(umask)
umask 077
private_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/aegis-private-node.XXXXXXXX")
input="$private_dir/node.vless"
cleanup() {
  if [[ $? == 0 ]]; then
    rm -f "$input"
    rm -rf "$private_dir/DerivedData"
  else
    rm -rf "$private_dir"
  fi
}
trap cleanup EXIT
printf '%s\n' "$node_uri" > "$input"
unset node_uri
umask "$original_umask"
project="$(cd "$(dirname "$0")/../../apps/ios" && pwd)/Aegis.xcodeproj"
xcodebuild -project "$project" -scheme Aegis -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$private_dir/DerivedData" -archivePath "$private_dir/Aegis.xcarchive" \
  "$@" AEGIS_ACCESS_RELEASE_CHANNEL="$channel" AEGIS_PRIVATE_TEST_NODE_FILE="$input" archive
# Check the finished app before handing the archive to the private signer.
python3 - "$private_dir/Aegis.xcarchive/Products/Applications/Aegis.app" "$channel" "$input" <<'VERIFY'
from pathlib import Path
import plistlib
import sys

app, channel, source = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
info = plistlib.loads((app / 'Info.plist').read_bytes())
for bundle in (app, app / 'PlugIns/SafariWebExtension.appex', app / 'PlugIns/ShareExtension.appex'):
    if plistlib.loads((bundle / 'Info.plist').read_bytes()).get('AegisReleaseProfile') != channel:
        sys.exit('Private archive release profile mismatch: ' + bundle.name)
if (info.get('AegisAccessReleaseChannel') != channel or
        (app / 'AegisPrivateTestNode.vless').read_bytes() != source.read_bytes().strip()):
    sys.exit('Private archive channel or packaged test node differs from requested input.')
VERIFY
echo "IOS_PRIVATE_ARCHIVE=$private_dir/Aegis.xcarchive"
