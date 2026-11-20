#!/usr/bin/env bash
set -euo pipefail

bot_summary="${GITHUB_STEP_SUMMARY:?GitHub step summary is required}"
bot_root="$(cd -P -- "${RUNNER_TEMP:?GitHub runner temp is required}" && pwd)"
bot_name="${bot_summary##*/}"
if [[ "$bot_name" != step_summary_?* || "$bot_name" == *[!a-zA-Z0-9_-]* ||
      "$bot_summary" != "$bot_root/_runner_file_commands/$bot_name" ||
      -L "$bot_root/_runner_file_commands" || ! -f "$bot_summary" ||
      -L "$bot_summary" || ! -O "$bot_summary" || ! -w "$bot_summary" ]]; then
  printf '%s\n' 'Refusing a summary outside the owned GitHub runner command file' >&2
  exit 1
fi

node scripts/ci/android-delivery-bot.mjs | tee -a "$bot_summary"
