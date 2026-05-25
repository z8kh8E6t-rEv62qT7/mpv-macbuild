#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$CI_SCRIPT_ROOT/lib/runtime-audit-common.sh"

require_source_env

cd "$MPV_DIR"
bundle_binary="build/mpv.app/Contents/MacOS/mpv"
source_built_exception_dir="build/mpv.app/Contents/Resources/source-built"

audit_vulkan_manifest_libraries() {
  python3 - <<'PY'
import json
import pathlib
import sys

bundle_root = pathlib.Path("build/mpv.app/Contents")
manifest_root = bundle_root / "Resources" / "vulkan"
failures = []

for manifest in sorted(manifest_root.rglob("*.json")):
    try:
        data = json.loads(manifest.read_text())
    except json.JSONDecodeError as exc:
        failures.append(f"{manifest}: invalid JSON: {exc}")
        continue

    library_path = None
    if isinstance(data.get("ICD"), dict):
        library_path = data["ICD"].get("library_path")
    if library_path is None and isinstance(data.get("layer"), dict):
        library_path = data["layer"].get("library_path")
    if not library_path:
        continue

    candidate = pathlib.Path(library_path)
    if not candidate.is_absolute():
        candidate = manifest.parent / candidate
    if not candidate.resolve(strict=False).is_file():
        failures.append(f"{manifest}: missing Vulkan library {library_path} -> {candidate}")

if failures:
    print("mpv.app bundle has broken Vulkan manifest library paths:", file=sys.stderr)
    for failure in failures:
        print(f"  {failure}", file=sys.stderr)
    sys.exit(1)
PY
}

mkdir -p "$AUDIT_DIR"
run_logged "bundle-codesign-verify" codesign --verify --deep --strict --verbose=2 build/mpv.app
run_logged "bundle-vulkan-manifest-libraries" audit_vulkan_manifest_libraries
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

runtime_audit_check_dynamic_files \
  "mpv.app bundle" \
  "$AUDIT_DIR/bundle-dynamic-files.txt" \
  "$source_built_exception_dir"
runtime_audit_check_otool_refs \
  "mpv.app bundle" \
  "$AUDIT_DIR/bundle-otool.txt" \
  "$AUDIT_DIR/bundle-dynamic-otool.txt"

if grep -F /opt/homebrew "$AUDIT_DIR/bundle-otool.txt" "$AUDIT_DIR/bundle-dynamic-otool.txt" >/dev/null; then
  echo "mpv.app bundle retains Homebrew runtime references after bundling:" >&2
  grep -F /opt/homebrew "$AUDIT_DIR/bundle-otool.txt" "$AUDIT_DIR/bundle-dynamic-otool.txt" >&2
  exit 1
fi

if [[ -d "$source_built_exception_dir" ]]; then
  find "$source_built_exception_dir" -type f | sort > "$AUDIT_DIR/plugin-exceptions.txt"
else
  : > "$AUDIT_DIR/plugin-exceptions.txt"
fi
