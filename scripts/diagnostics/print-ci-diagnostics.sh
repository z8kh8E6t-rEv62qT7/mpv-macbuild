#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
init_ci_environment

print_file() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  ci_group "$path"
  cat "$path"
  ci_endgroup
}

print_matching_files() {
  local title="$1"
  shift
  local found=0
  local pattern path

  ci_group "$title"
  for pattern in "$@"; do
    for path in $pattern; do
      [[ -f "$path" ]] || continue
      found=1
      echo "===== $path ====="
      cat "$path"
      echo
    done
  done
  if [[ "$found" == 0 ]]; then
    echo "No matching files."
  fi
  ci_endgroup
}

print_command() {
  local title="$1"
  shift
  ci_group "$title"
  "$@" || true
  ci_endgroup
}

print_selected_environment() {
  local names=(
    GITHUB_WORKSPACE
    RUNNER_OS
    RUNNER_ARCH
    RUNNER_TEMP
    SOURCE_PREFIX
    FFMPEG_PREFIX
    SOURCE_ROOT
    BUILD_ROOT
    AUDIT_DIR
    VCPKG_INSTALLED_DIR
    VCPKG_TARGET_PREFIX
    VCPKG_BINARY_CACHE
    VCPKG_BINARY_SOURCES
    NUGET_CACHE_MODE
    NUGET_CACHE_REASON
    NUGET_FEED_URL
    NUGET_SOURCE_NAME
    NUGET_CONFIG_PATH
    MPV_REAL_RUSTC
    MPV_RUSTC_DIAGNOSTIC_LOG
    MPV_RUSTC_DEPLOYMENT_TARGET
    RUSTC
    CC
    CXX
    OBJC
    OBJCXX
    AR
    RANLIB
    STRIP
    NM
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
    MACOSX_DEPLOYMENT_TARGET
    CMAKE_OSX_DEPLOYMENT_TARGET
    LD64_LLD
    LLVM_RES
    LLVM_RESOURCE_FLAG
    LLVM_C_BUNDLE
    LLVM_CXX_BUNDLE
    LLVM_LINK_BUNDLE
    LLVM_BUNDLE
    LLVM_RUNTIME_LINK_FLAGS
    CPU_FLAGS
    OPTIMIZATIONS
    LINK_PATH
    INCLUDE_PATH
    PKG_CONFIG_LIBDIR
    CMAKE_PREFIX_PATH
  )
  local name

  ci_group "CI diagnostics: selected environment"
  for name in "${names[@]}"; do
    printf '%s=%s\n' "$name" "${!name:-}"
  done
  ci_endgroup
}

build_root="${BUILD_ROOT:-${RUNNER_TEMP:+$RUNNER_TEMP/build}}"
source_prefix="${SOURCE_PREFIX:-${RUNNER_TEMP:+$RUNNER_TEMP/source-prefix}}"
ffmpeg_prefix="${FFMPEG_PREFIX:-${RUNNER_TEMP:+$RUNNER_TEMP/ffmpeg-prefix}}"
mpv_dir="${MPV_DIR:-${WORKSPACE_DIR:-$(pwd)}/mpv}"
audit_dir="${AUDIT_DIR:-${WORKSPACE_DIR:-$(pwd)}/audit}"

print_command "CI diagnostics: workspace" pwd
print_command "CI diagnostics: git status" git status --short
print_selected_environment

print_matching_files "CI diagnostics: audit logs" \
  "$audit_dir/logs/*.log" \
  "$audit_dir/*.json" \
  "$audit_dir/*.txt" \
  "$audit_dir/*.md"

if [[ -n "${build_root:-}" ]]; then
  print_matching_files "CI diagnostics: CMake superbuild logs" \
    "$build_root/superbuild/"'*'"/src/"'*'"-stamp/"'*'".log" \
    "$build_root/source-superbuild/CMakeFiles/CMakeOutput.log" \
    "$build_root/source-superbuild/CMakeFiles/CMakeError.log"
fi

if [[ -n "${SOURCE_ROOT:-}" ]]; then
  print_matching_files "CI diagnostics: vcpkg buildtree logs" \
    "$SOURCE_ROOT/vcpkg/buildtrees/"'*'"/"*"*.log"
fi

print_matching_files "CI diagnostics: Meson logs" \
  "$mpv_dir/build/meson-logs/meson-log.txt" \
  "$mpv_dir/build/meson-logs/testlog.txt" \
  "$build_root/"'*'"/meson-logs/meson-log.txt" \
  "$build_root/"'*'"/meson-logs/testlog.txt"

if [[ -n "${source_prefix:-}" || -n "${ffmpeg_prefix:-}" ]]; then
  print_command "CI diagnostics: source prefix tree" find "${source_prefix:-/nonexistent}" -maxdepth 3 -type f
  print_command "CI diagnostics: FFmpeg prefix tree" find "${ffmpeg_prefix:-/nonexistent}" -maxdepth 3 -type f
fi
