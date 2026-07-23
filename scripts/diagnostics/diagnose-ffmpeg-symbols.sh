#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

ffmpeg_bin="${1:-}"
report_stem="${2:-ffmpeg-symbol-diagnostics}"
if [[ -z "$ffmpeg_bin" ]]; then
  [[ -n "${FFMPEG_PREFIX:-}" ]] || die "FFMPEG_PREFIX is not set and no FFmpeg binary argument was provided"
  ffmpeg_bin="$FFMPEG_PREFIX/bin/ffmpeg"
fi

[[ -x "$ffmpeg_bin" ]] || die "missing executable FFmpeg tool: $ffmpeg_bin"
case "$report_stem" in
  "" | *[!A-Za-z0-9._-]*) die "invalid FFmpeg diagnostics report stem: $report_stem" ;;
esac

mkdir -p "$AUDIT_DIR" "$AUDIT_DIR/logs"

report="$AUDIT_DIR/${report_stem}.txt"
lldb_commands="$AUDIT_DIR/logs/${report_stem}.lldb"
nm_tool="${NM:-nm}"

have_tool() {
  command -v "$1" >/dev/null 2>&1
}

append_section() {
  local title="$1"
  shift

  {
    echo
    echo "## $title"
    echo
    if ! "$@" 2>&1; then
      echo "command failed: $*"
    fi
  } >> "$report"
}

symbol_table() {
  "$nm_tool" -m "$ffmpeg_bin" | awk '
    $NF == "_close" ||
    $NF == "_file_close" ||
    $NF == "_ff_cbs_close" ||
    $NF == "_ff_cbs_fragment_free" ||
    $NF == "_avio_close" ||
    $NF == "_ffurl_closep" {
      print
    }
  '
}

undefined_close_imports() {
  "$nm_tool" -an "$ffmpeg_bin" | awk '$1 == "U" && ($2 == "_close" || $2 == "_close$NOCANCEL") { print }'
}

indirect_close_symbols() {
  otool -Iv "$ffmpeg_bin" | awk '$NF == "_close" || $NF == "_close$NOCANCEL" || $NF == "__error" || $NF == "_free" { print }'
}

source_context() {
  local source_root="${SOURCE_ROOT:-}"
  local file_c=""
  local apv_parser=""

  if [[ -n "$source_root" && -d "$source_root" ]]; then
    file_c="$(find "$source_root" -path '*/libavformat/file.c' -type f -print -quit 2>/dev/null || true)"
    apv_parser="$(find "$source_root" -path '*/libavcodec/apv_parser.c' -type f -print -quit 2>/dev/null || true)"
  fi

  if [[ -n "$file_c" ]]; then
    echo "### libavformat/file.c"
    echo
    echo "path: $file_c"
    sed -n '218,230p' "$file_c"
    echo
  else
    echo "libavformat/file.c not found under SOURCE_ROOT=${source_root:-<unset>}"
  fi

  if [[ -n "$apv_parser" ]]; then
    echo "### libavcodec/apv_parser.c"
    echo
    echo "path: $apv_parser"
    sed -n '192,214p' "$apv_parser"
  else
    echo "libavcodec/apv_parser.c not found under SOURCE_ROOT=${source_root:-<unset>}"
  fi
}

write_lldb_commands() {
  local address

  {
    printf 'target create "%s"\n' "$ffmpeg_bin"
    while IFS= read -r address; do
      printf 'image lookup -a 0x%s\n' "$address"
      printf 'disassemble -s 0x%s -c 18\n' "$address"
    done < <("$nm_tool" -m "$ffmpeg_bin" | awk '$NF == "_file_close" { print $1 }')
    while IFS= read -r address; do
      printf 'image lookup -a 0x%s\n' "$address"
      printf 'disassemble -s 0x%s -c 18\n' "$address"
    done < <("$nm_tool" -m "$ffmpeg_bin" | awk '$NF == "_close" { print $1 }')
  } > "$lldb_commands"
}

lldb_disassembly() {
  if ! have_tool lldb; then
    echo "lldb not available"
    return 0
  fi

  write_lldb_commands
  lldb --batch -s "$lldb_commands"
}

{
  echo "# FFmpeg Symbol Diagnostics"
  echo
  echo "generated_utc: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "ffmpeg: $ffmpeg_bin"
  echo "nm: $nm_tool"
  echo
  echo "This report is diagnostic-only. It does not change FFmpeg build flags, smoke test commands, or smoke test results."
} > "$report"

append_section "File Identity" file "$ffmpeg_bin"

if have_tool dwarfdump; then
  append_section "Mach-O UUID" dwarfdump --uuid "$ffmpeg_bin"
fi

append_section "Selected Mach-O Symbols" symbol_table
append_section "Undefined POSIX close Imports" undefined_close_imports
append_section "Indirect Symbol Table close Entries" indirect_close_symbols
append_section "Relevant Source Context" source_context
append_section "Bounded LLDB Disassembly" lldb_disassembly

echo "wrote FFmpeg symbol diagnostics: $report"
