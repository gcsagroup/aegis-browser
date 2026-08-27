#!/usr/bin/env bash
# 针对钉扎 Chromium checkout 与产物的只读状态/完整性门。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

SERIES_FILE="${AEGIS_SERIES_FILE:-$ROOT_DIR/patches/series}"
PATCH_DIR="${AEGIS_PATCH_DIR:-$ROOT_DIR/patches}"
V8_PATCH_DIR="${AEGIS_V8_PATCH_DIR:-$PATCH_DIR/v8}"
V8_SERIES_FILE="${AEGIS_V8_SERIES_FILE:-$V8_PATCH_DIR/series}"
EXPECTED_PATCH_COUNT="${AEGIS_EXPECTED_PATCH_COUNT:-}"
SRC="$CHROMIUM_ROOT/src"
DEV_OUT="${AEGIS_DEV_OUT:-${OUT_DIR:-$SRC/out/AegisLocalDev}}"
RELEASE_OUT="${AEGIS_RELEASE_OUT:-$SRC/out/AegisRelease}"
OVERLAY_DIR="${AEGIS_OVERLAY_DIR:-$ROOT_DIR/overlay}"
SOURCE_IDENTITY_EXCLUDES="$ROOT_DIR/config/source-identity-excludes"
SKIP_OVERLAY_CHECK="${AEGIS_SKIP_OVERLAY_CHECK:-0}"
host="$(uname -s)"

errors=0
warnings=0

ok() {
  printf '  [OK]   %s\n' "$*"
}

warn() {
  warnings=$((warnings + 1))
  printf '  [WARN] %s\n' "$*"
}

fail() {
  errors=$((errors + 1))
  printf '  [FAIL] %s\n' "$*"
}

short_sha() {
  printf '%.12s' "$1"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 1
  fi
}

file_mtime() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null
}

read_patch_header_sha() {
  awk 'NR == 1 && $1 == "From" && $2 ~ /^[0-9a-f]{40}$/ { print $2 }' "$1"
}

read_patch_id() {
  git patch-id --stable < "$1" 2>/dev/null | awk 'NR == 1 { print $1 }'
}

patch_lineage_kind() {
  local exact_commit_identity="$1"
  local all_patch_ids_match="$2"

  if [[ "$exact_commit_identity" == true &&
        "$all_patch_ids_match" == true ]]; then
    printf 'exact\n'
  elif [[ "$all_patch_ids_match" == true ]]; then
    printf 'replay\n'
  else
    printf 'mismatch\n'
  fi
}

chromium_checkout_status() {
  local checkout="$1"
  if [[ ! -f "$SOURCE_IDENTITY_EXCLUDES" ]]; then
    printf '缺少受控源码身份排除文件：%s\n' "$SOURCE_IDENTITY_EXCLUDES" >&2
    return 1
  fi
  # 覆盖 Chromium checkout 的 diff.ignoreSubmodules=dirty；唯一额外豁免是
  # 受控文件中声明的 .DS_Store，未跟踪源码、tracked 改动和 HEAD 漂移仍失败。
  git -C "$checkout" -c core.excludesFile="$SOURCE_IDENTITY_EXCLUDES" \
    status --porcelain=v1 --untracked-files=all --ignore-submodules=none \
    -- . ':(exclude)v8'
}

check_overlay_matches_checkout() {
  local overlay_file relative checkout_file
  local drift_count=0
  local shown_count=0

  case "$SKIP_OVERLAY_CHECK" in
    0) ;;
    1)
      warn "已通过 AEGIS_SKIP_OVERLAY_CHECK=1 临时跳过 overlay 漂移门"
      return
      ;;
    *)
      fail "AEGIS_SKIP_OVERLAY_CHECK 仅接受 0 或 1"
      return
      ;;
  esac

  if [[ ! -d "$OVERLAY_DIR" ]]; then
    fail "overlay 目录缺失：$OVERLAY_DIR"
    return
  fi

  while IFS= read -r -d '' overlay_file; do
    relative="${overlay_file#"$OVERLAY_DIR"/}"
    checkout_file="$SRC/$relative"
    if [[ ! -f "$checkout_file" ]] || ! cmp -s "$overlay_file" "$checkout_file"; then
      drift_count=$((drift_count + 1))
      if [[ "$shown_count" -lt 10 ]]; then
        if [[ -f "$checkout_file" ]]; then
          printf '           内容不同：%s\n' "$relative"
        else
          printf '           checkout 缺失：%s\n' "$relative"
        fi
        shown_count=$((shown_count + 1))
      fi
    fi
  done < <(find "$OVERLAY_DIR" -type f -print0)

  if [[ "$drift_count" -gt 0 ]]; then
    fail "overlay 与 checkout 漂移（$drift_count 个路径）"
    if [[ "$drift_count" -gt "$shown_count" ]]; then
      printf '           ……另有 %d 个路径\n' \
        "$((drift_count - shown_count))"
    fi
  else
    ok "overlay 与 checkout 内容一致"
  fi
}

check_v8_patch_lineage() {
  local chromium_base="$1"
  local v8_src="$SRC/v8"
  local v8_base v8_head dirty_status
  local patch_name patch_path header_sha expected_id actual_id commit
  local index=0
  local exact_lineage=true
  local all_patch_ids_match=true
  local -a patch_names=()
  local -a expected_shas=()
  local -a expected_ids=()
  local -a commits=()

  if [[ ! -s "$V8_SERIES_FILE" ]]; then
    fail "缺少 V8 补丁序列：$V8_SERIES_FILE"
    return
  fi
  while IFS= read -r patch_name; do
    [[ -z "$patch_name" || "$patch_name" =~ ^[[:space:]]*# ]] && continue
    patch_names+=("$patch_name")
  done < "$V8_SERIES_FILE"
  if [[ "${#patch_names[@]}" -eq 0 ]]; then
    fail "V8 补丁序列为空"
    return
  fi
  if ! git -C "$v8_src" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "V8 checkout 缺失或不是 Git 仓库：$v8_src"
    return
  fi
  v8_base="$(git -C "$SRC" rev-parse "${chromium_base}:v8" 2>/dev/null || true)"
  if [[ ! "$v8_base" =~ ^[0-9a-f]{40}$ ]]; then
    fail "无法从 Chromium base 读取 V8 gitlink"
    return
  fi
  for patch_name in "${patch_names[@]}"; do
    index=$((index + 1))
    if [[ "$patch_name" == */* || "$patch_name" == *..* ]]; then
      fail "V8 补丁序列含不安全路径：$patch_name"
      continue
    fi
    if [[ "$patch_name" != "$(printf '%04d-' "$index")"* ]]; then
      fail "第 $index 个 V8 补丁名称不符合顺序：$patch_name"
    fi
    patch_path="$V8_PATCH_DIR/$patch_name"
    if [[ ! -f "$patch_path" ]]; then
      fail "缺少 V8 补丁文件：$patch_name"
      continue
    fi
    header_sha="$(read_patch_header_sha "$patch_path")"
    expected_id="$(read_patch_id "$patch_path")"
    if [[ ! "$header_sha" =~ ^[0-9a-f]{40}$ ||
          ! "$expected_id" =~ ^[0-9a-f]{40}$ ]]; then
      fail "V8 补丁缺少有效 commit SHA 或 patch-id：$patch_name"
      continue
    fi
    expected_shas+=("$header_sha")
    expected_ids+=("$expected_id")
  done
  if [[ "${#expected_ids[@]}" -ne "${#patch_names[@]}" ]]; then
    return
  fi

  v8_head="$(git -C "$v8_src" rev-parse HEAD 2>/dev/null || true)"
  if ! git -C "$v8_src" merge-base --is-ancestor "$v8_base" "$v8_head" 2>/dev/null; then
    fail "V8 HEAD 不是钉扎 V8 base 的后代"
    return
  fi
  while IFS= read -r commit; do
    [[ -n "$commit" ]] && commits+=("$commit")
  done < <(git -C "$v8_src" rev-list --reverse "${v8_base}..${v8_head}")
  if [[ "${#commits[@]}" -ne "${#patch_names[@]}" ]]; then
    fail "V8 checkout 在 base 后有 ${#commits[@]} 个提交，补丁序列为 ${#patch_names[@]} 个"
  else
    for ((index = 0; index < ${#commits[@]}; index++)); do
      commit="${commits[$index]}"
      actual_id="$(git -C "$v8_src" show --pretty=email --binary "$commit" 2>/dev/null |
        git patch-id --stable 2>/dev/null | awk 'NR == 1 { print $1 }' || true)"
      if [[ "$actual_id" != "${expected_ids[$index]}" ]]; then
        all_patch_ids_match=false
        fail "V8 补丁 $(printf '%04d' $((index + 1))) 内容不匹配"
      fi
      if [[ "$commit" != "${expected_shas[$index]}" ]]; then
        exact_lineage=false
      fi
    done
    if [[ "$all_patch_ids_match" == true ]]; then
      if [[ "$exact_lineage" == true ]]; then
        ok "V8 checkout 精确匹配 ${#patch_names[@]} 个嵌套补丁提交"
      else
        ok "V8 checkout 等价重放 ${#patch_names[@]} 个嵌套补丁"
      fi
    fi
  fi

  if ! dirty_status="$(git -C "$v8_src" status --porcelain=v1 \
    --untracked-files=all 2>&1)"; then
    fail "无法读取 V8 checkout 脏状态：$dirty_status"
  elif [[ -n "$dirty_status" ]]; then
    fail "V8 checkout 存在未封存改动"
    printf '%s\n' "$dirty_status" | sed -n '1,10s/^/           /p'
  else
    ok "V8 checkout 干净，HEAD $v8_head"
  fi
}

check_freshness() {
  local label="$1"
  local artifact="$2"
  local args_template="$3"
  local artifact_epoch head_epoch newer_input

  artifact_epoch="$(file_mtime "$artifact" || true)"
  head_epoch="$(git -C "$SRC" show -s --format=%ct HEAD 2>/dev/null || true)"
  if [[ -z "$artifact_epoch" ]]; then
    fail "$label 无法读取修改时间：$artifact"
    return
  fi
  if [[ -n "$head_epoch" && "$artifact_epoch" -lt "$head_epoch" ]]; then
    fail "$label 早于 checkout HEAD"
    return
  fi

  newer_input="$(find "$PATCH_DIR" "$OVERLAY_DIR" "$args_template" \
    "$VERSION_FILE" "$COMMIT_FILE" -type f -newer "$artifact" -print -quit \
    2>/dev/null || true)"
  if [[ -n "$newer_input" ]]; then
    fail "$label 已过期；存在更新输入：$newer_input"
  else
    ok "$label 新鲜度时间戳=$artifact_epoch"
  fi
}

check_desktop_output() {
  local label="$1"
  local out_dir="$2"
  local expected_component="$3"
  local args_template="$4"
  local host_os="$5"
  local args_file="$out_dir/args.gn"
  local binary
  local actual_component target_cpu binary_type manifest_error

  if ! binary="$(desktop_binary_path "$out_dir" "$host_os")"; then
    warn "$label 不支持当前宿主产物布局：$host_os"
    return
  fi

  if [[ ! -d "$out_dir" ]]; then
    warn "$label 尚未构建：$out_dir"
    return
  fi
  if [[ ! -f "$args_file" ]]; then
    fail "$label 输出目录存在但缺少 args.gn"
    return
  fi
  if grep -Eq '^[[:space:]]*is_component_build[[:space:]]*=[[:space:]]*true' "$args_file"; then
    actual_component=true
  elif grep -Eq '^[[:space:]]*is_component_build[[:space:]]*=[[:space:]]*false' "$args_file"; then
    actual_component=false
  else
    fail "$label 的 args.gn 未声明 is_component_build"
    return
  fi
  if [[ "$actual_component" != "$expected_component" ]]; then
    fail "$label 类型不符：component=$actual_component，预期=$expected_component"
  else
    ok "$label 类型 component=$actual_component"
  fi
  if ! gn_args_match "$args_template" "$args_file"; then
    fail "$label 的 args.gn 与 $(basename "$args_template") 不一致"
  else
    ok "$label GN 参数匹配 $(basename "$args_template")"
  fi
  if [[ ! -x "$binary" ]]; then
    fail "$label 不完整；缺少可执行文件 $binary"
    return
  fi
  binary_type="$(file -b "$binary" 2>/dev/null || true)"
  target_cpu="$(awk -F= '/^[[:space:]]*target_cpu[[:space:]]*=/ {gsub(/[[:space:]\"]/, "", $2); print $2; exit}' "$args_file")"
  case "$target_cpu" in
    arm64)
      if [[ "$binary_type" != *arm64* && "$binary_type" != *aarch64* ]]; then
        fail "$label 可执行文件不是 arm64：$binary_type"
      else
        ok "$label 可执行文件：$binary_type"
      fi
      ;;
    x64)
      if [[ "$binary_type" != *x86_64* && "$binary_type" != *x86-64* ]]; then
        fail "$label 可执行文件不是 x86_64：$binary_type"
      else
        ok "$label 可执行文件：$binary_type"
      fi
      ;;
    *) warn "$label 的 target_cpu 无法识别：$target_cpu" ;;
  esac
  check_freshness "$label" "$binary" "$args_template"
  if [[ "$expected_component" == false ]]; then
    if manifest_error="$(verify_release_manifest_inputs "$out_dir" 2>&1)"; then
      ok "$label 构建身份清单、构建图及产物匹配当前源码"
    else
      fail "$label 构建身份清单无效：$manifest_error"
    fi
  fi
}

check_android_output() {
  local out_dir="$SRC/out/AegisAndroid"
  local args_template="$ROOT_DIR/args/aegis-android.gn"
  local args_file="$out_dir/args.gn"
  local apk="$out_dir/apks/ChromePublic.apk"
  local apk_type

  if [[ ! -d "$out_dir" ]]; then
    warn "Android 产物尚未构建（需要 Linux 主机）"
    return
  fi
  if [[ ! -f "$args_file" ]] || ! gn_args_match "$args_template" "$args_file"; then
    fail "Android args.gn 缺失或与 aegis-android.gn 不一致"
  fi
  if [[ ! -f "$apk" ]]; then
    fail "Android 产物不完整；缺少 $apk"
    return
  fi
  apk_type="$(file -b "$apk" 2>/dev/null || true)"
  if [[ "$apk_type" != *Zip* && "$apk_type" != *Android* ]]; then
    fail "Android 产物类型异常：$apk_type"
  else
    ok "Android 产物：$apk_type"
  fi
  check_freshness "Android APK" "$apk" "$args_template"
}

if [[ "${AEGIS_STATUS_SOURCE_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

printf 'GCSA-aegis Chromium fork 完整性状态\n'

version="$(read_pinned_value "$VERSION_FILE" 2>/dev/null || true)"
base_sha="$(read_pinned_value "$COMMIT_FILE" 2>/dev/null || true)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "Chromium 版本钉扎无效：${version:-缺失}"
else
  ok "版本钉扎 $version"
fi
if [[ ! "$base_sha" =~ ^[0-9a-f]{40}$ ]]; then
  fail "Chromium base SHA 无效：${base_sha:-缺失}"
else
  ok "base 钉扎 $base_sha"
fi

patch_files=()
if [[ ! -s "$SERIES_FILE" ]]; then
  fail "缺少补丁序列：$SERIES_FILE"
else
  while IFS= read -r entry; do
    [[ -z "$entry" || "$entry" =~ ^[[:space:]]*# ]] && continue
    patch_files+=("$entry")
  done < "$SERIES_FILE"
fi

if [[ -n "$EXPECTED_PATCH_COUNT" &&
      "${#patch_files[@]}" -ne "$EXPECTED_PATCH_COUNT" ]]; then
  fail "补丁数量 ${#patch_files[@]}/$EXPECTED_PATCH_COUNT"
else
  ok "补丁数量 ${#patch_files[@]}"
fi

expected_patch_shas=()
expected_patch_ids=()
seen_patch_names=""
index=0
for patch_name in "${patch_files[@]}"; do
  index=$((index + 1))
  expected_prefix="$(printf '%04d-' "$index")"
  patch_path="$PATCH_DIR/$patch_name"
  if [[ "$patch_name" == */* || "$patch_name" == *..* ]]; then
    fail "补丁序列含不安全路径：$patch_name"
    continue
  fi
  if [[ "$patch_name" != "$expected_prefix"* ]]; then
    fail "第 $index 个补丁名称不符合顺序：$patch_name"
  fi
  if [[ "$seen_patch_names" == *"|$patch_name|"* ]]; then
    fail "补丁序列存在重复项：$patch_name"
  fi
  seen_patch_names="${seen_patch_names}|${patch_name}|"
  if [[ ! -f "$patch_path" ]]; then
    fail "缺少补丁文件：$patch_name"
    continue
  fi
  header_sha="$(read_patch_header_sha "$patch_path")"
  patch_id="$(read_patch_id "$patch_path")"
  if [[ ! "$header_sha" =~ ^[0-9a-f]{40}$ ]]; then
    fail "$patch_name 缺少 format-patch commit SHA"
  fi
  if [[ ! "$patch_id" =~ ^[0-9a-f]{40}$ ]]; then
    fail "$patch_name 无法生成稳定 patch-id"
  fi
  expected_patch_shas+=("$header_sha")
  expected_patch_ids+=("$patch_id")
done

series_origin_head=""
if [[ "${#expected_patch_shas[@]}" -gt 0 ]]; then
  series_origin_head="${expected_patch_shas[$((${#expected_patch_shas[@]} - 1))]}"
fi
series_sha="$(sha256_file "$SERIES_FILE" 2>/dev/null || true)"
if [[ -n "$series_sha" ]]; then
  ok "补丁序列 SHA-256 $series_sha"
else
  warn "缺少 SHA-256 工具，未校验补丁序列摘要"
fi
if [[ "$series_origin_head" =~ ^[0-9a-f]{40}$ ]]; then
  ok "补丁导出源 HEAD $series_origin_head"
else
  fail "无法从最后一个补丁读取导出源 HEAD"
fi

printf '  checkout：%s\n' "$SRC"
if ! git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "Chromium checkout 缺失或不是 Git 仓库"
else
  head_sha="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)"
  if [[ ! "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
    fail "无法读取 checkout HEAD"
  else
    ok "checkout HEAD $head_sha"
  fi

  if [[ "$base_sha" =~ ^[0-9a-f]{40}$ ]] && \
     ! git -C "$SRC" cat-file -e "${base_sha}^{commit}" 2>/dev/null; then
    fail "本地 checkout 缺少 base commit"
  elif [[ "$base_sha" =~ ^[0-9a-f]{40}$ ]]; then
    ok "本地存在 base commit"
  fi

  if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && \
     git -C "$SRC" show-ref --verify --quiet "refs/tags/$version"; then
    tag_sha="$(git -C "$SRC" rev-parse "refs/tags/${version}^{commit}" 2>/dev/null || true)"
    if [[ "$tag_sha" != "$base_sha" ]]; then
      fail "tag $version 指向 $tag_sha，预期 $base_sha"
    else
      ok "tag $version 匹配 base 钉扎"
    fi
  else
    warn "本地缺少 tag $version"
  fi

  commits=()
  lineage_kind=unverified
  if [[ "$base_sha" =~ ^[0-9a-f]{40}$ ]] && \
     git -C "$SRC" merge-base --is-ancestor "$base_sha" "$head_sha" 2>/dev/null; then
    while IFS= read -r commit; do
      [[ -n "$commit" ]] && commits+=("$commit")
    done < <(git -C "$SRC" rev-list --reverse "${base_sha}..${head_sha}")
    if [[ "${#commits[@]}" -eq 0 ]]; then
      warn "checkout 位于 base SHA，尚未应用补丁"
    elif [[ "${#commits[@]}" -ne "${#patch_files[@]}" ]]; then
      fail "checkout 在 base 后有 ${#commits[@]} 个提交，补丁序列为 ${#patch_files[@]} 个"
    else
      ok "checkout 含预期的 ${#patch_files[@]} 个补丁提交"
      exact_lineage=true
      all_patch_ids_match=true
      for ((i = 0; i < ${#patch_files[@]}; i++)); do
        commit="${commits[$i]}"
        expected_sha="${expected_patch_shas[$i]:-}"
        expected_id="${expected_patch_ids[$i]:-}"
        actual_id="$(git -C "$SRC" show --pretty=email --binary "$commit" 2>/dev/null | \
          git patch-id --stable 2>/dev/null | awk 'NR == 1 { print $1 }' || true)"
        if [[ "$actual_id" != "$expected_id" ]]; then
          all_patch_ids_match=false
          fail "补丁 $(printf '%04d' $((i + 1))) 的内容与 ${patch_files[$i]} 不符"
        fi
        if [[ "$commit" != "$expected_sha" ]]; then
          exact_lineage=false
        fi
      done
      lineage_kind="$(patch_lineage_kind "$exact_lineage" \
        "$all_patch_ids_match")"
      case "$lineage_kind" in
        exact)
          ok "checkout 保留补丁导出时的原始 commit 身份，且 patch-id 全部匹配"
          ;;
        replay)
          ok "checkout commit 身份由本地重放生成，稳定 patch-id 全部匹配"
          ;;
        mismatch) ;;
      esac
    fi
  else
    fail "checkout HEAD 不是钉扎 base 的后代"
  fi

  if [[ -n "$series_origin_head" && "$head_sha" == "$series_origin_head" &&
        "$lineage_kind" == exact ]]; then
    ok "checkout HEAD 匹配补丁导出源 HEAD"
  elif [[ "$lineage_kind" == replay ]]; then
    ok "checkout HEAD $(short_sha "$head_sha") 为等价本地重放结果"
  fi

  check_overlay_matches_checkout
  check_v8_patch_lineage "$base_sha"

  # V8 的 gitlink 由独立补丁序列校验；其余 Chromium gitlink 仍必须参与脏状态检查。
  if ! dirty_status="$(chromium_checkout_status "$SRC" 2>&1)"; then
    fail "无法读取 Chromium checkout 脏状态：$dirty_status"
  elif [[ -n "$dirty_status" ]]; then
    dirty_count="$(printf '%s\n' "$dirty_status" | awk 'NF {count++} END {print count+0}')"
    fail "checkout 存在脏改动（$dirty_count 个路径）"
    printf '%s\n' "$dirty_status" | sed -n '1,10s/^/           /p'
    if [[ "$dirty_count" -gt 10 ]]; then
      printf '           ……另有 %d 个路径\n' "$((dirty_count - 10))"
    fi
  else
    ok "checkout 干净"
  fi

  check_desktop_output "开发桌面产物" "$DEV_OUT" true \
    "$ROOT_DIR/args/aegis.gn" "$host"
  check_desktop_output "Release 桌面产物" "$RELEASE_OUT" false \
    "$ROOT_DIR/args/aegis-release.gn" "$host"
  if [[ "$host" == Linux || -d "$SRC/out/AegisAndroid" ]]; then
    check_android_output
  else
    warn "Android 产物尚未构建（需要 Linux 主机）"
  fi
fi

printf '  主机：%s\n' "$host"
if [[ -d "$DEPOT_TOOLS_DIR/.git" ]]; then
  ok "depot_tools 已存在：$DEPOT_TOOLS_DIR"
else
  warn "depot_tools 缺失：$DEPOT_TOOLS_DIR"
fi

printf '汇总：%d 个失败，%d 个警告\n' "$errors" "$warnings"
if [[ "$errors" -gt 0 ]]; then
  exit 1
fi
