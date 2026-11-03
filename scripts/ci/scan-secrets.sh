#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

if (( $# > 1 )); then
  printf 'Usage: %s [repository]\n' "$0" >&2
  exit 2
fi

source_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
repository="${1:-$source_root}"
if [[ "$(git -C "$repository" rev-parse --is-shallow-repository)" != false ]]; then
  printf 'Secret scanning requires complete Git history; fetch with depth 0.\n' >&2
  exit 2
fi

umask 077
report_directory="$(mktemp -d "${TMPDIR:-/tmp}/aegis-secret-scan.XXXXXX")"
trap 'rm -rf -- "$report_directory"' EXIT

status=0
"${GITLEAKS_BIN:-gitleaks}" git "$repository" \
  --config "$source_root/.gitleaks.toml" \
  --gitleaks-ignore-path "$source_root/.gitleaksignore" \
  --ignore-gitleaks-allow \
  --log-opts="--all --full-history" \
  --max-decode-depth 5 --max-archive-depth 2 \
  --redact=100 --no-banner --no-color \
  --report-format json --report-path "$report_directory/findings.json" || status=$?

# Gitleaks reports also contain commit messages and source context. Publish only
# locations; never upload or print the raw report, Match, Secret, or Message.
if [[ -f "$report_directory/findings.json" ]]; then
  python3 - "$report_directory/findings.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as report:
    findings = json.load(report)
for finding in findings:
    print(json.dumps({
        "rule": finding["RuleID"],
        "file": finding["File"],
        "line": finding["StartLine"],
        "commit": finding["Commit"],
    }))
print(f"Secret scan candidates: {len(findings)}")
PY
fi

exit "$status"
