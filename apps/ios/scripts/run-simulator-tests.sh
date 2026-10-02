#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IOS_ROOT="$(cd -P -- "${SCRIPT_DIR}/.." && pwd)"

REPO_ROOT="$(cd -P -- "${IOS_ROOT}/../.." && pwd)"
DERIVED_DATA="${AEGIS_IOS_DERIVED_DATA:-$(dirname "$REPO_ROOT")/GCSA-aegis-build/ios/DerivedData}"
MODE="dry-run"
PROJECT_PATH=""
WORKSPACE_PATH=""
SCHEME="${AEGIS_IOS_SCHEME:-Aegis}"
TEST_PLAN="${AEGIS_IOS_TEST_PLAN:-}"
ONLY_TESTING=()
RUNTIME_ID="${AEGIS_IOS_RUNTIME_ID:-}"
OUTPUT_DIR="${AEGIS_IOS_OUTPUT_DIR:-/tmp/aegis-ios-$(date -u +%Y%m%dT%H%M%SZ)-$$}"

PHONE_NAME="Aegis QA iPhone 17"
PHONE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
TABLET_NAME="Aegis QA iPad Air 11-inch (M4)"
TABLET_TYPE="com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M4"

usage() {
  cat <<'EOF'
用法：
  bash apps/ios/scripts/run-simulator-tests.sh [选项]

默认只做 dry-run：校验 fixture 与 Safari 文档身份测试、读取 Simulator 清单并打印将执行的命令，不创建设备，
不启动测试，也不创建输出目录。只有显式传入 --execute 才会创建缺失的专用设备并运行测试。

选项：
  --dry-run              只读预演（默认）
  --execute              创建缺失设备，依次运行 iPhone/iPad 测试并导出产品 Swift coverage
  --project PATH         指定 .xcodeproj
  --workspace PATH       指定 .xcworkspace
  --scheme NAME          Scheme，默认 Aegis
  --test-plan NAME       可选 Test Plan；未指定时运行 Scheme 中全部测试
  --only-testing PATH    只运行指定测试，可重复（例如 AegisTests/ContentFilterTests）
  --runtime IDENTIFIER   Simulator runtime ID；默认选择最新可用 iOS runtime
  --output-dir PATH      必须是不存在的 /tmp/aegis-ios-* 绝对路径
  -h, --help             显示帮助

安全边界：脚本从不 erase、delete、shutdown、uninstall 或清理任何 Simulator，也不会删除或
覆盖已有测试产物。每台设备保留 xcresult、原始 xccov JSON 与产品 Swift 文件级汇总；
xcodebuild 可按系统正常行为启动目标 Simulator。
EOF
}

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

print_command() {
  printf '  '
  printf '%q ' "$@"
  printf '\n'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      MODE="dry-run"
      shift
      ;;
    --execute)
      MODE="execute"
      shift
      ;;
    --project)
      [[ $# -ge 2 ]] || die "--project 缺少路径"
      PROJECT_PATH="$2"
      shift 2
      ;;
    --workspace)
      [[ $# -ge 2 ]] || die "--workspace 缺少路径"
      WORKSPACE_PATH="$2"
      shift 2
      ;;
    --scheme)
      [[ $# -ge 2 ]] || die "--scheme 缺少名称"
      SCHEME="$2"
      shift 2
      ;;
    --test-plan)
      [[ $# -ge 2 ]] || die "--test-plan 缺少名称"
      TEST_PLAN="$2"
      shift 2
      ;;
    --only-testing)
      [[ $# -ge 2 ]] || die "--only-testing 缺少测试路径"
      [[ "$2" =~ ^(AegisTests|AegisUITests)(/[A-Za-z0-9_]+){0,2}$ ]] || die "测试路径格式无效"
      ONLY_TESTING+=("-only-testing:$2")
      shift 2
      ;;
    --runtime)
      [[ $# -ge 2 ]] || die "--runtime 缺少 identifier"
      RUNTIME_ID="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir 缺少路径"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac
done

[[ -z "$PROJECT_PATH" || -z "$WORKSPACE_PATH" ]] || die "--project 与 --workspace 只能指定一个"
[[ -n "$SCHEME" ]] || die "Scheme 不能为空"

case "$OUTPUT_DIR" in
  /tmp/aegis-ios-*) ;;
  *) die "输出目录必须是 /tmp/aegis-ios-* 形式的绝对路径" ;;
esac
case "$OUTPUT_DIR" in
  *'/../'*|*'/..') die "输出目录不能包含父目录跳转" ;;
esac

for required_tool in git node python3 shasum xcodegen xcodebuild xcrun; do
  command -v "$required_tool" >/dev/null 2>&1 || die "缺少工具：$required_tool"
done

node "${SCRIPT_DIR}/verify-fixtures.mjs"
node "${SCRIPT_DIR}/generate-tracker-rules.mjs" --check
python3 "${SCRIPT_DIR}/simulator-fixture-server.py" --self-test
node "${IOS_ROOT}/Tests/SharedWebExtension/SafariNavigationIdentityTests.mjs"
node --test "${SCRIPT_DIR}/test-summarize-xccov.mjs"

if [[ -z "$RUNTIME_ID" ]]; then
  RUNTIME_ID="$({ xcrun simctl list runtimes -j; } | node -e '
    const fs = require("node:fs");
    const payload = JSON.parse(fs.readFileSync(0, "utf8"));
    const runtimes = (payload.runtimes ?? [])
      .filter((item) => item.isAvailable !== false && item.identifier?.includes(".iOS-"))
      .sort((a, b) => String(a.version).localeCompare(String(b.version), undefined, { numeric: true }));
    if (runtimes.length === 0) process.exit(2);
    process.stdout.write(runtimes.at(-1).identifier);
  ')" || die "没有可用的 iOS Simulator runtime"
fi

runtime_available="$({ xcrun simctl list runtimes -j; } | env AEGIS_RUNTIME_ID="$RUNTIME_ID" node -e '
  const fs = require("node:fs");
  const payload = JSON.parse(fs.readFileSync(0, "utf8"));
  const runtime = (payload.runtimes ?? []).find((item) => item.identifier === process.env.AEGIS_RUNTIME_ID);
  process.stdout.write(runtime && runtime.isAvailable !== false ? "yes" : "no");
')"
[[ "$runtime_available" == "yes" ]] || die "runtime 不可用：$RUNTIME_ID"

device_types_json="$(xcrun simctl list devicetypes -j)"
for required_type in "$PHONE_TYPE" "$TABLET_TYPE"; do
  type_available="$(printf '%s' "$device_types_json" | env AEGIS_DEVICE_TYPE="$required_type" node -e '
    const fs = require("node:fs");
    const payload = JSON.parse(fs.readFileSync(0, "utf8"));
    const found = (payload.devicetypes ?? []).some((item) => item.identifier === process.env.AEGIS_DEVICE_TYPE);
    process.stdout.write(found ? "yes" : "no");
  ')"
  [[ "$type_available" == "yes" ]] || die "设备类型不可用：$required_type"
done

if [[ -z "$PROJECT_PATH" && -z "$WORKSPACE_PATH" ]]; then
  if [[ -d "${IOS_ROOT}/Aegis.xcworkspace" ]]; then
    WORKSPACE_PATH="${IOS_ROOT}/Aegis.xcworkspace"
  elif [[ -d "${IOS_ROOT}/Aegis.xcodeproj" ]]; then
    PROJECT_PATH="${IOS_ROOT}/Aegis.xcodeproj"
  else
    for candidate in "${IOS_ROOT}"/*.xcworkspace; do
      if [[ -d "$candidate" ]]; then
        WORKSPACE_PATH="$candidate"
        break
      fi
    done
    if [[ -z "$WORKSPACE_PATH" ]]; then
      for candidate in "${IOS_ROOT}"/*.xcodeproj; do
        if [[ -d "$candidate" ]]; then
          PROJECT_PATH="$candidate"
          break
        fi
      done
    fi
  fi
fi

if [[ -n "$WORKSPACE_PATH" ]]; then
  CONTAINER_ARGS=(-workspace "$WORKSPACE_PATH")
  CONTAINER_LABEL="$WORKSPACE_PATH"
elif [[ -n "$PROJECT_PATH" ]]; then
  CONTAINER_ARGS=(-project "$PROJECT_PATH")
  CONTAINER_LABEL="$PROJECT_PATH"
else
  CONTAINER_ARGS=(-project "${IOS_ROOT}/Aegis.xcodeproj")
  CONTAINER_LABEL="${IOS_ROOT}/Aegis.xcodeproj"
  if [[ "$MODE" == "execute" ]]; then
    die "未找到 Xcode project/workspace；可通过 --project 或 --workspace 指定"
  fi
  printf '提示：工程尚不存在，dry-run 使用预期路径 %s。\n' "$CONTAINER_LABEL"
fi

if [[ "$MODE" == "execute" && ! -d "$CONTAINER_LABEL" ]]; then
  die "Xcode 容器不存在：$CONTAINER_LABEL"
fi

lookup_device() {
  local name="$1"
  local expected_type="$2"
  xcrun simctl list devices -j | env \
    AEGIS_DEVICE_NAME="$name" \
    AEGIS_DEVICE_TYPE="$expected_type" \
    AEGIS_RUNTIME_ID="$RUNTIME_ID" \
    node -e '
      const fs = require("node:fs");
      const payload = JSON.parse(fs.readFileSync(0, "utf8"));
      const devices = payload.devices?.[process.env.AEGIS_RUNTIME_ID] ?? [];
      const named = devices.filter((item) => item.name === process.env.AEGIS_DEVICE_NAME && item.isAvailable !== false);
      if (named.length === 0) {
        process.stdout.write("ABSENT");
      } else if (named.length > 1) {
        process.stdout.write(`DUPLICATE|${named.map((item) => item.udid).join(",")}`);
      } else if (named[0].deviceTypeIdentifier !== process.env.AEGIS_DEVICE_TYPE) {
        process.stdout.write(`TYPE_MISMATCH|${named[0].udid}|${named[0].deviceTypeIdentifier}`);
      } else {
        process.stdout.write(`FOUND|${named[0].udid}`);
      }
    '
}

ensure_device() {
  local name="$1"
  local type="$2"
  local result
  local tag
  local udid

  result="$(lookup_device "$name" "$type")"
  tag="${result%%|*}"
  case "$tag" in
    FOUND)
      udid="${result#FOUND|}"
      printf '复用专用 Simulator：%s (%s)\n' "$name" "$udid" >&2
      printf '%s' "$udid"
      ;;
    ABSENT)
      if [[ "$MODE" == "dry-run" ]]; then
        printf '缺少专用 Simulator，执行模式将创建：%s\n' "$name" >&2
        print_command xcrun simctl create "$name" "$type" "$RUNTIME_ID" >&2
        printf 'name=%s' "$name"
      else
        udid="$(xcrun simctl create "$name" "$type" "$RUNTIME_ID")"
        [[ -n "$udid" ]] || die "创建 Simulator 未返回 UDID：$name"
        printf '已创建专用 Simulator：%s (%s)\n' "$name" "$udid" >&2
        printf '%s' "$udid"
      fi
      ;;
    DUPLICATE)
      die "同一 runtime 下存在多个同名设备，脚本不会猜测或删除：$name (${result#DUPLICATE|})"
      ;;
    TYPE_MISMATCH)
      die "同名设备类型不符，脚本不会覆盖或删除：$name (${result#TYPE_MISMATCH|})"
      ;;
    *)
      die "无法解析 Simulator 查询结果：$result"
      ;;
  esac
}

PHONE_DESTINATION="$(ensure_device "$PHONE_NAME" "$PHONE_TYPE")"
TABLET_DESTINATION="$(ensure_device "$TABLET_NAME" "$TABLET_TYPE")"

COMMON_ARGS=("${CONTAINER_ARGS[@]}" -scheme "$SCHEME" -configuration Debug -enableCodeCoverage YES)
if [[ -n "$TEST_PLAN" ]]; then
  COMMON_ARGS+=(-testPlan "$TEST_PLAN")
fi

destination_for() {
  local resolved="$1"
  if [[ "$resolved" == name=* ]]; then
    printf 'platform=iOS Simulator,%s' "$resolved"
  else
    printf 'platform=iOS Simulator,id=%s' "$resolved"
  fi
}

PHONE_XCODE_DESTINATION="$(destination_for "$PHONE_DESTINATION")"
TABLET_XCODE_DESTINATION="$(destination_for "$TABLET_DESTINATION")"

printf '\nAegis iOS Simulator 测试计划\n'
printf '  模式：%s\n' "$MODE"
printf '  工程：%s\n' "$CONTAINER_LABEL"
printf '  Scheme：%s\n' "$SCHEME"
printf '  Test Plan：%s\n' "${TEST_PLAN:-<Scheme 全部测试>}"
printf '  Runtime：%s\n' "$RUNTIME_ID"
printf '  输出：%s\n' "$OUTPUT_DIR"

PHONE_COMMAND=(xcodebuild "${COMMON_ARGS[@]}" test-without-building
  -destination "$PHONE_XCODE_DESTINATION"
  -derivedDataPath "$DERIVED_DATA"
  -parallel-testing-enabled NO -collect-test-diagnostics never
  -resultBundlePath "${OUTPUT_DIR}/iPhone.xcresult" ${ONLY_TESTING[@]+"${ONLY_TESTING[@]}"})
TABLET_COMMAND=(xcodebuild "${COMMON_ARGS[@]}" test-without-building
  -destination "$TABLET_XCODE_DESTINATION"
  -derivedDataPath "$DERIVED_DATA"
  -parallel-testing-enabled NO -collect-test-diagnostics never
  -resultBundlePath "${OUTPUT_DIR}/iPad.xcresult" ${ONLY_TESTING[@]+"${ONLY_TESTING[@]}"})

BUILD_COMMAND=(xcodebuild "${COMMON_ARGS[@]}" build-for-testing
  -destination "$PHONE_XCODE_DESTINATION" -derivedDataPath "$DERIVED_DATA")

if [[ "$MODE" == "dry-run" ]]; then
  printf '构建时递增 project.yml 构建号，并在固定路径 %s 生成一次测试包。\n' "$DERIVED_DATA"
  print_command "${BUILD_COMMAND[@]}"
  printf '\n将执行：\n'
  print_command "${PHONE_COMMAND[@]}"
  print_command "${TABLET_COMMAND[@]}"
  printf '\nDRY_RUN=PASS（未创建设备、未启动测试、未创建输出目录）\n'
  exit 0
fi

[[ ! -e "$OUTPUT_DIR" ]] || die "输出目录已存在，拒绝覆盖：$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

REPO_ROOT="$(git -C "${IOS_ROOT}" rev-parse --show-toplevel)"
GIT_SHA="$(git -C "${IOS_ROOT}" rev-parse HEAD)"
if [[ -n "$(git -C "${IOS_ROOT}" status --short)" ]]; then
  GIT_TREE_STATE="dirty"
else
  GIT_TREE_STATE="clean"
fi
XCODE_VERSION="$(xcodebuild -version | tr '\n' ' ')"

write_input_manifest() {
  local destination="$1"
  (
    cd "$REPO_ROOT"
    git ls-files --cached --others --exclude-standard -- apps/ios \
      | LC_ALL=C sort \
      | while IFS= read -r input_path; do
          [[ -n "$input_path" ]] || continue
          shasum -a 256 "$input_path"
        done
  ) > "$destination"
}


xcrun simctl list runtimes -j \
  | env AEGIS_RUNTIME_ID="$RUNTIME_ID" node -e '
      const fs = require("node:fs");
      const payload = JSON.parse(fs.readFileSync(0, "utf8"));
      const runtime = (payload.runtimes ?? []).find((item) => item.identifier === process.env.AEGIS_RUNTIME_ID);
      if (!runtime) process.exit(1);
      process.stdout.write(`${JSON.stringify(runtime, null, 2)}\n`);
    ' > "${OUTPUT_DIR}/simulator-runtime.json"

{
  printf 'started_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'project_or_workspace=%s\n' "$CONTAINER_LABEL"
  printf 'scheme=%s\n' "$SCHEME"
  printf 'test_plan=%s\n' "${TEST_PLAN:-<scheme-default>}"
  printf 'test_filter=%s\n' "${ONLY_TESTING[*]:-<all>}"
  printf 'runtime=%s\n' "$RUNTIME_ID"
  printf 'git_sha=%s\n' "$GIT_SHA"
  printf 'git_tree_state=%s\n' "$GIT_TREE_STATE"
  printf 'host_os=%s\n' "$(sw_vers -productName) $(sw_vers -productVersion) $(sw_vers -buildVersion)"
  printf 'host_arch=%s\n' "$(uname -m)"
  printf 'developer_dir=%s\n' "$(xcode-select -p)"
  printf 'node_version=%s\n' "$(node --version)"
  printf 'iphone=%s|%s\n' "$PHONE_NAME" "$PHONE_DESTINATION"
  printf 'ipad=%s|%s\n' "$TABLET_NAME" "$TABLET_DESTINATION"
  xcodebuild -version
} > "${OUTPUT_DIR}/run-metadata.txt"

run_test() {
  local label="$1"
  local result_path="$2"
  local log_path="$3"
  shift 3
  local status
  local summary_path="${result_path%.*}-summary.json"
  local coverage_path="${result_path%.*}-coverage.json"
  local swift_coverage_path="${result_path%.*}-swift-coverage.json"
  local swift_coverage_text_path="${result_path%.*}-swift-coverage.txt"
  local summary_status=0
  local coverage_status=0

  printf '\n运行 %s Simulator 测试……\n' "$label"
  set +e
  "$@" 2>&1 | tee "$log_path"
  status="${PIPESTATUS[0]}"
  set -e

  if [[ -d "$result_path" ]]; then
    xcrun xcresulttool get test-results summary --path "$result_path" --compact \
      > "$summary_path" || summary_status=$?
  else
    printf '错误：%s 未生成 xcresult：%s\n' "$label" "$result_path" >&2
    summary_status=1
  fi

  if [[ "$summary_status" -eq 0 ]]; then
    env AEGIS_SUMMARY_PATH="$summary_path" node -e '
      const fs = require("node:fs");
      const summary = JSON.parse(fs.readFileSync(process.env.AEGIS_SUMMARY_PATH, "utf8"));
      if (summary.result !== "Passed" || !Number.isInteger(summary.totalTestCount) || summary.totalTestCount < 1) {
        console.error(`错误：测试摘要无效：result=${summary.result}, total=${summary.totalTestCount}`);
        process.exit(1);
      }
    ' || summary_status=$?
  fi

  if [[ -d "$result_path" ]]; then
    xcrun xccov view --report --json "$result_path" > "$coverage_path" \
      || coverage_status=$?
    if [[ "$coverage_status" -eq 0 ]]; then
      node "${SCRIPT_DIR}/summarize-xccov.mjs" \
        --xccov-json "$coverage_path" \
        --ios-root "$IOS_ROOT" \
        --output-json "$swift_coverage_path" \
        --output-text "$swift_coverage_text_path" \
        --device-label "$label" \
        --git-sha "$GIT_SHA" \
        --git-tree-state "$GIT_TREE_STATE" \
        --input-manifest-sha256 "$INPUT_MANIFEST_SHA256" \
        --runtime-id "$RUNTIME_ID" \
        --device-name "$([[ "$label" == "iPhone" ]] && printf '%s' "$PHONE_NAME" || printf '%s' "$TABLET_NAME")" \
        --device-udid "$([[ "$label" == "iPhone" ]] && printf '%s' "$PHONE_DESTINATION" || printf '%s' "$TABLET_DESTINATION")" \
        --xcode-version "$XCODE_VERSION" \
        || coverage_status=$?
    fi
  else
    coverage_status=1
  fi

  if [[ "$status" -ne 0 ]]; then
    return "$status"
  fi
  if [[ "$summary_status" -ne 0 ]]; then
    return "$summary_status"
  fi
  return "$coverage_status"
}

# 固定产物目录只允许一个构建者。证据仍按每次运行独立保存。
mkdir -p "$(dirname "$DERIVED_DATA")"
LOCK_DIR="${DERIVED_DATA}.runner-lock"
mkdir "$LOCK_DIR" 2>/dev/null || die "固定构建目录已有运行者：$LOCK_DIR"
fixture_pid=""
cleanup() {
  if [[ -n "$fixture_pid" ]]; then kill "$fixture_pid" 2>/dev/null || true; fi
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

fixture_ready() {
  python3 - <<'PYTHON'
import json, urllib.request
try:
    with urllib.request.urlopen('http://127.0.0.1:8768/v1/models', timeout=2) as response:
        value = json.load(response)
    assert value['data'][0]['id'] == 'aegis-simulator-fixture'
except Exception:
    raise SystemExit(1)
PYTHON
}
if ! fixture_ready; then
  python3 "${SCRIPT_DIR}/simulator-fixture-server.py" --port 8768 > "${OUTPUT_DIR}/fixture.log" 2>&1 &
  fixture_pid=$!
  for attempt in 1 2 3 4 5; do
    fixture_ready && break
    kill -0 "$fixture_pid" 2>/dev/null || die "验收服务启动失败，检查 8768 端口和 fixture.log"
    sleep 1
  done
  fixture_ready || die "验收服务尚未就绪"
fi
python3 - "$IOS_ROOT/project.yml" <<'PYTHON'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
text, count = re.subn(r'CURRENT_PROJECT_VERSION: (\d+)', lambda m: f'CURRENT_PROJECT_VERSION: {int(m[1]) + 1}', text)
assert count == 1
path.write_text(text)
PYTHON
xcodegen generate --spec "${IOS_ROOT}/project.yml"
write_input_manifest "${OUTPUT_DIR}/ios-input-sha256-before.txt"
INPUT_MANIFEST_SHA256="$(shasum -a 256 "${OUTPUT_DIR}/ios-input-sha256-before.txt" | awk '{print $1}')"
printf 'input_manifest_sha256=%s\n' "$INPUT_MANIFEST_SHA256" >> "${OUTPUT_DIR}/run-metadata.txt"
"${BUILD_COMMAND[@]}" > "${OUTPUT_DIR}/build.log" 2>&1 || die "构建失败，见 ${OUTPUT_DIR}/build.log"

phone_status=0
tablet_status=0
input_status=0
run_test "iPhone" "${OUTPUT_DIR}/iPhone.xcresult" "${OUTPUT_DIR}/iPhone-xcodebuild.log" \
  "${PHONE_COMMAND[@]}" || phone_status=$?
run_test "iPad" "${OUTPUT_DIR}/iPad.xcresult" "${OUTPUT_DIR}/iPad-xcodebuild.log" \
  "${TABLET_COMMAND[@]}" || tablet_status=$?

write_input_manifest "${OUTPUT_DIR}/ios-input-sha256-after.txt"
if ! cmp -s \
  "${OUTPUT_DIR}/ios-input-sha256-before.txt" \
  "${OUTPUT_DIR}/ios-input-sha256-after.txt"; then
  printf '错误：测试执行期间 apps/ios 输入发生变化；前后 SHA-256 清单已保留。\n' >&2
  input_status=1
fi

printf 'iphone_exit=%s\nipad_exit=%s\ninput_stability_exit=%s\nfinished_at_utc=%s\n' \
  "$phone_status" "$tablet_status" "$input_status" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  >> "${OUTPUT_DIR}/run-metadata.txt"

printf '\n测试产物：%s\n' "$OUTPUT_DIR"
if [[ "$phone_status" -ne 0 || "$tablet_status" -ne 0 || "$input_status" -ne 0 ]]; then
  printf 'SIMULATOR_TESTS=FAIL（iPhone=%s, iPad=%s, input_stability=%s）\n' \
    "$phone_status" "$tablet_status" "$input_status" >&2
  exit 1
fi

printf 'SIMULATOR_TESTS=PASS\n'
printf 'IOS_COVERAGE=PASS\n'
