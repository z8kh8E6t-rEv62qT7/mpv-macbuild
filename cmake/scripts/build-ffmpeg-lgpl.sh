#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/superbuild-common.sh"

src="$SOURCE_ROOT/ffmpeg-lgpl"

checkout_ffmpeg() {
  if [[ ! -d "$src/.git" ]]; then
    mkdir -p "$src"
    git -C "$src" init
    git -C "$src" remote add origin https://github.com/FFmpeg/FFmpeg.git
  fi
  git -C "$src" fetch --depth 1 origin "$FFMPEG_REF"
  git -C "$src" checkout --detach FETCH_HEAD
}

configure_ffmpeg() {
  local lgpl_ldflags
  local optional=()
  local spec
  local flag
  local module
  local -a candidates=(
    libaom:aom libaribcaption:libaribcaption libcelt:celt libcodec2:codec2
    libdav1d:dav1d libgme:libgme libgsm:gsm libilbc:libilbc liblc3:lc3
    liblcevc-dec:lcevc_dec libmodplug:libmodplug libopenh264:openh264
    libopenmpt:libopenmpt libopus:opus libspeex:speex libsvtjpegxs:SvtJpegxs
    libuavs3d:uavs3d libvorbis:vorbis libvpx:vpx libxevd:xevd libzvbi:zvbi-0.2
  )

  pkg-config --exists libjxl || die "mandatory LGPL dependency libjxl is unavailable"
  pkg-config --exists librsvg-2.0 || die "mandatory LGPL dependency librsvg-2.0 is unavailable"
  for spec in "${candidates[@]}"; do
    flag="${spec%%:*}"
    module="${spec#*:}"
    if pkg-config --exists "$module"; then
      optional+=("--enable-$flag")
    fi
  done

  export PKG_CONFIG_PATH=""
  export PKG_CONFIG_LIBDIR="$SOURCE_PREFIX/lib/pkgconfig:$SOURCE_PREFIX/share/pkgconfig:$VCPKG_TARGET_PREFIX/lib/pkgconfig:$VCPKG_TARGET_PREFIX/share/pkgconfig"
  export LIBRARY_PATH="$SOURCE_PREFIX/lib:$VCPKG_TARGET_PREFIX/lib"
  export CPATH="$SOURCE_PREFIX/include:$VCPKG_TARGET_PREFIX/include"
  lgpl_ldflags="$OPTIMIZATIONS -fuse-ld=$LD64_LLD $LLVM_LINK_BUNDLE $LINK_PATH"
  lgpl_ldflags+=" -L$SOURCE_PREFIX/lib -L$VCPKG_TARGET_PREFIX/lib"
  lgpl_ldflags+=" -Wl,--dead-strip-duplicates -Wl,-headerpad_max_install_names"

  cd "$src"
  ./configure \
    --prefix="$FFMPEG_LGPL_PREFIX" \
    --cc="$CC" --cxx="$CXX" --objcc="$OBJC" --ld="$CC" \
    --ar="$AR" --ranlib="$RANLIB" --strip="$STRIP" \
    --pkg-config=pkg-config --pkg-config-flags=--static \
    --enable-shared --disable-static --install-name-dir=@rpath \
    --disable-autodetect --disable-debug --enable-stripping --enable-pic \
    --enable-pthreads --enable-asm --enable-hardcoded-tables \
    --enable-bzlib --enable-iconv --enable-lzma --enable-zlib \
    --enable-audiotoolbox --enable-videotoolbox \
    --enable-libjxl --enable-librsvg "${optional[@]}" \
    --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages \
    --extra-cflags="$CFLAGS" \
    --extra-cxxflags="$CXXFLAGS $MPV_FFMPEG_CXX_DISABLE" \
    --extra-objcflags="$OBJCFLAGS" \
    --extra-ldflags="$lgpl_ldflags" \
    --extra-libs="-lc++ -framework AudioToolbox -framework CoreAudio -framework CoreFoundation -framework CoreMedia -framework CoreVideo -framework Security -framework VideoToolbox"
}

validate_profile() {
  local config="$src/config.h"
  grep -Fx '#define CONFIG_GPL 0' "$config" >/dev/null
  grep -Fx '#define CONFIG_VERSION3 0' "$config" >/dev/null
  grep -Fx '#define CONFIG_NONFREE 0' "$config" >/dev/null
  "$FFMPEG_LGPL_PREFIX/bin/ffmpeg" -hide_banner -buildconf
}

run_logged "ffmpeg-lgpl-checkout" checkout_ffmpeg
run_logged "ffmpeg-lgpl-configure" configure_ffmpeg
run_logged "ffmpeg-lgpl-build" make -C "$src" -j"$(ci_jobs)"
run_logged "ffmpeg-lgpl-install" make -C "$src" install
run_logged "ffmpeg-lgpl-validate-profile" validate_profile
