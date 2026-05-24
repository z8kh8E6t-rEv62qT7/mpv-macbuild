#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_source_env

ffmpeg_source_dir="$SOURCE_ROOT/ffmpeg"
samples_dir="${FFMPEG_FATE_SAMPLES:-${FATE_SAMPLES:-$BUILD_ROOT/fate-suite}}"
frei0r_source_dir="$SOURCE_PREFIX/lib/frei0r-1"
frei0r_fate_dir="$BUILD_ROOT/ffmpeg-fate/frei0r-1"

[[ -d "$ffmpeg_source_dir" ]] || die "FFmpeg source directory does not exist: $ffmpeg_source_dir"
[[ -f "$ffmpeg_source_dir/ffbuild/config.mak" ]] || die "FFmpeg source tree is not configured: $ffmpeg_source_dir"

resolve_fate_jobs() {
  local jobs

  if [[ -n "${FFMPEG_FATE_JOBS:-}" ]]; then
    printf '%s\n' "$FFMPEG_FATE_JOBS"
    return
  fi

  if jobs="$(ci_jobs 2>/dev/null)" && [[ -n "$jobs" ]]; then
    printf '%s\n' "$jobs"
    return
  fi

  printf '8\n'
}

prepare_frei0r_fate_plugins() {
  local plugin
  local alias
  local count=0

  [[ -d "$frei0r_source_dir" ]] || die "missing frei0r plugin directory: $frei0r_source_dir"

  rm -rf "$frei0r_fate_dir"
  mkdir -p "$frei0r_fate_dir"

  shopt -s nullglob
  for plugin in "$frei0r_source_dir"/*.so; do
    alias="$frei0r_fate_dir/$(basename "${plugin%.so}").dylib"
    ln -s "$plugin" "$alias"
    count=$((count + 1))
  done
  shopt -u nullglob

  [[ "$count" -gt 0 ]] || die "no frei0r .so plugins found in $frei0r_source_dir"
}

write_fate_summary() {
  local jobs="$1"
  local summary="$AUDIT_DIR/ffmpeg-fate-summary.md"

  {
    echo "# FFmpeg FATE Summary"
    echo
    echo "- ffmpeg source: \`$ffmpeg_source_dir\`"
    echo "- samples: \`$samples_dir\`"
    echo "- jobs: \`$jobs\`"
    echo "- runtime library path: \`$SOURCE_PREFIX/lib:$FFMPEG_PREFIX/lib\`"
    echo "- frei0r test plugin aliases: \`$frei0r_fate_dir\`"
  } > "$summary"
}

run_fate_with_runtime() {
  local jobs="$1"
  local dyld_library_path="$SOURCE_PREFIX/lib:$FFMPEG_PREFIX/lib"

  if [[ -n "${DYLD_LIBRARY_PATH:-}" ]]; then
    dyld_library_path="$dyld_library_path:$DYLD_LIBRARY_PATH"
  fi

  run_logged "ffmpeg-fate" \
    env \
      DYLD_LIBRARY_PATH="$dyld_library_path" \
      FREI0R_PATH="$frei0r_fate_dir" \
      make -C "$ffmpeg_source_dir" -j"$jobs" fate "SAMPLES=$samples_dir"
}

jobs="$(resolve_fate_jobs)"

mkdir -p "$samples_dir" "$AUDIT_DIR/logs"
prepare_frei0r_fate_plugins
write_fate_summary "$jobs"

run_logged "ffmpeg-fate-rsync" \
  make -C "$ffmpeg_source_dir" fate-rsync "SAMPLES=$samples_dir"
run_logged "ffmpeg-fate-clear-reports" \
  make -C "$ffmpeg_source_dir" fate-clear-reports "SAMPLES=$samples_dir"
run_fate_with_runtime "$jobs"
