#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

KCOV_TAG="v43"
KCOV_COMMIT="a39874f938ce13f7a65f253120d1ec946b349ffe"
KCOV_SOURCE_URL="https://codeload.github.com/SimonKagstrom/kcov/tar.gz/$KCOV_COMMIT"
KCOV_SOURCE_SHA256="dac01569171979477b500924be264d2a1bc649dae6010536228cbb319344d516"

usage() {
  printf 'Usage: %s --tested-sha SHA --report-dir ABSOLUTE_PATH\n' "$0" >&2
  exit 2
}

tested_sha=""
report_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tested-sha)
      [[ $# -ge 2 ]] || usage
      tested_sha="$2"
      shift 2
      ;;
    --report-dir)
      [[ $# -ge 2 ]] || usage
      report_dir="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ "$(uname -s)" == "Linux" ]] || {
  printf 'Bash coverage requires Linux kcov; current host is %s\n' "$(uname -s)" >&2
  exit 1
}
[[ "$tested_sha" =~ ^[0-9a-f]{40}$ ]] || {
  printf '%s\n' '--tested-sha must be a full lowercase commit SHA' >&2
  exit 1
}
[[ "$report_dir" == /* ]] || {
  printf '%s\n' '--report-dir must be an absolute path' >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd -P)"
report_dir="$(python3 - "$REPO_ROOT" "$report_dir" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
report = Path(sys.argv[2]).resolve(strict=False)
try:
    relative = report.relative_to(root)
except ValueError:
    raise SystemExit(f'Report directory must be inside the repository: {report}')
if not relative.parts:
    raise SystemExit('Report directory must not be the repository root')
print(report)
PY
)"
actual_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
[[ "$tested_sha" == "$actual_sha" ]] || {
  printf 'Tested SHA mismatch: requested=%s actual=%s\n' "$tested_sha" "$actual_sha" >&2
  exit 1
}

if [[ -e "$report_dir" && ! -d "$report_dir" ]]; then
  printf 'Report path exists and is not a directory: %s\n' "$report_dir" >&2
  exit 1
fi
if [[ -e "$report_dir" ]] && [[ -n "$(find "$report_dir" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
  printf 'Refusing to overwrite non-empty report directory: %s\n' "$report_dir" >&2
  exit 1
fi
mkdir -p "$report_dir"

work_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/aegis-kcov.XXXXXX")"
cleanup() {
  [[ -n "${work_dir:-}" && -d "$work_dir" ]] && rm -rf -- "$work_dir"
}
trap cleanup EXIT

for command_name in curl sha256sum tar cmake; do
  command -v "$command_name" >/dev/null || {
    printf 'Missing kcov build prerequisite: %s\n' "$command_name" >&2
    exit 1
  }
done
source_archive="$work_dir/kcov-$KCOV_COMMIT.tar.gz"
curl --fail --location --silent --show-error --retry 3 \
  --output "$source_archive" "$KCOV_SOURCE_URL"
actual_source_sha="$(sha256sum "$source_archive" | awk '{print $1}')"
[[ "$actual_source_sha" == "$KCOV_SOURCE_SHA256" ]] || {
  printf 'kcov source SHA256 mismatch: expected=%s actual=%s\n' \
    "$KCOV_SOURCE_SHA256" "$actual_source_sha" >&2
  exit 1
}
mkdir -p "$work_dir/source" "$work_dir/build" "$work_dir/install"
tar -xzf "$source_archive" -C "$work_dir/source" --strip-components=1
cmake -S "$work_dir/source" -B "$work_dir/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$work_dir/install" >/dev/null
cmake --build "$work_dir/build" --parallel 2 >/dev/null
cmake --install "$work_dir/build" >/dev/null
kcov_bin="$work_dir/install/bin/kcov"
[[ -x "$kcov_bin" ]] || {
  printf 'kcov executable is unavailable: %s\n' "$kcov_bin" >&2
  exit 1
}
kcov_version_output="$($kcov_bin --version)"
[[ "$kcov_version_output" =~ ^kcov[[:space:]]+43([.[:space:]-]|$) ]] || {
  printf 'Expected kcov 43, got: %s\n' "$kcov_version_output" >&2
  exit 1
}
kcov_binary_sha256="$(sha256sum "$kcov_bin" | awk '{print $1}')"

BROWSER_SCRIPTS="$REPO_ROOT/apps/browser/scripts"
FIXTURE_DIR="$SCRIPT_DIR/platform-tests"
fixture_output="$work_dir/fixture-coverage"
"$kcov_bin" \
  --include-path="$FIXTURE_DIR" \
  --bash-parse-files-in-dir="$FIXTURE_DIR" \
  --bash-handle-sh-invocation \
  "$fixture_output" "$FIXTURE_DIR/kcov-parent-fixture.sh" >/dev/null
fixture_cobertura="$(find "$fixture_output" -type f -name cobertura.xml -print -quit)"
[[ -n "$fixture_cobertura" && -s "$fixture_cobertura" ]] || {
  printf '%s\n' 'kcov subprocess fixture produced no Cobertura report' >&2
  exit 1
}

python3 - "$fixture_cobertura" "$FIXTURE_DIR" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

report = Path(sys.argv[1])
scope = Path(sys.argv[2]).resolve()
covered = set()
for source in ET.parse(report).findall('.//class'):
    raw = source.get('filename', '')
    candidates = [Path(raw), scope / Path(raw).name]
    for candidate in candidates:
        try:
            resolved = candidate.resolve()
        except OSError:
            continue
        if resolved.parent == scope:
            hits = sum(int(line.get('hits', '0')) for line in source.findall('./lines/line'))
            if hits > 0:
                covered.add(resolved.name)
            break
expected = {'kcov-parent-fixture.sh', 'kcov-child-fixture.sh'}
if not expected.issubset(covered):
    raise SystemExit(f'kcov did not capture the Bash subprocess fixture: covered={sorted(covered)}')
PY

tests=(
  aegis-access-gn-wiring_test.sh
  status_test.sh
  fetch-toolchain_test.sh
  run_test.sh
  apply-patches_test.sh
  build-package-guards_test.sh
  package-android-guards_test.sh
  sign-chromium-app_test.sh
)
coverage_inputs=()
test_results_file="$work_dir/test-results.txt"
: > "$test_results_file"
for test_name in "${tests[@]}"; do
  test_path="$BROWSER_SCRIPTS/$test_name"
  [[ -x "$test_path" ]] || {
    printf 'Coverage test is missing or not executable: %s\n' "$test_path" >&2
    exit 1
  }
  output="$work_dir/runs/${test_name%.sh}"
  mkdir -p "$output"
  printf 'Running real Bash behavior test under kcov: %s\n' "$test_name"
  "$kcov_bin" \
    --include-path="$BROWSER_SCRIPTS" \
    --exclude-pattern=_test.sh \
    --bash-parse-files-in-dir="$BROWSER_SCRIPTS" \
    --bash-handle-sh-invocation \
    "$output" "$test_path"
  coverage_inputs+=("$output")
  printf '%s\tPASS\n' "$test_name" >> "$test_results_file"
done

merged_output="$work_dir/merged"
"$kcov_bin" --merge "$merged_output" "${coverage_inputs[@]}" >/dev/null
merged_cobertura="$(find "$merged_output" -type f -path '*/kcov-merged/cobertura.xml' -print -quit)"
[[ -n "$merged_cobertura" && -s "$merged_cobertura" ]] || {
  printf '%s\n' 'Merged kcov Cobertura report is missing or empty' >&2
  exit 1
}

KCOV_VERSION_OUTPUT="$kcov_version_output" \
KCOV_BINARY_SHA256="$kcov_binary_sha256" \
KCOV_SOURCE_URL="$KCOV_SOURCE_URL" \
KCOV_SOURCE_SHA256="$KCOV_SOURCE_SHA256" \
KCOV_SOURCE_COMMIT="$KCOV_COMMIT" \
KCOV_SOURCE_TAG="$KCOV_TAG" \
TESTED_SHA="$tested_sha" \
python3 - "$REPO_ROOT" "$BROWSER_SCRIPTS" "$merged_cobertura" \
  "$report_dir" "$test_results_file" <<'PY'
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

repo = Path(sys.argv[1]).resolve()
scope = Path(sys.argv[2]).resolve()
input_xml = Path(sys.argv[3])
output = Path(sys.argv[4])
results_path = Path(sys.argv[5])

def resolve_source(raw):
    path = Path(raw)
    candidates = [path, repo / path, scope / path, scope / path.name]
    for candidate in candidates:
        try:
            resolved = candidate.resolve()
        except OSError:
            continue
        if resolved.is_file() and resolved.parent == scope:
            return resolved
    return None

line_hits = defaultdict(dict)
for source in ET.parse(input_xml).findall('.//class'):
    resolved = resolve_source(source.get('filename', ''))
    if resolved is None or resolved.name.endswith('_test.sh'):
        continue
    relative = resolved.relative_to(repo).as_posix()
    for line in source.findall('./lines/line'):
        number = int(line.get('number', '0'))
        hits = int(line.get('hits', '0'))
        if number > 0:
            line_hits[relative][number] = max(line_hits[relative].get(number, 0), hits)

if not line_hits:
    raise SystemExit('Merged kcov report contains no production Bash source')
if any(path.endswith('_test.sh') or '/platform-tests/' in path for path in line_hits):
    raise SystemExit('Merged kcov report contains harness or fixture source')
required_hits = [
    'apps/browser/scripts/common.sh',
    'apps/browser/scripts/status.sh',
    'apps/browser/scripts/run.sh',
]
missing_hits = [path for path in required_hits if sum(line_hits.get(path, {}).values()) == 0]
if missing_hits:
    raise SystemExit('Required product Bash sources have no executed lines: ' + ', '.join(missing_hits))

lcov_lines = []
for path in sorted(line_hits):
    lines = line_hits[path]
    lcov_lines.extend(['TN:', f'SF:{path}'])
    lcov_lines.extend(f'DA:{number},{lines[number]}' for number in sorted(lines))
    lcov_lines.extend([
        f'LF:{len(lines)}',
        f'LH:{sum(1 for hits in lines.values() if hits > 0)}',
        'end_of_record',
    ])
lcov = '\n'.join(lcov_lines) + '\n'
(output / 'lcov.info').write_text(lcov, encoding='utf-8')

coverage = ET.Element('coverage', {
    'line-rate': '0', 'branch-rate': '0', 'version': 'kcov-43',
    'timestamp': str(int(datetime.now(tz=timezone.utc).timestamp())),
})
sources = ET.SubElement(coverage, 'sources')
ET.SubElement(sources, 'source').text = '.'
packages = ET.SubElement(coverage, 'packages')
package = ET.SubElement(packages, 'package', {
    'name': 'apps.browser.scripts', 'line-rate': '0', 'branch-rate': '0', 'complexity': '0',
})
classes = ET.SubElement(package, 'classes')
total = covered = 0
for path in sorted(line_hits):
    lines = line_hits[path]
    total += len(lines)
    covered += sum(1 for hits in lines.values() if hits > 0)
    item = ET.SubElement(classes, 'class', {
        'name': path.replace('/', '.'), 'filename': path,
        'line-rate': str(sum(1 for hits in lines.values() if hits > 0) / len(lines)),
        'branch-rate': '0', 'complexity': '0',
    })
    ET.SubElement(item, 'methods')
    xml_lines = ET.SubElement(item, 'lines')
    for number in sorted(lines):
        ET.SubElement(xml_lines, 'line', {'number': str(number), 'hits': str(lines[number]), 'branch': 'false'})
rate = covered / total if total else 0
coverage.set('lines-valid', str(total))
coverage.set('lines-covered', str(covered))
coverage.set('line-rate', str(rate))
package.set('line-rate', str(rate))
ET.indent(coverage)
ET.ElementTree(coverage).write(output / 'cobertura.xml', encoding='utf-8', xml_declaration=True)

tests = []
for line in results_path.read_text(encoding='utf-8').splitlines():
    name, result = line.split('\t', 1)
    tests.append({'entry': f'apps/browser/scripts/{name}', 'result': result})
all_production = sorted(
    path.relative_to(repo).as_posix()
    for path in scope.glob('*.sh')
    if not path.name.endswith('_test.sh')
)
unmeasured = [path for path in all_production if path not in line_hits]
summary = (
    f'tool={os.environ["KCOV_VERSION_OUTPUT"]}\n'
    f'tested_sha={os.environ["TESTED_SHA"]}\n'
    f'tests_passed={len(tests)}/{len(tests)}\n'
    f'production_files_reported={len(line_hits)}\n'
    f'lines_covered={covered}\nlines_total={total}\nline_rate={rate * 100:.2f}%\n'
)
(output / 'coverage.txt').write_text(summary, encoding='utf-8')
report_hashes = {
    name: hashlib.sha256((output / name).read_bytes()).hexdigest()
    for name in ('lcov.info', 'cobertura.xml', 'coverage.txt')
}
metadata = {
    'schemaVersion': 1,
    'language': 'bash',
    'status': 'PASS',
    'testedSha': os.environ['TESTED_SHA'],
    'generatedAt': datetime.now(tz=timezone.utc).isoformat(),
    'tool': {
        'name': 'kcov',
        'version': os.environ['KCOV_VERSION_OUTPUT'],
        'sourceTag': os.environ['KCOV_SOURCE_TAG'],
        'sourceCommit': os.environ['KCOV_SOURCE_COMMIT'],
        'sourceUrl': os.environ['KCOV_SOURCE_URL'],
        'sourceArchiveSha256': os.environ['KCOV_SOURCE_SHA256'],
        'binarySha256': os.environ['KCOV_BINARY_SHA256'],
    },
    'scope': {
        'kind': 'browser-shell-production-behavior',
        'include': ['apps/browser/scripts/*.sh'],
        'exclude': ['apps/browser/scripts/*_test.sh', 'scripts/ci/platform-tests/**'],
        'reportedProductionFiles': sorted(line_hits),
        'unmeasuredProductionFiles': unmeasured,
        'notMeasured': [
            'shell scripts outside apps/browser/scripts',
            'branches and functions (kcov Bash line coverage only)',
            'macOS-only behavior not reached by the Linux fixtures',
        ],
    },
    'subprocessFixture': {
        'result': 'PASS',
        'parent': 'scripts/ci/platform-tests/kcov-parent-fixture.sh',
        'child': 'scripts/ci/platform-tests/kcov-child-fixture.sh',
        'includedInProductionReport': False,
    },
    'tests': tests,
    'totals': {'lines': {'covered': covered, 'total': total, 'pct': round(rate * 100, 2)}},
    'reports': {
        'lcov': {'path': 'lcov.info', 'sha256': report_hashes['lcov.info']},
        'cobertura': {'path': 'cobertura.xml', 'sha256': report_hashes['cobertura.xml']},
        'summary': {'path': 'coverage.txt', 'sha256': report_hashes['coverage.txt']},
    },
}
(output / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
for name in ('lcov.info', 'cobertura.xml', 'coverage.txt', 'metadata.json'):
    path = output / name
    if not path.is_file() or path.stat().st_size == 0:
        raise SystemExit(f'Coverage output is missing or empty: {path}')
print(json.dumps(metadata))
PY
