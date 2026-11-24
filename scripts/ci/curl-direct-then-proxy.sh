#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Shared CI download helper (five-project schedule).
# Attempt order: direct, direct, proxy, proxy, direct.
# Exponential backoff between attempts (1s, 2s, 4s, 8s).
# Per-attempt limit: CURL_CI_MAX_TIME_SECONDS (default 45). Worst case is
# 5 x 45s + 1+2+4+8s backoff = 240s, inside the 5-minute install step timeout.
# Override with CURL_CI_BACKOFF_BASE_SECONDS=0 or CI_DOWNLOAD_BACKOFF_BASE_SECONDS=0 in tests.
# shellcheck shell=bash

curl_ci_configured_proxy() {
  printf '%s' "${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-${all_proxy:-${ALL_PROXY:-}}}}}}"
}

curl_ci_backoff_seconds() {
  # $1 = zero-based index of the failure that just happened (0..3)
  local index="$1"
  local base="${CURL_CI_BACKOFF_BASE_SECONDS:-${CI_DOWNLOAD_BACKOFF_BASE_SECONDS:-1}}"
  if [[ "$base" == "0" ]]; then
    printf '0\n'
    return 0
  fi
  printf '%s\n' "$((base * (1 << index)))"
}

curl_ci_download() {
  local output="$1"
  local url="$2"
  shift 2
  local -a extra=("$@")
  local max_time="${CURL_CI_MAX_TIME_SECONDS:-${CI_DOWNLOAD_MAX_TIME_SECONDS:-45}}"
  [[ "$max_time" =~ ^[1-9][0-9]*$ ]] || max_time=45
  local -a base=(
    curl --fail --location --proto '=https' --tlsv1.2
    --connect-timeout 20 --max-time "$max_time" --retry 0
    --output "$output"
  )
  local proxy route attempt delay
  local -a routes=(direct direct proxy proxy direct)

  proxy="$(curl_ci_configured_proxy)"

  for attempt in "${!routes[@]}"; do
    route="${routes[$attempt]}"
    case "$route" in
      direct)
        if "${base[@]}" ${extra[@]+"${extra[@]}"} --proxy '' --noproxy '*' "$url"; then
          return 0
        fi
        ;;
      proxy)
        if [[ -z "$proxy" ]]; then
          printf 'Skipping proxy attempt %s: no HTTP(S) proxy configured\n' "$((attempt + 1))" >&2
        elif "${base[@]}" ${extra[@]+"${extra[@]}"} --proxy "$proxy" --noproxy '' "$url"; then
          return 0
        fi
        ;;
      *)
        printf 'Unknown download route: %s\n' "$route" >&2
        return 1
        ;;
    esac

    if (( attempt + 1 == ${#routes[@]} )); then
      break
    fi
    delay="$(curl_ci_backoff_seconds "$attempt")"
    printf 'Download attempt %s (%s) failed; backing off %ss before %s\n' \
      "$((attempt + 1))" "$route" "$delay" "${routes[$((attempt + 1))]}" >&2
    if (( delay > 0 )); then
      sleep "$delay"
    fi
  done

  printf 'Download failed after direct×2, proxy×2, direct×1: %s\n' "$url" >&2
  return 1
}
