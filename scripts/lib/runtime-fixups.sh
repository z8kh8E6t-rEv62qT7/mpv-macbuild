#!/usr/bin/env bash
set -euo pipefail

runtime_llvm_paths() {
  local llvm_prefix="${LLVM_PREFIX:?LLVM_PREFIX is not set}"

  LLVM_CXX_RUNTIME_DIR="${LLVM_CXX_RUNTIME_DIR:-$llvm_prefix/lib/c++}"
  LLVM_UNWIND_RUNTIME_DIR="${LLVM_UNWIND_RUNTIME_DIR:-$llvm_prefix/lib/unwind}"
  LLVM_LIBCXX_DYLIB="${LLVM_LIBCXX_DYLIB:-$LLVM_CXX_RUNTIME_DIR/libc++.1.dylib}"
  LLVM_LIBCXXABI_DYLIB="${LLVM_LIBCXXABI_DYLIB:-$LLVM_CXX_RUNTIME_DIR/libc++abi.1.dylib}"
  LLVM_LIBUNWIND_DYLIB="${LLVM_LIBUNWIND_DYLIB:-$LLVM_UNWIND_RUNTIME_DIR/libunwind.1.dylib}"
}

require_llvm_runtime_dylibs() {
  local library

  runtime_llvm_paths
  for library in "$LLVM_LIBCXX_DYLIB" "$LLVM_LIBCXXABI_DYLIB" "$LLVM_LIBUNWIND_DYLIB"; do
    [[ -f "$library" ]] || die "missing Homebrew LLVM runtime dylib: $library"
  done
}

llvm_runtime_link_flags() {
  require_llvm_runtime_dylibs
  printf '%s ' \
    -nostdlib++ \
    "-Wl,-rpath,$LLVM_CXX_RUNTIME_DIR" \
    "-Wl,-rpath,$LLVM_UNWIND_RUNTIME_DIR" \
    "-Wl,-needed_library,$LLVM_LIBCXX_DYLIB" \
    "-Wl,-needed_library,$LLVM_LIBCXXABI_DYLIB" \
    "-Wl,-needed_library,$LLVM_LIBUNWIND_DYLIB"
}

otool_load_lines() {
  local binary="$1"
  otool -L "$binary" | awk '/^[[:space:]]/ { print }'
}

otool_refs() {
  local binary="$1"
  otool_load_lines "$binary" | awk '{ print $1 }'
}

is_mach_o() {
  local binary="$1"
  otool -hv "$binary" >/dev/null 2>&1
}

dylib_id() {
  local binary="$1"
  otool -D "$binary" 2>/dev/null | tail -n +2 | head -n1 || true
}

otool_dependency_refs() {
  local binary="$1"
  local id

  id="$(dylib_id "$binary")"
  while IFS= read -r ref; do
    [[ -n "$id" && "$ref" == "$id" ]] && continue
    printf '%s\n' "$ref"
  done < <(otool_refs "$binary")
}

change_dylib_ref_if_present() {
  local binary="$1"
  local old_ref="$2"
  local new_ref="$3"

  [[ "$old_ref" != "$new_ref" ]] || return 0
  if otool_dependency_refs "$binary" | grep -Fx "$old_ref" >/dev/null; then
    install_name_tool -change "$old_ref" "$new_ref" "$binary"
  fi
}

add_rpath_if_missing() {
  local binary="$1"
  local rpath="$2"

  if ! rpath_refs "$binary" | grep -Fx "$rpath" >/dev/null; then
    install_name_tool -add_rpath "$rpath" "$binary"
  fi
}

rpath_refs() {
  local binary="$1"
  otool -l "$binary" | awk '/cmd LC_RPATH/{getline; getline; print $2}'
}

delete_rpath_if_present() {
  local binary="$1"
  local rpath="$2"

  if rpath_refs "$binary" | grep -Fx "$rpath" >/dev/null; then
    install_name_tool -delete_rpath "$rpath" "$binary"
  fi
}

normalize_llvm_runtime_refs() {
  local binary="$1"

  require_llvm_runtime_dylibs
  [[ -e "$binary" ]] || die "cannot normalize missing binary: $binary"

  change_dylib_ref_if_present "$binary" /usr/lib/libc++.1.dylib "$LLVM_LIBCXX_DYLIB"
  change_dylib_ref_if_present "$binary" /usr/lib/libc++abi.dylib "$LLVM_LIBCXXABI_DYLIB"
  change_dylib_ref_if_present "$binary" /usr/lib/libunwind.dylib "$LLVM_LIBUNWIND_DYLIB"
  change_dylib_ref_if_present "$binary" /usr/lib/libunwind.1.dylib "$LLVM_LIBUNWIND_DYLIB"
  add_rpath_if_missing "$binary" "$LLVM_CXX_RUNTIME_DIR"
  add_rpath_if_missing "$binary" "$LLVM_UNWIND_RUNTIME_DIR"
}

write_runtime_load_report() {
  local target="$1"
  local label="${2:-$target}"

  echo "## $label"
  otool_load_lines "$target" || true
  echo
  echo "## rpaths: $label"
  rpath_refs "$target" || true
  echo
}

delete_llvm_runtime_rpaths() {
  local binary="$1"

  require_llvm_runtime_dylibs
  delete_rpath_if_present "$binary" "$LLVM_CXX_RUNTIME_DIR"
  delete_rpath_if_present "$binary" "$LLVM_UNWIND_RUNTIME_DIR"
}

assert_uses_llvm_runtime_refs() {
  local label="$1"
  shift
  local binary
  local refs
  local libcxx_refs

  require_llvm_runtime_dylibs
  libcxx_refs="$(otool_refs "$LLVM_LIBCXX_DYLIB")"

  if ! grep -Fx "$LLVM_LIBCXXABI_DYLIB" <<< "$libcxx_refs" >/dev/null &&
     ! grep -Fx "@rpath/$(basename "$LLVM_LIBCXXABI_DYLIB")" <<< "$libcxx_refs" >/dev/null; then
    die "Homebrew LLVM libc++ does not resolve libc++abi through the LLVM runtime: $LLVM_LIBCXX_DYLIB"
  fi
  if ! grep -Fx "$LLVM_LIBUNWIND_DYLIB" <<< "$libcxx_refs" >/dev/null &&
     ! grep -Fx "@rpath/$(basename "$LLVM_LIBUNWIND_DYLIB")" <<< "$libcxx_refs" >/dev/null; then
    die "Homebrew LLVM libc++ does not resolve libunwind through the LLVM runtime: $LLVM_LIBCXX_DYLIB"
  fi

  for binary in "$@"; do
    [[ -e "$binary" ]] || die "missing runtime audit target: $binary"
    refs="$(otool_refs "$binary")"
    if grep -Fx /usr/lib/libc++.1.dylib <<< "$refs" >/dev/null; then
      die "$label links system libc++: $binary"
    fi
    if grep -Fx /usr/lib/libc++abi.dylib <<< "$refs" >/dev/null; then
      die "$label links system libc++abi: $binary"
    fi
    if grep -Fx /usr/lib/libunwind.dylib <<< "$refs" >/dev/null; then
      die "$label links system libunwind: $binary"
    fi
    if ! grep -Fx "$LLVM_LIBCXX_DYLIB" <<< "$refs" >/dev/null; then
      die "$label does not link Homebrew LLVM libc++: $binary"
    fi
    if ! grep -Fx "$LLVM_LIBUNWIND_DYLIB" <<< "$refs" >/dev/null; then
      die "$label does not link Homebrew LLVM libunwind: $binary"
    fi
  done
}

assert_no_system_cxx_runtime_refs() {
  local label="$1"
  shift
  local binary
  local refs

  for binary in "$@"; do
    [[ -e "$binary" ]] || die "missing runtime audit target: $binary"
    refs="$(otool_refs "$binary")"
    if grep -Fx /usr/lib/libc++.1.dylib <<< "$refs" >/dev/null; then
      die "$label links system libc++: $binary"
    fi
    if grep -Fx /usr/lib/libc++abi.dylib <<< "$refs" >/dev/null; then
      die "$label links system libc++abi: $binary"
    fi
    if grep -Fx /usr/lib/libunwind.dylib <<< "$refs" >/dev/null; then
      die "$label links system libunwind: $binary"
    fi
    if grep -Fx /usr/lib/libunwind.1.dylib <<< "$refs" >/dev/null; then
      die "$label links system libunwind: $binary"
    fi
  done
}

copy_llvm_runtime_into_dir() {
  local dest_dir="$1"
  local library
  local dest

  require_llvm_runtime_dylibs
  mkdir -p "$dest_dir"
  for library in "$LLVM_LIBCXX_DYLIB" "$LLVM_LIBCXXABI_DYLIB" "$LLVM_LIBUNWIND_DYLIB"; do
    dest="$dest_dir/$(basename "$library")"
    cp "$library" "$dest"
    chmod u+w "$dest"
  done

  install_name_tool -id "@rpath/$(basename "$LLVM_LIBCXX_DYLIB")" "$dest_dir/$(basename "$LLVM_LIBCXX_DYLIB")"
  install_name_tool -id "@rpath/$(basename "$LLVM_LIBCXXABI_DYLIB")" "$dest_dir/$(basename "$LLVM_LIBCXXABI_DYLIB")"
  install_name_tool -id "@rpath/$(basename "$LLVM_LIBUNWIND_DYLIB")" "$dest_dir/$(basename "$LLVM_LIBUNWIND_DYLIB")"

  change_dylib_ref_if_present "$dest_dir/$(basename "$LLVM_LIBCXX_DYLIB")" \
    @rpath/$(basename "$LLVM_LIBCXXABI_DYLIB") "@loader_path/$(basename "$LLVM_LIBCXXABI_DYLIB")"
  change_dylib_ref_if_present "$dest_dir/$(basename "$LLVM_LIBCXX_DYLIB")" \
    @rpath/$(basename "$LLVM_LIBUNWIND_DYLIB") "@loader_path/$(basename "$LLVM_LIBUNWIND_DYLIB")"
  change_dylib_ref_if_present "$dest_dir/$(basename "$LLVM_LIBCXXABI_DYLIB")" \
    @rpath/$(basename "$LLVM_LIBUNWIND_DYLIB") "@loader_path/$(basename "$LLVM_LIBUNWIND_DYLIB")"
}

rewrite_llvm_runtime_refs_to_bundle() {
  local binary="$1"
  local loader_ref="$2"

  require_llvm_runtime_dylibs
  change_dylib_ref_if_present "$binary" /usr/lib/libc++.1.dylib "$loader_ref/$(basename "$LLVM_LIBCXX_DYLIB")"
  change_dylib_ref_if_present "$binary" /usr/lib/libc++abi.dylib "$loader_ref/$(basename "$LLVM_LIBCXXABI_DYLIB")"
  change_dylib_ref_if_present "$binary" /usr/lib/libunwind.dylib "$loader_ref/$(basename "$LLVM_LIBUNWIND_DYLIB")"
  change_dylib_ref_if_present "$binary" /usr/lib/libunwind.1.dylib "$loader_ref/$(basename "$LLVM_LIBUNWIND_DYLIB")"
  change_dylib_ref_if_present "$binary" "@executable_path/lib/$(basename "$LLVM_LIBCXX_DYLIB")" "$loader_ref/$(basename "$LLVM_LIBCXX_DYLIB")"
  change_dylib_ref_if_present "$binary" "@executable_path/lib/$(basename "$LLVM_LIBCXXABI_DYLIB")" "$loader_ref/$(basename "$LLVM_LIBCXXABI_DYLIB")"
  change_dylib_ref_if_present "$binary" "@executable_path/lib/$(basename "$LLVM_LIBUNWIND_DYLIB")" "$loader_ref/$(basename "$LLVM_LIBUNWIND_DYLIB")"
  change_dylib_ref_if_present "$binary" "@rpath/$(basename "$LLVM_LIBCXX_DYLIB")" "$loader_ref/$(basename "$LLVM_LIBCXX_DYLIB")"
  change_dylib_ref_if_present "$binary" "@rpath/$(basename "$LLVM_LIBCXXABI_DYLIB")" "$loader_ref/$(basename "$LLVM_LIBCXXABI_DYLIB")"
  change_dylib_ref_if_present "$binary" "@rpath/$(basename "$LLVM_LIBUNWIND_DYLIB")" "$loader_ref/$(basename "$LLVM_LIBUNWIND_DYLIB")"
  change_dylib_ref_if_present "$binary" "$LLVM_LIBCXX_DYLIB" "$loader_ref/$(basename "$LLVM_LIBCXX_DYLIB")"
  change_dylib_ref_if_present "$binary" "$LLVM_LIBCXXABI_DYLIB" "$loader_ref/$(basename "$LLVM_LIBCXXABI_DYLIB")"
  change_dylib_ref_if_present "$binary" "$LLVM_LIBUNWIND_DYLIB" "$loader_ref/$(basename "$LLVM_LIBUNWIND_DYLIB")"
}

loader_path_to_dir() {
  local binary="$1"
  local target_dir="$2"

  python3 - "$binary" "$target_dir" <<'PY'
import os
import sys

binary_dir = os.path.dirname(os.path.normpath(sys.argv[1]))
target_dir = os.path.normpath(sys.argv[2])
relative = os.path.relpath(target_dir, binary_dir)
if relative == ".":
    print("@loader_path")
else:
    print(f"@loader_path/{relative}")
PY
}

normalize_vapoursynth_runtime_dir() {
  local runtime_dir="$1"
  local dylib
  local old_ref
  local basename
  local target

  [[ -d "$runtime_dir" ]] || die "missing VapourSynth runtime dir: $runtime_dir"

  while IFS= read -r dylib; do
    basename="$(basename "$dylib")"
    install_name_tool -id "@rpath/$basename" "$dylib"
  done < <(find "$runtime_dir" -maxdepth 1 -type f \( -name 'libvsscript*.dylib' -o -name 'libvapoursynth*.dylib' \) | sort)

  while IFS= read -r dylib; do
    while IFS= read -r old_ref; do
      [[ "$(basename "$old_ref")" == "$(basename "$dylib")" ]] && continue
      basename="$(basename "$old_ref")"
      install_name_tool -change "$old_ref" "@loader_path/$basename" "$dylib"
    done < <(otool_dependency_refs "$dylib" | awk '/libvsscript.*[.]dylib|libvapoursynth.*[.]dylib/')
  done < <(find "$runtime_dir" -maxdepth 1 -type f \( -name 'libvsscript*.dylib' -o -name 'libvapoursynth*.dylib' \) | sort)

  while IFS= read -r dylib; do
    while IFS= read -r old_ref; do
      basename="$(basename "$old_ref")"
      install_name_tool -change "$old_ref" "@loader_path/$basename" "$dylib"
    done < <(otool_dependency_refs "$dylib" | awk '/libvsscript.*[.]dylib|libvapoursynth.*[.]dylib/')
  done < <(find "$runtime_dir" -maxdepth 1 -type f \( -name '*.so' -o -name '*.bundle' \) | sort)

  while IFS= read -r target; do
    is_mach_o "$target" || continue
    while IFS= read -r old_ref; do
      basename="$(basename "$old_ref")"
      install_name_tool -change "$old_ref" "@loader_path/$basename" "$target"
    done < <(otool_dependency_refs "$target" | awk '/libvsscript.*[.]dylib|libvapoursynth.*[.]dylib/')
  done < <(find "$runtime_dir" -maxdepth 1 -type f -perm -111 ! -name '*.dylib' ! -name '*.so' ! -name '*.bundle' | sort)
}

rewrite_vapoursynth_ref() {
  local binary="$1"
  local new_ref="$2"
  local old_ref

  while IFS= read -r old_ref; do
    change_dylib_ref_if_present "$binary" "$old_ref" "$new_ref"
  done < <(otool_dependency_refs "$binary" | awk '/libvsscript.*[.]dylib/')
}

has_vapoursynth_ref() {
  local binary="$1"

  is_mach_o "$binary" || return 1
  otool_dependency_refs "$binary" | awk '/libvsscript.*[.]dylib|libvapoursynth.*[.]dylib/ {found=1} END {exit found ? 0 : 1}'
}
