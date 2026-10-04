#!/usr/bin/env bash

# One package contract for staging, auditing and smoke tests.
ffmpeg_package_profile() {
  case "$1" in
    gpl)
      ffmpeg_libraries=(avcodec avdevice avfilter avformat avutil swresample swscale)
      ffmpeg_tools=(ffmpeg ffprobe ffplay)
      ;;
    lgpl)
      ffmpeg_libraries=(avcodec avfilter avformat avutil swscale)
      ffmpeg_tools=(ffmpeg)
      ;;
    *) die "unknown FFmpeg package profile: $1" ;;
  esac
}

stage_ffmpeg_shared_prefix() {
  local source_prefix="$1"
  local stage_root="$2"
  local profile="$3"
  local -a ffmpeg_libraries ffmpeg_tools
  ffmpeg_package_profile "$profile"
  local target
  local rpath
  local library
  local pc

  rm -rf "$stage_root"
  mkdir -p "$stage_root"
  cp -R "$source_prefix"/. "$stage_root"/
  find "$stage_root" -type f \( -name '*.a' -o -name '*.la' \) -delete

  for library in "${ffmpeg_libraries[@]}"; do
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
    if [[ "$profile" == lgpl ]]; then
      # A library consumer must also work without the original executable's rpath.
      [[ "$target" == "$stage_root/lib/"* ]] && add_rpath_if_missing "$target" "@loader_path"
      while IFS= read -r rpath; do
        case "$rpath" in /*) delete_rpath_if_present "$target" "$rpath" ;; esac
      done < <(rpath_refs "$target")
      codesign --force --sign - "$target"
    fi
  done < <(find "$stage_root/bin" "$stage_root/lib" -type f 2>/dev/null | sort)

  while IFS= read -r pc; do
    python3 - "$pc" "$profile" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = re.sub(r'^prefix=.*$', 'prefix=${pcfiledir}/../..', text, count=1, flags=re.MULTILINE)
if sys.argv[2] == "lgpl":
    # Only shared FFmpeg libraries are public. Private static-link flags would
    # expose dependency prefixes/archives that are deliberately not shipped.
    text = re.sub(r'^Libs[.]private:.*$', 'Libs.private:', text, flags=re.MULTILINE)
path.write_text(text)
PY
  done < <(find "$stage_root/lib/pkgconfig" -type f -name '*.pc' | sort)
}

validate_ffmpeg_shared_stage() {
  local root="$1"
  local profile="$2"
  local -a ffmpeg_libraries ffmpeg_tools
  ffmpeg_package_profile "$profile"
  local expected_tools=("${ffmpeg_tools[@]}")
  local library
  local tool
  local refs
  local staged_path
  local staged_tool
  local expected_tool
  local is_expected

  [[ "${#expected_tools[@]}" -gt 0 ]] || die "no expected FFmpeg tools specified"

  if find "$root" -type f \( -name '*.a' -o -name '*.la' \) -print -quit | grep -q .; then
    die "public FFmpeg package contains a static archive"
  fi
  for library in "${ffmpeg_libraries[@]}"; do
    [[ -f "$root/lib/lib${library}.dylib" && -d "$root/include/lib${library}" && -f "$root/lib/pkgconfig/lib${library}.pc" ]] \
      || die "incomplete FFmpeg development library: $library"
  done
  if [[ "$profile" == lgpl ]]; then
    python3 "$CI_SCRIPT_ROOT/audit/audit-lgpl-layout.py" "$root"
    validate_lgpl_runtime_closure "$root"
  fi
  for tool in "${expected_tools[@]}"; do
    [[ -x "$root/bin/$tool" ]] || die "missing FFmpeg tool: $tool"
    refs="$(otool -L "$root/bin/$tool")"
    for library in "${ffmpeg_libraries[@]}"; do
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

validate_lgpl_runtime_closure() {
  local root="$1"
  local target ref resolved rpath
  while IFS= read -r target; do
    is_mach_o "$target" || continue
    while IFS= read -r ref; do
      case "$ref" in
        /usr/lib/libz.*|/usr/lib/liblzma.*) die "dependency was not statically linked: $ref" ;;
        /usr/lib/*|/System/Library/Frameworks/*) continue ;;
        @rpath/*) resolved="$root/lib/${ref#@rpath/}" ;;
        @loader_path/*) resolved="$(dirname "$target")/${ref#@loader_path/}" ;;
        @executable_path/../lib/*) resolved="$root/lib/${ref#@executable_path/../lib/}" ;;
        *) die "non-relocatable LGPL dependency in $target: $ref" ;;
      esac
      [[ -f "$resolved" ]] || die "missing LGPL runtime dependency: $ref"
    done < <(otool_dependency_refs "$target")
    while IFS= read -r rpath; do
      case "$rpath" in
        @loader_path|@executable_path/../lib) ;;
        *) die "unexpected LGPL runtime search path: $rpath" ;;
      esac
    done < <(rpath_refs "$target")
  done < <(find "$root/bin" "$root/lib" -type f | sort)
}
