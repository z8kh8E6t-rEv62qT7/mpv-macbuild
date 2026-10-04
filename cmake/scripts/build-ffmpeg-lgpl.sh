#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/superbuild-common.sh"
init_superbuild_environment
require_var FFMPEG_REF

src="$SOURCE_ROOT/ffmpeg-lgpl"
# Keep generated objects separate from the checkout and discard old profile output.
lgpl_build="$BUILD_ROOT/ffmpeg-lgpl"
decoders=apng,bmp,exr,gif,hevc,libdav1d,mjpeg,png,tiff,webp,webp_anim
parsers=av1,bmp,gif,hevc,mjpeg,png,webp
demuxers=apng,gif,image2,image2pipe,image_bmp_pipe,image_exr_pipe,image_jpeg_pipe,image_png_pipe,image_tiff_pipe,image_webp_pipe,mov,webp_anim

checkout_ffmpeg() {
  if [[ ! -d "$src/.git" ]]; then
    mkdir -p "$src"
    git -C "$src" init
    git -C "$src" remote add origin https://github.com/FFmpeg/FFmpeg.git
  fi
  git -C "$src" fetch --depth 1 origin "$FFMPEG_REF"
  # This checkout belongs exclusively to this build, including old configure edits.
  git -C "$src" checkout --force --detach FETCH_HEAD
  git -C "$src" clean -ffdqx
  git -C "$src" rev-parse HEAD
}

configure_lgpl_environment() {
  export PKG_CONFIG_PATH=""
  export PKG_CONFIG_LIBDIR="$VCPKG_TARGET_PREFIX/lib/pkgconfig:$VCPKG_TARGET_PREFIX/share/pkgconfig"
  export CMAKE_PREFIX_PATH="$VCPKG_TARGET_PREFIX"
  export LIBRARY_PATH="$VCPKG_TARGET_PREFIX/lib"
  export CPATH="$VCPKG_TARGET_PREFIX/include"
  export CPPFLAGS="-I$VCPKG_TARGET_PREFIX/include"
  export CFLAGS="$OPTIMIZATIONS $LLVM_C_BUNDLE -I$VCPKG_TARGET_PREFIX/include"
  export CXXFLAGS="$CFLAGS" OBJCFLAGS="$CFLAGS"
  export LDFLAGS="$OPTIMIZATIONS -fuse-ld=$LD64_LLD $LLVM_LINK_BUNDLE $LINK_PATH -L$VCPKG_TARGET_PREFIX/lib -Wl,--dead-strip-duplicates -Wl,-headerpad_max_install_names"
  unset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH
}

configure_ffmpeg() {
  local dependency library
  for dependency in zlib dav1d liblzma; do
    pkg-config --exists "$dependency" || die "mandatory LGPL dependency $dependency is unavailable"
  done
  for library in z dav1d lzma; do
    [[ -f "$VCPKG_TARGET_PREFIX/lib/lib$library.a" ]] || die "missing static dependency: lib$library.a"
    if find "$VCPKG_TARGET_PREFIX/lib" -maxdepth 1 -name "lib$library*.dylib" -print -quit | grep -q .; then
      die "LGPL dependency prefix must be static-only: lib$library"
    fi
  done

  python3 - "$FFMPEG_LGPL_PREFIX" "$lgpl_build" "$BUILDER_DIR" "$SOURCE_ROOT" "$SOURCE_PREFIX" "$VCPKG_TARGET_PREFIX" "$FFMPEG_PREFIX" <<'PY_CHECK'
import pathlib
import sys
outputs = [pathlib.Path(value).resolve() for value in sys.argv[1:3]]
protected = [pathlib.Path(value).resolve() for value in sys.argv[3:]]
for output in outputs:
    for path in protected:
        if path.is_relative_to(output):
            raise SystemExit(f"refusing to remove LGPL output {output}: contains protected path {path}")
if outputs[0].is_relative_to(outputs[1]) or outputs[1].is_relative_to(outputs[0]):
    raise SystemExit("LGPL build and installation directories must not overlap")
PY_CHECK
  rm -rf "$lgpl_build" "$FFMPEG_LGPL_PREFIX"
  mkdir -p "$lgpl_build" "$FFMPEG_LGPL_PREFIX"
  cd "$lgpl_build"
  "$src/configure" \
    --prefix="$FFMPEG_LGPL_PREFIX" \
    --cc="$CC" --cxx="$CXX" --objcc="$OBJC" --ld="$CC" \
    --ar="$AR" --ranlib="$RANLIB" --strip="$STRIP" \
    --pkg-config=pkg-config --pkg-config-flags=--static \
    --disable-everything --disable-autodetect \
    --disable-gpl --disable-version3 --disable-nonfree \
    --enable-shared --disable-static --install-name-dir=@rpath \
    --enable-ffmpeg --disable-ffplay --disable-ffprobe \
    --enable-avcodec --enable-avformat --enable-avutil --enable-swscale --enable-avfilter \
    --disable-avdevice --disable-swresample --disable-network --disable-hwaccels \
    --disable-audiotoolbox --disable-videotoolbox --disable-securetransport \
    --disable-debug --enable-stripping --enable-pic \
    --enable-pthreads --enable-asm --enable-hardcoded-tables \
    --enable-zlib --enable-lzma --enable-libdav1d \
    --enable-decoder="$decoders" --enable-parser="$parsers" --enable-demuxer="$demuxers" \
    --enable-filter=scale --enable-encoder=rawvideo --enable-muxer=rawvideo --enable-protocol=file \
    --disable-doc \
    --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS"
}

validate_configuration() {
  python3 "$BUILDER_DIR/scripts/audit/audit-lgpl-config.py" "$lgpl_build" \
    "$decoders" "$parsers" "$demuxers"
}

validate_install() {
  [[ -x "$FFMPEG_LGPL_PREFIX/bin/ffmpeg" ]] || die "LGPL FFmpeg executable is missing"
  env DYLD_LIBRARY_PATH="$FFMPEG_LGPL_PREFIX/lib" "$FFMPEG_LGPL_PREFIX/bin/ffmpeg" -hide_banner -buildconf
}

configure_lgpl_environment

run_logged "ffmpeg-lgpl-checkout" checkout_ffmpeg
run_logged "ffmpeg-lgpl-configure" configure_ffmpeg
run_logged "ffmpeg-lgpl-validate-config" validate_configuration
run_logged "ffmpeg-lgpl-build" make -C "$lgpl_build" -j"$(ci_jobs)"
run_logged "ffmpeg-lgpl-install" make -C "$lgpl_build" install
run_logged "ffmpeg-lgpl-validate-profile" validate_install
