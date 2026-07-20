#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$CI_SCRIPT_ROOT/lib/runtime-audit-common.sh"

require_source_env

mkdir -p "$AUDIT_DIR"

ffmpeg_tools=(
  "$FFMPEG_PREFIX/bin/ffmpeg"
  "$FFMPEG_PREFIX/bin/ffprobe"
  "$FFMPEG_PREFIX/bin/ffplay"
)

for ffmpeg_tool in "${ffmpeg_tools[@]}"; do
  [[ -x "$ffmpeg_tool" ]] || die "missing executable FFmpeg tool: $ffmpeg_tool"
done

run_logged "ffmpeg-runtime-dynamic-file-list" \
  sh -c 'find "$1" -type f \( -name "*.dylib" -o -name "*.so" -o -name "*.bundle" \) | sort > "$2"' \
  sh "$FFMPEG_PREFIX" "$AUDIT_DIR/ffmpeg-runtime-dynamic-files.txt"

: > "$AUDIT_DIR/ffmpeg-prefix-otool.txt"

for ffmpeg_tool in "${ffmpeg_tools[@]}"; do
  write_runtime_load_report "$ffmpeg_tool" "$(basename "$ffmpeg_tool")" >> "$AUDIT_DIR/ffmpeg-prefix-otool.txt"
done

while IFS= read -r dynamic_file; do
  write_runtime_load_report "$dynamic_file" "${dynamic_file#$FFMPEG_PREFIX/}" >> "$AUDIT_DIR/ffmpeg-prefix-otool.txt"
done < "$AUDIT_DIR/ffmpeg-runtime-dynamic-files.txt"

run_logged "ffmpeg-prefix-otool" cat "$AUDIT_DIR/ffmpeg-prefix-otool.txt"

local_close_symbols="$AUDIT_DIR/ffmpeg-local-close-symbols.txt"
if "$NM" -m "$FFMPEG_PREFIX/bin/ffmpeg" \
  | awk '$0 ~ /\(__TEXT,__text\) non-external _close$/ { print }' \
  > "$local_close_symbols"; then
  :
else
  die "failed to inspect FFmpeg local close symbols with $NM"
fi

if [[ -s "$local_close_symbols" ]]; then
  cat "$local_close_symbols"
  die "FFmpeg binary contains local _close symbols; POSIX close(fd) may bind to an internal callback"
fi

run_logged "ffmpeg-local-close-symbols" cat "$local_close_symbols"

for library in avcodec avdevice avfilter avformat avutil swresample swscale; do
  find "$FFMPEG_PREFIX/lib" -maxdepth 1 -name "lib${library}*.dylib" -print -quit | grep -q . \
    || die "missing shared FFmpeg library: lib${library}"
  for ffmpeg_tool in "${ffmpeg_tools[@]}"; do
    otool -L "$ffmpeg_tool" | grep -E "lib${library}[.][0-9]+[.]dylib" >/dev/null \
      || die "$(basename "$ffmpeg_tool") does not dynamically link lib${library}"
  done
done
runtime_audit_check_otool_refs \
  "FFmpeg install prefix" \
  "$AUDIT_DIR/ffmpeg-prefix-otool.txt"
