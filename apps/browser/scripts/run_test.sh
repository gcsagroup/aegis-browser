#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

has_user_data_dir_arg --foo --user-data-dir=/tmp/aegis || \
  fail "应识别 --user-data-dir=PATH"
has_user_data_dir_arg --foo --user-data-dir /tmp/aegis || \
  fail "应识别分离形式的 --user-data-dir"
if has_user_data_dir_arg --foo --bar; then
  fail "不应误判普通参数"
fi
[[ "$(resolve_user_data_dir_arg /tmp/default --foo)" == /tmp/default ]] || \
  fail "应返回默认 Profile"
[[ "$(resolve_user_data_dir_arg /tmp/default --user-data-dir=/tmp/explicit)" == \
  /tmp/explicit ]] || fail "应解析等号形式的显式 Profile"
[[ "$(resolve_user_data_dir_arg /tmp/default --user-data-dir /tmp/split)" == \
  /tmp/split ]] || fail "应解析分离形式的显式 Profile"
if resolve_user_data_dir_arg /tmp/default --user-data-dir >/dev/null 2>&1; then
  fail "缺少 Profile 路径必须失败"
fi

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/aegis-run-test.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
CHROMIUM_ROOT="$fixture_root/chromium"
fixture_src="$CHROMIUM_ROOT/src"
fixture_out="$fixture_src/out/Test"
mkdir -p "$fixture_out"

profile_fixture="$fixture_root/profile"
mkdir -p "$profile_fixture"
ln -s "fixture-$$" "$profile_fixture/SingletonLock"
[[ "$(live_browser_pid_for_profile "$profile_fixture")" == "$$" ]] || \
  fail "应识别活跃 Chromium Profile lock"
if ensure_profile_not_in_use "$profile_fixture" >/dev/null 2>&1; then
  fail "活跃 Profile 必须拒绝启动"
fi

git -C "$fixture_src" init -q
git -C "$fixture_src" -c user.name=Aegis -c user.email=aegis@localhost \
  commit -q --allow-empty -m base
mkdir -p "$fixture_src/v8"
git -C "$fixture_src/v8" init -q
git -C "$fixture_src/v8" -c user.name=Aegis -c user.email=aegis@localhost \
  commit -q --allow-empty -m base
cp "$ROOT_DIR/args/aegis.gn" "$fixture_out/args.gn"

case "$(uname -s)" in
  Darwin)
    fixture_binary="$fixture_out/Chromium.app/Contents/MacOS/Chromium"
    ;;
  Linux)
    fixture_binary="$fixture_out/chrome"
    ;;
  *)
    printf 'SKIP: run fixture 不支持当前宿主\n'
    exit 0
    ;;
esac
mkdir -p "$(dirname "$fixture_binary")"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture_binary"
chmod +x "$fixture_binary"
touch "$fixture_binary"

actual="$(verify_runnable_browser_output \
  "fixture component" "$fixture_out" true "$ROOT_DIR/args/aegis.gn")"
[[ "$actual" == "$fixture_binary" ]] || fail "有效 component fixture 应通过"

manifest="$fixture_out/.aegis/build-manifest.json"
mkdir -p "$(dirname "$manifest")"
printf '{"schemaVersion":2,"kind":"incomplete"}\n' > "$manifest"
printf '%s  build-manifest.json\n' "$(portable_sha256_file "$manifest")" > "$manifest.sha256"
cp "$ROOT_DIR/args/aegis-release.gn" "$fixture_out/args.gn"
if AEGIS_ALLOW_DIRTY_IDENTITY=1 verify_runnable_browser_output \
  "fixture Release" "$fixture_out" false "$ROOT_DIR/args/aegis-release.gn" \
  >/dev/null 2>&1; then
  fail "非 schema v3 完整身份清单必须拒绝启动"
fi

printf 'is_component_build = true\n' > "$fixture_out/args.gn"
if verify_runnable_browser_output \
  "fixture component" "$fixture_out" true "$ROOT_DIR/args/aegis.gn" \
  >/dev/null 2>&1; then
  fail "GN 参数漂移必须拒绝启动"
fi

cp "$ROOT_DIR/args/aegis.gn" "$fixture_out/args.gn"
git -C "$fixture_src" -c user.name=Aegis -c user.email=aegis@localhost \
  commit -q --allow-empty -m newer
touch -t 202001010000 "$fixture_binary"
if verify_runnable_browser_output \
  "fixture component" "$fixture_out" true "$ROOT_DIR/args/aegis.gn" \
  >/dev/null 2>&1; then
  fail "早于 checkout HEAD 的产物必须拒绝启动"
fi

printf 'PASS: run preflight fixture\n'
