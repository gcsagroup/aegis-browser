#!/usr/bin/env bash
# Work around Google Artifact Registry (us-python.pkg.dev) being unreachable:
# 1) Build local wheels for Chromium-only / sdist-only pins (e.g. crcmod)
# 2) Serve a merge proxy (local wheels + pypi.org) because vpython uses pip --isolated
# 3) Rewrite +chromium.N pins in cached requirements.txt files
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHEELHOUSE="${AEGIS_WHEELHOUSE:-$HOME/Projects/GCSA-aegis-chromium/.aegis-wheels}"
PROXY_PORT="${AEGIS_PYPI_PROXY_PORT:-4173}"
PROXY_URL="http://127.0.0.1:${PROXY_PORT}/simple/"
mkdir -p "$WHEELHOUSE/simple"

vpython_uid="$(id -u)"
VPYTHON_STORE_ROOTS=(
  "${HOME}/.cache/vpython-root.${vpython_uid}/store"
  "${HOME}/Library/Caches/vpython-root.${vpython_uid}/store"
)

find_vpython_cpython() {
  local root py
  for root in "${VPYTHON_STORE_ROOTS[@]}"; do
    [[ -d "$root" ]] || continue
    py="$(find "$root" -path '*/cpython+*/contents/bin/python3' 2>/dev/null | head -n 1 || true)"
    if [[ -n "$py" ]]; then
      echo "$py"
      return 0
    fi
  done
  return 1
}

pip_platform_args() {
  if [[ "$(uname -s)" == "Linux" ]]; then
    echo --python-version 311 --abi cp311 --abi abi3 \
      --platform manylinux_2_17_aarch64 --platform manylinux2014_aarch64 \
      --platform linux_aarch64 --platform any
  else
    echo --python-version 311 --abi cp311 \
      --platform macosx_11_0_arm64 --platform macosx_10_9_universal2 --platform any
  fi
}

# Prefer merge proxy so --isolated pip can see local crcmod wheels AND pypi.org.
# Set AEGIS_USE_PUBLIC_PYPI=1 to force plain PyPI (will break crcmod).
if [[ "${AEGIS_USE_PUBLIC_PYPI:-0}" == "1" ]]; then
  export VPYTHON_AR_URL="${VPYTHON_AR_URL:-https://pypi.org/simple/}"
else
  export VPYTHON_AR_URL="$PROXY_URL"
fi

patch_requirements() {
  local req="$1"
  [[ -f "$req" ]] || return 0
  local dirty=0
  if grep -q 'pyyaml==5\.4\.1+chromium' "$req" || grep -q '^pyyaml==5\.4\.1$' "$req"; then
    sed -i.bak -E 's/^pyyaml==5\.4\.1([+]chromium\.[0-9]+)?$/pyyaml==6.0.2/' "$req"
    dirty=1
  fi
  if grep -qE 'crcmod==1\.7([+]chromium\.[0-9]+)?' "$req"; then
    sed -i.bak -E 's/^crcmod==1\.7([+]chromium\.[0-9]+)?$/crcmod==1.7/' "$req"
    dirty=1
  fi
  if grep -qE '\+chromium\.[0-9]+' "$req"; then
    sed -i.bak -E 's/\+chromium\.[0-9]+//g' "$req"
    dirty=1
  fi
  # Yanked / unavailable on public PyPI — bump to nearest public wheel.
  if grep -q '^grpc-google-iam-v1==0\.12\.3$' "$req"; then
    sed -i.bak 's/^grpc-google-iam-v1==0\.12\.3$/grpc-google-iam-v1==0.12.4/' "$req"
    dirty=1
  fi
  # markupsafe 2.0.1 has no cp311 wheel left on PyPI.
  if grep -q '^markupsafe==2\.0\.1$' "$req"; then
    sed -i.bak 's/^markupsafe==2\.0\.1$/markupsafe==2.1.5/' "$req"
    dirty=1
  fi
  # lxml 4.9.3 没有 aarch64 的 manylinux wheel。
  if grep -q '^lxml==4\.9\.3$' "$req"; then
    sed -i.bak 's/^lxml==4\.9\.3$/lxml==4.9.4/' "$req"
    dirty=1
  fi
  # mozinfo 1.2.2 已从 PyPI 下架。
  if grep -q '^mozinfo==1\.2\.2$' "$req"; then
    sed -i.bak 's/^mozinfo==1\.2\.2$/mozinfo==1.2.3/' "$req"
    dirty=1
  fi
  # oauth2client 3.x 已无 binary。
  if grep -q '^oauth2client==3\.0\.0$' "$req"; then
    sed -i.bak 's/^oauth2client==3\.0\.0$/oauth2client==4.1.3/' "$req"
    dirty=1
  fi
  # psutil 5.8/5.9 没有可用的 cp311 aarch64 wheel。
  if grep -qE '^psutil==5\.(8\.0|9\.8)$' "$req"; then
    sed -i.bak -E 's/^psutil==5\.(8\.0|9\.8)$/psutil==6.1.1/' "$req"
    dirty=1
  fi
  # pycparser 2.19 已无 binary。
  if grep -q '^pycparser==2\.19$' "$req"; then
    sed -i.bak 's/^pycparser==2\.19$/pycparser==2.22/' "$req"
    dirty=1
  fi
  # pylsqpack 0.3.12 已无 binary。
  if grep -q '^pylsqpack==0\.3\.12$' "$req"; then
    sed -i.bak 's/^pylsqpack==0\.3\.12$/pylsqpack==0.3.18/' "$req"
    dirty=1
  fi
  if [[ "$dirty" -eq 1 ]]; then
    echo "Patched Chromium-only / yanked pins in $req"
  fi
}

ensure_local_wheel() {
  local spec="$1"
  local name="${spec%%=*}"
  local existing
  existing="$(find "$WHEELHOUSE" -maxdepth 1 -name "${name}-*.whl" -o -name "${name}-*.whl" 2>/dev/null | head -n 1 || true)"
  # also match PyYAML-style capitalized names
  if [[ -z "$existing" ]]; then
    existing="$(find "$WHEELHOUSE" -maxdepth 1 -iname "${name}-*.whl" 2>/dev/null | head -n 1 || true)"
  fi
  if [[ -z "$existing" ]]; then
    local py311
    py311="$(find_vpython_cpython || true)"
    if [[ -z "$py311" ]]; then
      echo "No vpython cpython yet — cannot build/download $spec wheel"
      return 0
    fi
    echo "Downloading/building wheel $spec -> $WHEELHOUSE"
    # shellcheck disable=SC2046
    "$py311" -m pip download --only-binary=:all: $(pip_platform_args) \
      "$spec" -d "$WHEELHOUSE" 2>/dev/null \
      || "$py311" -m pip download --only-binary=:all: "$spec" -d "$WHEELHOUSE" 2>/dev/null \
      || "$py311" -m pip wheel --no-deps "$spec" -w "$WHEELHOUSE"
    existing="$(find "$WHEELHOUSE" -maxdepth 1 -iname "${name}-*.whl" 2>/dev/null | head -n 1 || true)"
  fi
  if [[ -n "$existing" ]]; then
    local pkg
    pkg="$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
    mkdir -p "$WHEELHOUSE/simple/$pkg"
    cp -f "$existing" "$WHEELHOUSE/simple/$pkg/"
    local whl
    whl="$(basename "$existing")"
    cat > "$WHEELHOUSE/simple/$pkg/index.html" <<EOF
<!DOCTYPE html><html><body>
<a href="${whl}">${whl}</a>
</body></html>
EOF
    echo "Indexed local wheel $pkg -> $whl"
  else
    echo "WARNING: no wheel for $spec"
  fi
}

prefetch_requirements_wheels() {
  local req="$1"
  [[ -f "$req" ]] || return 0
  local py311
  py311="$(find_vpython_cpython || true)"
  [[ -n "$py311" ]] || return 0
  echo "Prefetching wheels from $req"
  # crcmod 1.7 没有公网 binary；整文件 -r 还会因某个下架 pin 全盘失败。
  # 逐条 --no-deps，已有 wheel 则跳过。
  local tmp name ver name_us
  tmp="$(mktemp)"
  grep -vE '^(crcmod)==' "$req" > "$tmp" || true
  while IFS= read -r spec || [[ -n "$spec" ]]; do
    [[ -z "$spec" || "$spec" == \#* || "$spec" == crcmod==* ]] && continue
    name="${spec%%=*}"
    ver="${spec##*=}"
    name_us="${name//-/_}"
    if find "$WHEELHOUSE" \( -iname "${name}-${ver}-*.whl" -o -iname "${name_us}-${ver}-*.whl" \) 2>/dev/null | grep -q .; then
      continue
    fi
    echo "Prefetch $spec"
    # shellcheck disable=SC2046
    env -u VPYTHON_AR_URL PIP_INDEX_URL="https://pypi.org/simple" PIP_DISABLE_PIP_VERSION_CHECK=1 \
      "$py311" -m pip download --only-binary=:all: --no-deps $(pip_platform_args) \
      "$spec" -d "$WHEELHOUSE" || true
  done < "$tmp"
  rm -f "$tmp"
  # Index ALL wheels per package (do not overwrite with the last file).
  python3 - "$WHEELHOUSE" <<'PY'
from pathlib import Path
import sys
wh = Path(sys.argv[1])
simple = wh / "simple"
simple.mkdir(parents=True, exist_ok=True)
pkgs: dict[str, list[Path]] = {}
for whl in list(wh.glob("*.whl")) + list(simple.glob("*/*.whl")):
    if not whl.is_file():
        continue
    pkg = whl.name.split("-", 1)[0].lower().replace("_", "-")
    pkgs.setdefault(pkg, []).append(whl)
for pkg, wheels in pkgs.items():
    d = simple / pkg
    d.mkdir(parents=True, exist_ok=True)
    names = []
    seen = set()
    for w in wheels:
        dest = d / w.name
        if w.resolve() != dest.resolve():
            dest.write_bytes(w.read_bytes())
        if w.name not in seen:
            seen.add(w.name)
            names.append(w.name)
    body = "\n".join(f'<a href="{n}">{n}</a><br/>' for n in sorted(names))
    (d / "index.html").write_text(f"<!DOCTYPE html><html><body>\n{body}\n</body></html>\n")
print(f"Indexed {len(pkgs)} local packages")
PY
}

refresh_simple_root_index() {
  {
    echo '<!DOCTYPE html><html><body>'
    for d in "$WHEELHOUSE"/simple/*/; do
      [[ -d "$d" ]] || continue
      pkg="$(basename "$d")"
      [[ "$pkg" == "simple" ]] && continue
      echo "<a href=\"${pkg}/\">${pkg}</a>"
    done
    echo '</body></html>'
  } > "$WHEELHOUSE/simple/index.html"
}

ensure_proxy() {
  refresh_simple_root_index
  export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,::1}"
  case ",$NO_PROXY," in
    *,127.0.0.1,*) ;;
    *) export NO_PROXY="$NO_PROXY,127.0.0.1,localhost" ;;
  esac

  # 脚本更新后需要重启 merge proxy（旧进程会挡住新版本）。
  if [[ "${AEGIS_RESTART_PYPI_PROXY:-0}" == "1" ]]; then
    pkill -f 'local-pypi-proxy.py' 2>/dev/null || true
    sleep 0.3
  elif curl -fsS --max-time 1 "$PROXY_URL" >/dev/null 2>&1; then
    echo "aegis-pypi-proxy already up at $PROXY_URL"
    return 0
  fi

  echo "Starting aegis-pypi-proxy on $PROXY_URL"
  nohup env http_proxy="${http_proxy:-}" https_proxy="${https_proxy:-}" \
    HTTP_PROXY="${HTTP_PROXY:-}" HTTPS_PROXY="${HTTPS_PROXY:-}" \
    NO_PROXY="$NO_PROXY" \
    python3 "$SCRIPT_DIR/local-pypi-proxy.py" \
    --wheelhouse "$WHEELHOUSE" \
    --port "$PROXY_PORT" \
    >>"$HOME/Projects/GCSA-aegis-chromium-pypi-proxy.log" 2>&1 &
  local i=0
  while (( i < 30 )); do
    if curl -fsS --max-time 1 "$PROXY_URL" >/dev/null 2>&1; then
      echo "aegis-pypi-proxy ready"
      return 0
    fi
    sleep 0.2
    i=$((i + 1))
  done
  echo "WARNING: aegis-pypi-proxy failed to start — see ~/Projects/GCSA-aegis-chromium-pypi-proxy.log"
  return 1
}

# Keep loopback off Clash / system proxy.
export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,::1}"

shopt -s nullglob
found=0
for root in "${VPYTHON_STORE_ROOTS[@]}"; do
  for req in "$root"/wheels+*/contents/requirements.txt; do
    found=1
    patch_requirements "$req"
    prefetch_requirements_wheels "$req"
  done
done
if [[ "$found" -eq 0 ]]; then
  echo "No cached wheels requirements yet — will patch after first vpython attempt if needed."
fi

ensure_local_wheel 'crcmod==1.7'
ensure_proxy || true

echo "VPYTHON_AR_URL=$VPYTHON_AR_URL"
echo "NO_PROXY=$NO_PROXY"

