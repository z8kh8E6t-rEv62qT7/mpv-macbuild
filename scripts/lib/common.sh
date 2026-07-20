#!/usr/bin/env bash
set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_SCRIPT_ROOT="$(cd "$CI_SCRIPT_DIR/.." && pwd)"
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

die() {
  echo "error: $*" >&2
  exit 1
}

source "$CI_SCRIPT_DIR/runtime-fixups.sh"

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

run_logged() {
  local title="$1"
  shift
  local log_dir="$AUDIT_DIR/logs"
  local log_path="$log_dir/$(log_slug "$title").log"
  local status

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

require_source_env() {
  local required=(
    SOURCE_PREFIX
    FFMPEG_PREFIX
    FFMPEG_LGPL_PREFIX
    SOURCE_ROOT
    BUILD_ROOT
    VCPKG_INSTALLED_DIR
    VCPKG_TARGET_PREFIX
    VCPKG_BINARY_CACHE
    VCPKG_BINARY_SOURCES
    NUGET_CACHE_MODE
    NUGET_CACHE_REASON
    NUGET_FEED_URL
    NUGET_SOURCE_NAME
    NUGET_CONFIG_PATH
    MACOSX_DEPLOYMENT_TARGET
    CMAKE_OSX_DEPLOYMENT_TARGET
    CC
    CXX
    OBJC
    OBJCXX
    AR
    RANLIB
    STRIP
    NM
    LLVM_PREFIX
    LLVM_RANLIB
    LLVM_CXX_RUNTIME_DIR
    LLVM_UNWIND_RUNTIME_DIR
    LLVM_LIBCXX_DYLIB
    LLVM_LIBCXXABI_DYLIB
    LLVM_LIBUNWIND_DYLIB
    VCPKG_TARGET_CC
    VCPKG_TARGET_CXX
    VCPKG_TARGET_OBJC
    VCPKG_TARGET_OBJCXX
    VCPKG_TARGET_AR
    VCPKG_TARGET_RANLIB
    VCPKG_TARGET_STRIP
    VCPKG_TARGET_NM
    LLVM_RES
    LLVM_RESOURCE_FLAG
    LLVM_C_BUNDLE
    LLVM_CXX_BUNDLE
    LLVM_LINK_BUNDLE
    LLVM_BUNDLE
    LLVM_RUNTIME_LINK_FLAGS
    CPU_FLAGS
    OPTIMIZATIONS
    MPV_FFMPEG_CXX_DISABLE
    LINK_PATH
    INCLUDE_PATH
    CFLAGS
    CXXFLAGS
    OBJCFLAGS
    OBJCXXFLAGS
    LDFLAGS
    SOURCE_LDFLAGS
    LD64_LLD
    RUSTC
    MPV_REAL_RUSTC
    MPV_RUSTC_DIAGNOSTIC_LOG
  )
  local name

  for name in "${required[@]}"; do
    if [[ "$name" == "INCLUDE_PATH" ]]; then
      [[ "${!name+x}" == "x" ]] || die "$name is not set"
      continue
    fi
    [[ -n "${!name:-}" ]] || die "$name is not set"
  done
}

ci_jobs() {
  sysctl -n hw.ncpu
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
