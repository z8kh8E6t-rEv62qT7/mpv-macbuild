#!/usr/bin/env bash

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_SCRIPT_ROOT="$(cd "$CI_SCRIPT_DIR/.." && pwd)"

source "$CI_SCRIPT_DIR/logging.sh"
source "$CI_SCRIPT_DIR/runtime-fixups.sh"

init_ci_environment() {
  BUILDER_DIR="$(cd "$CI_SCRIPT_ROOT/.." && pwd)"
  WORKSPACE_DIR="${GITHUB_WORKSPACE:-$BUILDER_DIR}"
  MPV_DIR="${MPV_DIR:-$WORKSPACE_DIR/mpv}"
  AUDIT_DIR="${AUDIT_DIR:-$WORKSPACE_DIR/audit}"

  if [[ -n "${RUNNER_TEMP:-}" ]]; then
    SOURCE_PREFIX="${SOURCE_PREFIX:-$RUNNER_TEMP/source-prefix}"
    FFMPEG_PREFIX="${FFMPEG_PREFIX:-$RUNNER_TEMP/ffmpeg-prefix}"
    FFMPEG_LGPL_PREFIX="${FFMPEG_LGPL_PREFIX:-$RUNNER_TEMP/ffmpeg-lgpl-prefix}"
    SOURCE_ROOT="${SOURCE_ROOT:-$RUNNER_TEMP/sources}"
    BUILD_ROOT="${BUILD_ROOT:-$RUNNER_TEMP/build}"
  fi
}

create_clean_tar_gz() {
  local archive="$1"
  shift

  env COPYFILE_DISABLE=1 tar \
    --exclude='.DS_Store' \
    --exclude='./.DS_Store' \
    --exclude='*/.DS_Store' \
    --exclude='._*' \
    --exclude='./._*' \
    --exclude='*/._*' \
    --exclude='__MACOSX' \
    --exclude='./__MACOSX' \
    --exclude='*/__MACOSX' \
    -czf "$archive" "$@"
}

create_clean_tar_xz() {
  local archive="$1"
  shift

  env COPYFILE_DISABLE=1 tar \
    --exclude='.DS_Store' \
    --exclude='./.DS_Store' \
    --exclude='*/.DS_Store' \
    --exclude='._*' \
    --exclude='./._*' \
    --exclude='*/._*' \
    --exclude='__MACOSX' \
    --exclude='./__MACOSX' \
    --exclude='*/__MACOSX' \
    -cJf "$archive" "$@"
}

remove_macos_metadata() {
  local root

  for root in "$@"; do
    [[ -e "$root" ]] || continue
    find "$root" -name '.DS_Store' -type f -exec rm -f {} +
    find "$root" -name '._*' -type f -exec rm -f {} +
    find "$root" -name '__MACOSX' -type d -prune -exec rm -rf {} +
  done
}

require_github_file() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "$value" ]] || die "$name is not set"
}

require_build_environment() {
  local stage="$1"
  local declarations name allow_empty

  declarations="$(python3 "$CI_SCRIPT_DIR/build_environment.py" "$stage")" || return
  while IFS=$'\t' read -r name allow_empty; do
    [[ "${!name+x}" == x ]] || die "$name is not set"
    if [[ "$allow_empty" != 1 ]]; then
      [[ -n "${!name}" ]] || die "$name is not set"
    fi
  done <<< "$declarations"
}

write_github_environment() {
  local names name value

  require_github_file GITHUB_ENV
  names="$(python3 "$CI_SCRIPT_DIR/build_environment.py" github)" || return
  # Validate the complete set before appending anything to the runner file.
  while IFS= read -r name; do
    [[ "${!name+x}" == x ]] || die "$name is not set"
    value="${!name}"
    case "$value" in
      *$'\n'*|*$'\r'*) die "$name must be a single-line build environment value" ;;
    esac
  done <<< "$names"
  while IFS= read -r name; do
    export "$name"
    printf '%s=%s\n' "$name" "${!name}"
  done <<< "$names" >> "$GITHUB_ENV"
}

ci_jobs() {
  local jobs
  jobs="$(sysctl -n hw.ncpu)"
  if [[ "${CI_PARALLEL_CHILD:-}" == 1 ]]; then
    if [[ "$jobs" -gt 8 ]]; then
      echo 2
    else
      echo 1
    fi
  else
    echo "$jobs"
  fi
}

join_by_colon() {
  local IFS=:
  echo "$*"
}

append_row() {
  local name="$1"
  local status="$2"
  local detail="$3"
  printf '| %s | %s | %s |\n' "$name" "$status" "$detail" >> "$report"
}

fail_row() {
  append_row "$1" "FAIL" "$2"
  failures=$((failures + 1))
}
