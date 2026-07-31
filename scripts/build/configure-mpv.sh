#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

require_source_env

mpv_ffmpeg_pkg_config_packages=(
  libavcodec
  libavdevice
  libavfilter
  libavformat
  libavutil
  libswresample
  libswscale
)
mpv_patches=(
  "$BUILDER_DIR/patch/mpv-0001-macos-bundle-luarocks-search-paths.patch"
)

create_mpv_ffmpeg_pkg_config_overlay() {
  local overlay_dir="$BUILD_ROOT/mpv-pkgconfig/ffmpeg"
  local package

  rm -rf "$overlay_dir"
  mkdir -p "$overlay_dir"

  for package in "${mpv_ffmpeg_pkg_config_packages[@]}"; do
    [[ -f "$FFMPEG_PREFIX/lib/pkgconfig/$package.pc" ]] ||
      die "missing FFmpeg pkg-config file: $FFMPEG_PREFIX/lib/pkgconfig/$package.pc"
    [[ -f "$FFMPEG_PREFIX/lib/$package.a" ]] ||
      die "missing FFmpeg static archive: $FFMPEG_PREFIX/lib/$package.a"
    cp "$FFMPEG_PREFIX/lib/pkgconfig/$package.pc" "$overlay_dir/$package.pc"
  done

  python3 - "$overlay_dir" "$FFMPEG_PREFIX/lib" "${mpv_ffmpeg_pkg_config_packages[@]}" <<'PY'
import pathlib
import re
import sys

overlay_dir = pathlib.Path(sys.argv[1])
libdir = pathlib.Path(sys.argv[2])
packages = sys.argv[3:]
replacements = {
    f"-l{package[3:]}": str(libdir / f"{package}.a")
    for package in packages
}

for package in packages:
    pc_path = overlay_dir / f"{package}.pc"
    text = pc_path.read_text()
    lines = []
    for line in text.splitlines():
        if line.startswith(("Libs:", "Libs.private:")):
            for lib_flag, archive in replacements.items():
                line = re.sub(
                    rf"(?<!\S){re.escape(lib_flag)}(?!\S)",
                    archive,
                    line,
                )
        lines.append(line)
    pc_path.write_text("\n".join(lines) + "\n")
PY

  export PKG_CONFIG_PATH="$overlay_dir${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export PKG_CONFIG_LIBDIR="$overlay_dir${PKG_CONFIG_LIBDIR:+:$PKG_CONFIG_LIBDIR}"
  echo "mpv FFmpeg pkg-config overlay: $overlay_dir"
}

assert_mpv_ffmpeg_pkg_config_resolves_to_ffmpeg_prefix() {
  local package
  local libs
  local archive
  local unresolved

  for package in "${mpv_ffmpeg_pkg_config_packages[@]}"; do
    libs="$(pkg-config --libs --static "$package")"
    archive="$FFMPEG_PREFIX/lib/$package.a"
    case " $libs " in
      *" $archive "*) ;;
      *)
        die "pkg-config $package does not resolve to $archive"
        ;;
    esac

    unresolved="-l${package#lib}"
    case " $libs " in
      *" $unresolved "*)
        die "pkg-config $package still exposes unresolved FFmpeg flag: $unresolved"
        ;;
    esac

    if grep -F "$VCPKG_TARGET_PREFIX/lib/$package.a" <<< "$libs" >/dev/null ||
       grep -F "$VCPKG_TARGET_PREFIX/lib/pkgconfig/../../lib/$package.a" <<< "$libs" >/dev/null; then
      die "pkg-config $package resolves FFmpeg archive from vcpkg: $libs"
    fi
  done
}

resolve_mpv_ffmpeg_header_version() {
  local package="$1"
  local macro_prefix
  local output

  macro_prefix="$(printf '%s' "$package" | tr '[:lower:]' '[:upper:]')"
  output="$(
    # CFLAGS is intentionally expanded into the compiler arguments.
    # shellcheck disable=SC2086
    "$CC" $CFLAGS -E -P -x c - <<EOF
#include <$package/version.h>
${macro_prefix}_VERSION_MAJOR.${macro_prefix}_VERSION_MINOR.${macro_prefix}_VERSION_MICRO
EOF
  )"
  output="${output##*$'\n'}"
  printf '%s' "$output" | tr -d '[:space:]'
}

assert_mpv_ffmpeg_headers_match_pkg_config() {
  local package
  local expected_version
  local header_version

  for package in "${mpv_ffmpeg_pkg_config_packages[@]}"; do
    expected_version="$(pkg-config --modversion "$package")"
    header_version="$(resolve_mpv_ffmpeg_header_version "$package")"
    [[ "$header_version" == "$expected_version" ]] ||
      die "$package header version $header_version does not match pkg-config version $expected_version"
    echo "$package header version: $header_version"
  done
}

assert_mpv_build_uses_ffmpeg_prefix_archives() {
  local build_ninja="build/build.ninja"
  local package
  local archive

  [[ -f "$build_ninja" ]] || die "missing mpv build manifest: $build_ninja"

  for package in "${mpv_ffmpeg_pkg_config_packages[@]}"; do
    archive="$FFMPEG_PREFIX/lib/$package.a"
    grep -F "$archive" "$build_ninja" >/dev/null ||
      die "mpv build does not reference FFmpeg archive: $archive"

    if grep -F "$VCPKG_TARGET_PREFIX/lib/$package.a" "$build_ninja" >/dev/null ||
       grep -F "$VCPKG_TARGET_PREFIX/lib/pkgconfig/../../lib/$package.a" "$build_ninja" >/dev/null; then
      die "mpv build references vcpkg FFmpeg archive for $package"
    fi
  done
}

apply_mpv_patches() {
  local patch

  for patch in "${mpv_patches[@]}"; do
    git apply --check "$patch"
  done

  for patch in "${mpv_patches[@]}"; do
    git apply "$patch"
  done
}

resolve_mpv_iconv_link_flags() {
  local iconv_libs

  if iconv_libs="$(pkg-config --libs --static libiconv 2>/dev/null)" && [[ -n "$iconv_libs" ]]; then
    printf '%s\n' "$iconv_libs"
    return 0
  fi

  if iconv_libs="$(pkg-config --libs --static iconv 2>/dev/null)" && [[ -n "$iconv_libs" ]]; then
    printf '%s\n' "$iconv_libs"
    return 0
  fi

  if [[ -f "$VCPKG_TARGET_PREFIX/lib/libiconv.a" ]]; then
    printf '%s\n' "-L$VCPKG_TARGET_PREFIX/lib -liconv"
  elif [[ -f "$SOURCE_PREFIX/lib/libiconv.a" ]]; then
    printf '%s\n' "-L$SOURCE_PREFIX/lib -liconv"
  else
    printf '%s\n' "-liconv"
  fi
}

cd "$MPV_DIR"
rm -rf build
run_logged "mpv-apply-patches" apply_mpv_patches
create_mpv_ffmpeg_pkg_config_overlay
assert_mpv_ffmpeg_pkg_config_resolves_to_ffmpeg_prefix
ffmpeg_include_flag="-I$FFMPEG_PREFIX/include"
export CFLAGS="$ffmpeg_include_flag $CFLAGS -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3"
export CXXFLAGS="$ffmpeg_include_flag $CXXFLAGS $MPV_FFMPEG_CXX_DISABLE"
export OBJCFLAGS="$ffmpeg_include_flag $OBJCFLAGS"
export OBJCXXFLAGS="$ffmpeg_include_flag $OBJCXXFLAGS $MPV_FFMPEG_CXX_DISABLE"
run_logged "mpv-validate-ffmpeg-headers" assert_mpv_ffmpeg_headers_match_pkg_config
mpv_iconv_link_flags="$(resolve_mpv_iconv_link_flags)"
export LDFLAGS="${LDFLAGS:+$LDFLAGS }$mpv_iconv_link_flags"
export LDFLAGS="$LDFLAGS -Wl,-rpath,$SOURCE_PREFIX/lib/vapoursynth"
echo "mpv iconv link flags: $mpv_iconv_link_flags"

run_logged "mpv-meson-setup" \
  meson setup build \
    -Dlibmpv=true \
    -Dtests=true \
    -Dprefix="${RUNNER_TEMP}/mpv-install" \
    -Dbuildtype=release \
    -Db_lto=true \
    -Dprefer_static=true \
    -Dobjc_args="-Wno-error=deprecated -Wno-error=deprecated-declarations" \
    -Dcaca=enabled \
    -Dcdda=enabled \
    -Dcocoa=enabled \
    -Dcoreaudio=enabled \
    -Ddvdnav=enabled \
    -Dgl=enabled \
    -Dgl-cocoa=enabled \
    -Diconv=enabled \
    -Djavascript=enabled \
    -Djpeg=enabled \
    -Dlcms2=enabled \
    -Dlibarchive=enabled \
    -Dlibavdevice=enabled \
    -Dlibbluray=enabled \
    -Dlua=luajit \
    -Dmacos-cocoa-cb=enabled \
    -Dmacos-media-player=enabled \
    -Dmacos-touchbar=enabled \
    -Dopenal=enabled \
    -Dplain-gl=enabled \
    -Drubberband=enabled \
    -Dsdl2-audio=enabled \
    -Dsdl2-gamepad=enabled \
    -Dsdl2-video=enabled \
    -Dswift-build=enabled \
    -Dswift-flags="${SWIFT_FLAGS:-}" \
    -Duchardet=enabled \
    -Dvapoursynth=enabled \
    -Dvideotoolbox-gl=enabled \
    -Dvideotoolbox-pl=enabled \
    -Dvulkan=enabled \
    -Dzimg=enabled \
    -Dzlib=enabled

assert_mpv_build_uses_ffmpeg_prefix_archives
