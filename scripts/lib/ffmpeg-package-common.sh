#!/usr/bin/env bash
set -euo pipefail

standard_ffmpeg_libraries=(avcodec avdevice avfilter avformat avutil swresample swscale)

stage_ffmpeg_shared_prefix() {
  local source_prefix="$1"
  local stage_root="$2"
  local target
  local library
  local pc

  rm -rf "$stage_root"
  mkdir -p "$stage_root"
  cp -R "$source_prefix"/. "$stage_root"/
  find "$stage_root" -type f \( -name '*.a' -o -name '*.la' \) -delete

  for library in "${standard_ffmpeg_libraries[@]}"; do
    find "$stage_root/lib" -maxdepth 1 -name "lib${library}*.dylib" -print -quit | grep -q . \
      || die "missing shared FFmpeg library: lib${library}"
  done

  copy_llvm_runtime_into_dir "$stage_root/lib"
  while IFS= read -r target; do
    is_mach_o "$target" || continue
    if [[ "$target" == "$stage_root/bin/"* ]]; then
      rewrite_llvm_runtime_refs_to_bundle "$target" "@executable_path/../lib"
      add_rpath_if_missing "$target" "@executable_path/../lib"
    else
      rewrite_llvm_runtime_refs_to_bundle "$target" "@loader_path"
    fi
  done < <(find "$stage_root/bin" "$stage_root/lib" -type f 2>/dev/null | sort)

  while IFS= read -r pc; do
    python3 - "$pc" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = re.sub(r'^prefix=.*$', 'prefix=${pcfiledir}/../..', text, count=1, flags=re.MULTILINE)
path.write_text(text)
PY
  done < <(find "$stage_root/lib/pkgconfig" -type f -name '*.pc' | sort)
}

validate_ffmpeg_shared_stage() {
  local root="$1"
  shift
  local expected_tools=("$@")
  local library
  local tool
  local refs
  local staged_path
  local staged_tool
  local expected_tool
  local is_expected

  [[ "${#expected_tools[@]}" -gt 0 ]] || die "no expected FFmpeg tools specified"

  if find "$root" -type f -name '*.a' -print -quit | grep -q .; then
    die "public FFmpeg package contains a static archive"
  fi
  for tool in "${expected_tools[@]}"; do
    [[ -x "$root/bin/$tool" ]] || die "missing FFmpeg tool: $tool"
    refs="$(otool -L "$root/bin/$tool")"
    for library in "${standard_ffmpeg_libraries[@]}"; do
      grep -E "lib${library}[.][0-9]+[.]dylib" <<< "$refs" >/dev/null \
        || die "$tool does not dynamically link lib${library}"
    done
    env -u DYLD_LIBRARY_PATH -u DYLD_FRAMEWORK_PATH \
      -u DYLD_FALLBACK_LIBRARY_PATH -u DYLD_FALLBACK_FRAMEWORK_PATH \
      "$root/bin/$tool" -version >/dev/null
  done

  while IFS= read -r staged_path; do
    staged_tool="$(basename "$staged_path")"
    is_expected=0
    for expected_tool in "${expected_tools[@]}"; do
      if [[ "$staged_tool" == "$expected_tool" ]]; then
        is_expected=1
        break
      fi
    done
    [[ "$is_expected" -eq 1 ]] || die "unexpected FFmpeg tool: $staged_tool"
  done < <(find "$root/bin" -mindepth 1 -maxdepth 1 -print | sort)
}
