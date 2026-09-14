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

mtime_tools="$fixture_root/mtime-tools"
mtime_input="$fixture_root/mtime-input"
mkdir -p "$mtime_tools"
touch "$mtime_input"
cat > "$mtime_tools/uname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${AEGIS_TEST_UNAME:?}"
EOF
cat > "$mtime_tools/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${AEGIS_TEST_STAT_INVALID:-0}" == 1 ]]; then
  printf '%s\n' 'filesystem information, not an epoch'
  exit 0
fi
if [[ -n "${AEGIS_TEST_STAT_EXIT:-}" ]]; then
  exit "$AEGIS_TEST_STAT_EXIT"
fi
case "${AEGIS_TEST_UNAME:?}" in
  Darwin)
    [[ "$#" -eq 3 && "$1" == -f && "$2" == %m && "$3" == "$AEGIS_TEST_MTIME_FILE" ]]
    printf '%s\n' 1700000001
    ;;
  Linux)
    [[ "$#" -eq 3 && "$1" == -c && "$2" == %Y && "$3" == "$AEGIS_TEST_MTIME_FILE" ]]
    printf '%s\n' 1700000002
    ;;
  *) exit 91 ;;
esac
EOF
chmod +x "$mtime_tools/uname" "$mtime_tools/stat"
mtime_path="$mtime_tools:$PATH"
mtime_runner="$fixture_root/mtime-runner.sh"
cat > "$mtime_runner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$1"
portable_file_mtime "$2"
EOF
darwin_mtime="$(env \
  PATH="$mtime_path" AEGIS_TEST_UNAME=Darwin AEGIS_TEST_MTIME_FILE="$mtime_input" \
  bash "$mtime_runner" "$SCRIPT_DIR/common.sh" "$mtime_input")"
[[ "$darwin_mtime" == 1700000001 ]] || fail "BSD stat mtime 参数必须明确"
linux_mtime="$(env \
  PATH="$mtime_path" AEGIS_TEST_UNAME=Linux AEGIS_TEST_MTIME_FILE="$mtime_input" \
  bash "$mtime_runner" "$SCRIPT_DIR/common.sh" "$mtime_input")"
[[ "$linux_mtime" == 1700000002 ]] || fail "GNU stat mtime 参数必须明确"
if env PATH="$mtime_path" AEGIS_TEST_UNAME=Darwin \
  AEGIS_TEST_MTIME_FILE="$mtime_input" AEGIS_TEST_STAT_INVALID=1 \
  bash "$mtime_runner" "$SCRIPT_DIR/common.sh" "$mtime_input" >/dev/null 2>&1; then
  fail "非整数 stat 输出必须拒绝"
fi
if env PATH="$mtime_path" AEGIS_TEST_UNAME=FreeBSD AEGIS_TEST_MTIME_FILE="$mtime_input" \
  bash "$mtime_runner" "$SCRIPT_DIR/common.sh" "$mtime_input" >/dev/null 2>&1; then
  fail "未知 stat 平台必须拒绝"
fi

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

fixture_host="$(uname -s)"
case "$fixture_host" in
  Darwin)
    fixture_binary="$fixture_out/GCSA Aegis.app/Contents/MacOS/GCSA Aegis"
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

if PATH="$mtime_path" AEGIS_TEST_UNAME="$fixture_host" \
  AEGIS_TEST_MTIME_FILE="$fixture_binary" AEGIS_TEST_STAT_INVALID=1 \
  verify_runnable_browser_output \
    "fixture component" "$fixture_out" true "$ROOT_DIR/args/aegis.gn" \
    >/dev/null 2>&1; then
  fail "启动验证必须拒绝非整数 stat 输出"
fi
if PATH="$mtime_path" AEGIS_TEST_UNAME="$fixture_host" \
  AEGIS_TEST_MTIME_FILE="$fixture_binary" AEGIS_TEST_STAT_EXIT=73 \
  verify_runnable_browser_output \
    "fixture component" "$fixture_out" true "$ROOT_DIR/args/aegis.gn" \
    >/dev/null 2>&1; then
  fail "启动验证必须拒绝 stat 失败"
fi

mv "$fixture_src/.git" "$fixture_src/.git.saved"
if verify_runnable_browser_output \
  "fixture component" "$fixture_out" true "$ROOT_DIR/args/aegis.gn" \
  >/dev/null 2>&1; then
  mv "$fixture_src/.git.saved" "$fixture_src/.git"
  fail "启动验证必须拒绝缺失的 Chromium HEAD 时间"
fi
mv "$fixture_src/.git.saved" "$fixture_src/.git"

# 实际调用顶层入口，防止 pnpm 仅列出脚本却以 0 退出。
launch_profile="$fixture_root/launch-profile"
launch_output="$(CHROMIUM_ROOT="$CHROMIUM_ROOT" OUT_DIR="$fixture_out" \
  AEGIS_USER_DATA_DIR="$launch_profile" AEGIS_RUN_DRY_RUN=1 \
  pnpm --dir "$REPO_ROOT" run browser:run)"
[[ "$launch_output" == *"已验证开发版：$fixture_binary"* ]] || \
  fail "顶层 browser:run 必须实际进入验证启动脚本"
[[ "$launch_output" == *"独立 Profile：$launch_profile"* ]] || \
  fail "顶层 browser:run 必须保留独立资料目录"

# pnpm 的 Node/生命周期 shell 边界不会被 kcov 的 Bash 后代追踪可靠归属。
# 直接执行同一仓库源码，既保留上面的顶层接线检查，也让覆盖率绑定真实 run.sh。
direct_launch_output="$(CHROMIUM_ROOT="$CHROMIUM_ROOT" OUT_DIR="$fixture_out" \
  AEGIS_USER_DATA_DIR="$launch_profile" AEGIS_RUN_DRY_RUN=1 \
  bash "$SCRIPT_DIR/run.sh")"
[[ "$direct_launch_output" == *"已验证开发版：$fixture_binary"* ]] || \
  fail "直接 run.sh 必须实际完成构建产物验证"
[[ "$direct_launch_output" == *"独立 Profile：$launch_profile"* ]] || \
  fail "直接 run.sh 必须保留独立资料目录"

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
