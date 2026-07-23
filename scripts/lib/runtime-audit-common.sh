#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${CI_SCRIPT_DIR:-}" ]]; then
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi

runtime_audit_allowed_runtime_patterns() {
  PYTHONPATH="$CI_SCRIPT_ROOT/lib" python3 -c \
    'import ci_matrix; print("\n".join(ci_matrix.BUNDLE_ALLOWED_RUNTIME_EXCEPTION_PATTERNS))'
}

runtime_audit_denied_dylib_patterns() {
  PYTHONPATH="$CI_SCRIPT_ROOT/lib" python3 -c \
    'import ci_matrix; print("\n".join(ci_matrix.BUNDLE_DENY_DYLIB_PATTERNS))'
}

runtime_audit_ref_from_otool_line() {
  awk '{print $1}' <<< "$1"
}

runtime_audit_is_allowed_homebrew_ref() {
  local ref="$1"
  local llvm_prefix="${LLVM_PREFIX:-}"

  [[ -n "$llvm_prefix" ]] || return 1

  case "$ref" in
    "${LLVM_LIBUNWIND_DYLIB:-$llvm_prefix/lib/unwind/libunwind.1.dylib}" | \
    "${LLVM_LIBCXX_DYLIB:-$llvm_prefix/lib/c++/libc++.1.dylib}" | \
    "${LLVM_LIBCXXABI_DYLIB:-$llvm_prefix/lib/c++/libc++abi.1.dylib}" | \
    "${LLVM_UNWIND_RUNTIME_DIR:-$llvm_prefix/lib/unwind}" | \
    "${LLVM_CXX_RUNTIME_DIR:-$llvm_prefix/lib/c++}" | \
    "$llvm_prefix/lib/unwind/libunwind.1.dylib" | \
    "$llvm_prefix/lib/c++/libc++.1.dylib" | \
    "$llvm_prefix/lib/c++/libc++abi.1.dylib" | \
    "$llvm_prefix/lib/unwind" | \
    "$llvm_prefix/lib/c++")
      return 0
      ;;
  esac

  return 1
}

runtime_audit_check_system_cxx_refs() {
  local label="$1"
  shift
  local otool_files=("$@")
  local denied_report="$AUDIT_DIR/runtime-system-cxx-denied.txt"

  : > "$denied_report"
  grep -E '/usr/lib/libc\+\+(\.1)?\.dylib|/usr/lib/libc\+\+abi\.dylib|/usr/lib/libunwind(\.1)?\.dylib|@executable_path/lib/libc\+\+(\.1)?\.dylib|@executable_path/lib/libc\+\+abi(\.1)?\.dylib|@executable_path/lib/libunwind(\.1)?\.dylib' \
    "${otool_files[@]}" > "$denied_report" || true

  if [[ -s "$denied_report" ]]; then
    echo "$label links against non-bundled C++ runtime libraries:" >&2
    cat "$denied_report" >&2
    exit 1
  fi
}

runtime_audit_check_vapoursynth_rpath_refs() {
  local label="$1"
  shift
  local otool_files=("$@")
  local report="$AUDIT_DIR/runtime-vapoursynth-rpath.txt"
  local denied_report="$AUDIT_DIR/runtime-vapoursynth-denied.txt"
  local file
  local line
  local ref

  : > "$report"
  : > "$denied_report"

  for file in "${otool_files[@]}"; do
    [[ -f "$file" ]] || continue
    while IFS= read -r line; do
      ref="$(runtime_audit_ref_from_otool_line "$line")"
      case "$ref" in
        *libvsscript*.dylib | *libvapoursynth*.dylib)
          case "$ref" in
            @rpath/* | @loader_path/*)
              printf '%s:%s\n' "$file" "$line" >> "$report"
              ;;
            *)
              printf '%s:%s\n' "$file" "$line" >> "$denied_report"
              ;;
          esac
          ;;
      esac
    done < "$file"
  done

  if [[ -s "$denied_report" ]]; then
    echo "$label has non-rpath VapourSynth dylib references:" >&2
    cat "$denied_report" >&2
    exit 1
  fi

  if [[ -s "$report" ]]; then
    run_logged "vapoursynth-rpath-runtime" cat "$report"
  fi
}

runtime_audit_check_prefix_refs() {
  local label="$1"
  shift
  local otool_files=("$@")
  local prefix_name
  local prefix_value

  for prefix_name in SOURCE_PREFIX FFMPEG_PREFIX VCPKG_TARGET_PREFIX; do
    prefix_value="${!prefix_name:-}"
    [[ -n "$prefix_value" ]] || continue
    if grep -F "$prefix_value" "${otool_files[@]}" >/dev/null; then
      echo "$label references temporary build prefix $prefix_name=$prefix_value:" >&2
      grep -F "$prefix_value" "${otool_files[@]}" >&2
      exit 1
    fi
  done
}

runtime_audit_check_homebrew_refs() {
  local label="$1"
  shift
  local otool_files=("$@")
  local allowed_report="$AUDIT_DIR/runtime-homebrew-llvm-allowed.txt"
  local denied_report="$AUDIT_DIR/runtime-homebrew-denied.txt"
  local file
  local line
  local ref

  : > "$allowed_report"
  : > "$denied_report"

  for file in "${otool_files[@]}"; do
    [[ -f "$file" ]] || continue
    while IFS= read -r line; do
      [[ "$line" == *"/opt/homebrew"* ]] || continue
      ref="$(runtime_audit_ref_from_otool_line "$line")"
      [[ "$ref" == /opt/homebrew/* ]] || continue
      if runtime_audit_is_allowed_homebrew_ref "$ref"; then
        printf '%s:%s\n' "$file" "$line" >> "$allowed_report"
      else
        printf '%s:%s\n' "$file" "$line" >> "$denied_report"
      fi
    done < "$file"
  done

  if [[ -s "$allowed_report" ]]; then
    run_logged "allowed-homebrew-llvm-runtime" cat "$allowed_report"
  fi

  if [[ -s "$denied_report" ]]; then
    echo "$label links against non-LLVM Homebrew runtime libraries:" >&2
    cat "$denied_report" >&2
    exit 1
  fi
}

runtime_audit_check_static_required_dylibs() {
  local label="$1"
  shift
  local otool_files=("$@")
  local pattern

  while IFS= read -r pattern; do
    [[ -n "$pattern" ]] || continue
    if grep -E "[/@]${pattern}[^/[:space:]]*\\.dylib" "${otool_files[@]}" >/dev/null; then
      echo "$label links against a dylib for static-required library: $pattern" >&2
      grep -E "[/@]${pattern}[^/[:space:]]*\\.dylib" "${otool_files[@]}" >&2
      exit 1
    fi
  done < <(runtime_audit_denied_dylib_patterns)
}

runtime_audit_check_common_otool_refs() {
  local label="$1"
  shift
  local otool_files=("$@")

  runtime_audit_check_prefix_refs "$label" "${otool_files[@]}"
  runtime_audit_check_system_cxx_refs "$label" "${otool_files[@]}"
  runtime_audit_check_vapoursynth_rpath_refs "$label" "${otool_files[@]}"
  runtime_audit_check_homebrew_refs "$label" "${otool_files[@]}"
}

runtime_audit_check_static_bundle_otool_refs() {
  local label="$1"
  shift
  local otool_files=("$@")

  runtime_audit_check_common_otool_refs "$label" "${otool_files[@]}"
  runtime_audit_check_static_required_dylibs "$label" "${otool_files[@]}"
}

runtime_audit_check_dynamic_files() {
  local label="$1"
  local dynamic_file_list="$2"
  shift 2
  local exception_dirs=("$@")
  local allowed_runtime_patterns=()
  local pattern
  local dynamic_file
  local basename
  local allowed
  local exception_dir
  local denied_report="$AUDIT_DIR/runtime-unexpected-dynamic-files.txt"

  : > "$denied_report"

  while IFS= read -r pattern; do
    allowed_runtime_patterns+=("$pattern")
  done < <(runtime_audit_allowed_runtime_patterns)

  while IFS= read -r dynamic_file; do
    [[ -n "$dynamic_file" ]] || continue
    for exception_dir in "${exception_dirs[@]}"; do
      if [[ -n "$exception_dir" && "$dynamic_file" == "${exception_dir}"/* ]]; then
        continue 2
      fi
    done

    basename="$(basename "$dynamic_file")"
    allowed=0
    for pattern in "${allowed_runtime_patterns[@]}"; do
      if [[ "$basename" =~ $pattern ]]; then
        allowed=1
        break
      fi
    done

    if [[ "$allowed" -eq 0 ]]; then
      printf '%s\n' "$dynamic_file" >> "$denied_report"
    fi
  done < "$dynamic_file_list"

  if [[ -s "$denied_report" ]]; then
    echo "$label contains unexpected dynamic files outside explicit runtime exceptions:" >&2
    cat "$denied_report" >&2
    exit 1
  fi
}
