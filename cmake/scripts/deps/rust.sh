#!/usr/bin/env bash

build_libdovi() {
  clone_or_update https://github.com/quietvoid/dovi_tool.git "$SOURCE_ROOT/dovi_tool"
  cargo cinstall \
    --manifest-path "$SOURCE_ROOT/dovi_tool/dolby_vision/Cargo.toml" \
    --release \
    --prefix "$SOURCE_PREFIX"
  remove_dynamic_artifacts
  pkg-config --exists dovi
}

build_rav1e() {
  clone_or_update https://github.com/xiph/rav1e.git "$SOURCE_ROOT/rav1e"
  cargo cinstall \
    --manifest-path "$SOURCE_ROOT/rav1e/Cargo.toml" \
    --release \
    --prefix "$SOURCE_PREFIX"
  remove_dynamic_artifacts
  pkg-config --exists rav1e
}

find_llvm_objcopy() {
  local candidate
  local -a candidates=()

  if [[ -n "${LLVM_PREFIX:-}" ]]; then
    candidates+=("$LLVM_PREFIX/bin/llvm-objcopy")
  fi
  if [[ -n "${OBJCOPY:-}" ]]; then
    candidates+=("$OBJCOPY")
  fi
  if candidate="$(command -v llvm-objcopy 2>/dev/null)"; then
    candidates+=("$candidate")
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  die "llvm-objcopy was not found"
}

write_defined_global_symbols() {
  local archive="$1"
  local output="$2"

  [[ -f "$archive" ]] || die "missing static archive: $archive"
  "$NM" -gU "$archive" 2>/dev/null |
    awk 'NF >= 3 && $2 ~ /^[A-Z]$/ && $2 !~ /^[UVW]$/ { print $3 }' |
    sort -u > "$output"
}

weaken_symbols_in_archive() {
  local archive="$1"
  local symbols_file="$2"
  local objcopy="$3"
  local tmp_archive="${archive}.weak.tmp"

  rm -f "$tmp_archive"
  "$objcopy" --weaken-symbols="$symbols_file" "$archive" "$tmp_archive"
  mv "$tmp_archive" "$archive"
  "$RANLIB" "$archive"
}

# Rust staticlibs embed Rust runtime objects. Keep each package's C API
# exported, but make shared Rust internals weak before FFmpeg links them.
normalize_rust_staticlibs() {
  local work_dir="$BUILD_ROOT/rust-staticlib-symbols"
  local overlap_symbols="$work_dir/overlap-symbols.txt"
  local report="$AUDIT_DIR/rust-staticlib-symbols.txt"
  local objcopy
  local overlap_count
  local index
  local archive_name
  local archive_path
  local symbols_file
  local weaken_file
  local weaken_count
  local -a archive_names=(libdovi librav1e librsvg-2)
  local -a archive_paths=(
    "$SOURCE_PREFIX/lib/libdovi.a"
    "$SOURCE_PREFIX/lib/librav1e.a"
    "$VCPKG_TARGET_PREFIX/lib/librsvg-2.a"
  )
  local -a symbol_files=()
  local -a weaken_files=()
  local -a weaken_counts=()

  mkdir -p "$work_dir" "$AUDIT_DIR"
  objcopy="$(find_llvm_objcopy)"

  for index in "${!archive_names[@]}"; do
    archive_name="${archive_names[$index]}"
    archive_path="${archive_paths[$index]}"
    symbols_file="$work_dir/$archive_name.global-symbols.txt"
    weaken_file="$work_dir/$archive_name.weaken-symbols.txt"
    write_defined_global_symbols "$archive_path" "$symbols_file"
    symbol_files+=("$symbols_file")
    weaken_files+=("$weaken_file")
  done

  sort "${symbol_files[@]}" | uniq -d > "$overlap_symbols"
  overlap_count="$(wc -l < "$overlap_symbols" | tr -d '[:space:]')"

  for index in "${!archive_names[@]}"; do
    comm -12 "${symbol_files[$index]}" "$overlap_symbols" > "${weaken_files[$index]}"
    weaken_count="$(wc -l < "${weaken_files[$index]}" | tr -d '[:space:]')"
    weaken_counts+=("$weaken_count")
  done

  {
    printf 'Rust staticlib overlap normalization\n'
    for index in "${!archive_names[@]}"; do
      printf '%s archive: %s\n' "${archive_names[$index]}" "${archive_paths[$index]}"
      printf '%s weakened symbol count: %s\n' "${archive_names[$index]}" "${weaken_counts[$index]}"
    done
    printf 'llvm-objcopy: %s\n' "$objcopy"
    printf 'overlap symbol count: %s\n' "$overlap_count"
    printf '\n'
    cat "$overlap_symbols"
  } > "$report"

  if [[ "$overlap_count" -eq 0 ]]; then
    echo "No overlapping Rust staticlib symbols found"
    return 0
  fi

  if grep -E '^_(dovi|rav1e|rsvg)_' "$overlap_symbols" >/dev/null; then
    die "public C API symbols unexpectedly overlap between Rust static libraries"
  fi

  for index in "${!archive_names[@]}"; do
    if [[ "${weaken_counts[$index]}" -gt 0 ]]; then
      weaken_symbols_in_archive "${archive_paths[$index]}" "${weaken_files[$index]}" "$objcopy"
    fi
  done

  echo "Weakened $overlap_count overlapping Rust staticlib symbols across libdovi.a, librav1e.a, and librsvg-2.a"
  echo "Report: $report"
}
