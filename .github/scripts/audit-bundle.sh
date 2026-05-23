#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/common.sh"
source "$script_dir/runtime-audit-common.sh"

require_source_env

cd "$MPV_DIR"
bundle_binary="build/mpv.app/Contents/MacOS/mpv"
plugin_exception_dir="build/mpv.app/Contents/PlugIns/source-built"

mkdir -p "$AUDIT_DIR"
run_logged "bundle-main-otool" bash -c '
  source "$3/common.sh"
  write_runtime_load_report "$1" > "$2"
' bash "$bundle_binary" "$AUDIT_DIR/bundle-otool.txt" "$CI_SCRIPT_DIR"
run_logged "bundle-dynamic-file-list" sh -c 'find build/mpv.app -type f \( -name "*.dylib" -o -name "*.so" -o -name "*.bundle" \) | sort > "$1"' sh "$AUDIT_DIR/bundle-dynamic-files.txt"
: > "$AUDIT_DIR/bundle-dynamic-otool.txt"

while IFS= read -r dynamic_file; do
  write_runtime_load_report "$dynamic_file" >> "$AUDIT_DIR/bundle-dynamic-otool.txt"
done < "$AUDIT_DIR/bundle-dynamic-files.txt"

run_logged "bundle-dynamic-otool" cat "$AUDIT_DIR/bundle-dynamic-otool.txt"

runtime_audit_check_dynamic_files "mpv.app bundle" "$AUDIT_DIR/bundle-dynamic-files.txt" "$plugin_exception_dir"
runtime_audit_check_otool_refs \
  "mpv.app bundle" \
  "$AUDIT_DIR/bundle-otool.txt" \
  "$AUDIT_DIR/bundle-dynamic-otool.txt"

if grep -F /opt/homebrew "$AUDIT_DIR/bundle-otool.txt" "$AUDIT_DIR/bundle-dynamic-otool.txt" >/dev/null; then
  echo "mpv.app bundle retains Homebrew runtime references after bundling:" >&2
  grep -F /opt/homebrew "$AUDIT_DIR/bundle-otool.txt" "$AUDIT_DIR/bundle-dynamic-otool.txt" >&2
  exit 1
fi

if [[ -d "$plugin_exception_dir" ]]; then
  find "$plugin_exception_dir" -type f | sort > "$AUDIT_DIR/plugin-exceptions.txt"
else
  : > "$AUDIT_DIR/plugin-exceptions.txt"
fi
