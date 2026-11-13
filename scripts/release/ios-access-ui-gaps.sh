#!/usr/bin/env bash
# iOS only. Keep the simulator fixture on 127.0.0.1:8768 alive, then print
# the three Access UI gap tests. This script does not run xcodebuild.
# macOS bash 3.2: no mapfile and no associative arrays.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

ART="$ROOT/.artifacts/ios-access-closed-loop"
LOG="$ART/fixture-8768.log"
PIDFILE="$ART/fixture-8768.pid"
PORT=8768
URL="http://127.0.0.1:${PORT}/article"
DESTINATION="${AEGIS_IOS_DESTINATION:-platform=iOS Simulator,id=3D3C508E-B639-480E-9B06-C1D611B7B984}"
DERIVED="${AEGIS_IOS_DERIVED_DATA:-.artifacts/ios-access-closed-loop/logic/DerivedData}"
RESULT="${AEGIS_IOS_UI_GAPS_RESULT:-.artifacts/ios-access-closed-loop/ios-ui-gaps/result.xcresult}"

if [[ ! -f apps/ios/scripts/simulator-fixture-server.py ]]; then
  printf 'missing apps/ios/scripts/simulator-fixture-server.py\n' >&2
  exit 1
fi

port_open() {
  python3 - "$PORT" <<'PY'
import socket
import sys

sock = socket.socket()
sock.settimeout(0.5)
try:
    sock.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
PY
}

# nohup ignores SIGHUP. A new session keeps the fixture out of this shell's
# process group, so the server stays up after the launcher exits.
start_fixture() {
  mkdir -p "$ART"
  python3 - "$ROOT" "$LOG" "$PIDFILE" <<'PY'
import os
import signal
import sys

root, log_path, pid_path = sys.argv[1:]
os.chdir(root)
signal.signal(signal.SIGHUP, signal.SIG_IGN)
read_fd, write_fd = os.pipe()
starter = os.fork()
if starter > 0:
    os.close(write_fd)
    token = os.read(read_fd, 1)
    os.close(read_fd)
    raise SystemExit(0 if token == b"1" else 1)
os.close(read_fd)
os.setsid()
log_fd = os.open(log_path, os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o644)
null_fd = os.open(os.devnull, os.O_RDONLY)
server = os.fork()
if server > 0:
    with open(pid_path, "w", encoding="utf-8") as handle:
        handle.write("%s\n" % server)
    os.write(write_fd, b"1")
    os.close(write_fd)
    os._exit(0)
os.close(write_fd)
os.dup2(null_fd, 0)
os.dup2(log_fd, 1)
os.dup2(log_fd, 2)
if log_fd > 2:
    os.close(log_fd)
if null_fd > 2:
    os.close(null_fd)
os.execvp(
    "nohup",
    [
        "nohup",
        "python3",
        "apps/ios/scripts/simulator-fixture-server.py",
        "--port",
        "8768",
    ],
)
PY
}

article_code() {
  curl -sS -m 3 -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null || true
}

started=0
if ! port_open; then
  start_fixture || true
  started=1
fi

code=""
attempt=0
while [[ "$attempt" -lt 20 ]]; do
  code="$(article_code)"
  if [[ "$code" == "200" ]]; then
    break
  fi
  if [[ "$started" -eq 0 ]]; then
    break
  fi
  attempt=$((attempt + 1))
  sleep 0.25
done

if [[ "$code" != "200" ]]; then
  printf 'fixture GET /article failed (HTTP %s). Not continuing.\n' "${code:-000}" >&2
  printf 'log: %s\n' "$LOG" >&2
  exit 1
fi

if [[ "$started" -eq 1 ]] && command -v lsof >/dev/null 2>&1; then
  live="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | awk 'NR==1 { print; exit }' || true)"
  if [[ -n "${live:-}" ]]; then
    printf '%s\n' "$live" > "$PIDFILE"
  fi
fi

printf 'fixture %s -> 200\n' "$URL"
printf '%s\n' \
  "xcodebuild test \\" \
  "  -project apps/ios/Aegis.xcodeproj \\" \
  "  -scheme Aegis \\" \
  "  -destination '${DESTINATION}' \\" \
  "  -only-testing:AegisUITests/AegisUITests/testRealDownloadCompletesWithHash \\" \
  "  -only-testing:AegisUITests/AegisUITests/testWorkspaceSaveRestoreAndUndo \\" \
  "  -only-testing:AegisUITests/WebsiteEnhancementUITests/testAccessIntentIsolatedBetweenOrdinaryAndPrivateStores \\" \
  "  -parallel-testing-enabled NO \\" \
  "  -resultBundlePath '${RESULT}' \\" \
  "  -derivedDataPath '${DERIVED}' \\" \
  "  CODE_SIGNING_ALLOWED=YES"
