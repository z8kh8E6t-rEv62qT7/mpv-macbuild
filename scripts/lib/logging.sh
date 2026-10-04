#!/usr/bin/env bash

die() {
  echo "error: $*" >&2
  exit 1
}

ci_group() {
  local title="$1"
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "::group::$title"
  else
    echo "===== $title ====="
  fi
}

ci_endgroup() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "::endgroup::"
  fi
}

log_slug() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9_.-' '-' | sed 's/^-//;s/-$//'
}

log_path_for_title() {
  local title="$1"
  local log_dir="${AUDIT_DIR:-$BUILD_ROOT/audit}/logs"
  printf '%s/%s.log' "$log_dir" "$(log_slug "$title")"
}

run_logged() {
  local title="$1"
  shift
  local log_dir="${AUDIT_DIR:-$BUILD_ROOT/audit}/logs"
  local log_path
  local status

  log_path="$(log_path_for_title "$title")"
  mkdir -p "$log_dir"
  ci_group "$title"
  set +e
  (
    set -euo pipefail
    printf '## %s\n' "$title"
    printf 'cwd: %s\n' "$PWD"
    printf 'command:'
    printf ' %q' "$@"
    printf '\n\n'
    "$@"
  ) 2>&1 | tee "$log_path"
  status=${PIPESTATUS[0]}
  set -e
  echo "log: $log_path"
  ci_endgroup
  return "$status"
}

run_logged_to_file() {
  local title="$1"
  shift
  local log_path

  log_path="$(log_path_for_title "$title")"
  mkdir -p "$(dirname "$log_path")"
  (
    set -euo pipefail
    printf '## %s\n' "$title"
    printf 'cwd: %s\n' "$PWD"
    printf 'command:'
    printf ' %q' "$@"
    printf '\n\n'
    "$@"
  ) > "$log_path" 2>&1
}

require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "$name is not set"
}
