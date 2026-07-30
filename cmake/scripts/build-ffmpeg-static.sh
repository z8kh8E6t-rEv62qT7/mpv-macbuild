#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/superbuild-common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ffmpeg-common.sh"

require_var FFMPEG_REF

ffmpeg_patches=(
  "$BUILDER_DIR/patch/ffmpeg-0001-avformat-some-subtitle-optimizations.patch"
  "$BUILDER_DIR/patch/ffmpeg-0003-fftools-rename-dec-init.patch"
  "$BUILDER_DIR/patch/ffmpeg-0004-avcodec-apv-parser-rename-close-callback.patch"
)

checkout_ffmpeg() {
  mkdir -p "$SOURCE_ROOT/ffmpeg"
  if [[ ! -d "$SOURCE_ROOT/ffmpeg/.git" ]]; then
    git -C "$SOURCE_ROOT/ffmpeg" init
    git -C "$SOURCE_ROOT/ffmpeg" remote add origin https://github.com/FFmpeg/FFmpeg.git
  fi
  git -C "$SOURCE_ROOT/ffmpeg" fetch --depth 1 origin "$FFMPEG_REF"
  git -C "$SOURCE_ROOT/ffmpeg" checkout --detach FETCH_HEAD
  git -C "$SOURCE_ROOT/ffmpeg" rev-parse HEAD
}

apply_ffmpeg_patches() {
  local patch
  for patch in "${ffmpeg_patches[@]}"; do
    git -C "$SOURCE_ROOT/ffmpeg" apply --check "$patch"
  done
  for patch in "${ffmpeg_patches[@]}"; do
    git -C "$SOURCE_ROOT/ffmpeg" apply "$patch"
  done
}

configure_ffmpeg() {
  local ffmpeg_ldflags="$LDFLAGS -Wl,--dead-strip-duplicates -Wl,-headerpad_max_install_names"

  cd "$SOURCE_ROOT/ffmpeg"
  ./configure \
    --prefix="$FFMPEG_PREFIX" \
    --cc="$CC" \
    --cxx="$CXX" \
    --objcc="$OBJC" \
    --ld="$CC" \
    --ar="$AR" \
    --ranlib="$RANLIB" \
    --strip="$STRIP" \
    --pkg-config=pkg-config \
    --pkg-config-flags=--static \
    --glslc="$VCPKG_TARGET_PREFIX/tools/shaderc/glslc" \
    --enable-pic \
    --enable-hardcoded-tables \
    --disable-debug \
    --enable-stripping \
    --enable-shared \
    --enable-static \
    --install-name-dir=@rpath \
    --enable-pthreads \
    --disable-os2threads \
    --disable-w32threads \
    --enable-asm \
    --enable-bzlib \
    --enable-gpl \
    --enable-lzma \
    --enable-nonfree \
    --enable-version3 \
    --enable-zlib \
    --enable-gray \
    --enable-runtime-cpudetect \
    --enable-iconv \
    --enable-vapoursynth \
    --enable-libass \
    --enable-libbluray \
    --enable-libcaca \
    --enable-libcdio \
    --enable-chromaprint \
    --enable-libdvdnav \
    --enable-libdvdread \
    --enable-libfreetype \
    --enable-libfribidi \
    --enable-libfontconfig \
    --enable-libharfbuzz \
    --enable-libmodplug \
    --enable-libopenmpt \
    --enable-libopenjpeg \
    --enable-libopenh264 \
    --enable-libfdk-aac \
    --enable-libmp3lame \
    --enable-libkvazaar \
    --enable-lcms2 \
    --enable-libopus \
    --enable-libsoxr \
    --enable-libspeex \
    --enable-libsnappy \
    --enable-librtmp \
    --enable-libtheora \
    --enable-libvorbis \
    --enable-libvmaf \
    --enable-libbs2b \
    --enable-librubberband \
    --enable-libvpx \
    --enable-libwebp \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libaom \
    --enable-libsvtav1 \
    --enable-libdav1d \
    --enable-librav1e \
    --enable-libdavs2 \
    --enable-libuavs3d \
    --enable-libxvid \
    --enable-libzimg \
    --enable-openssl \
    --enable-libxml2 \
    --enable-libmysofa \
    --enable-libssh \
    --enable-libsrt \
    --enable-libjxl \
    --enable-libplacebo \
    --enable-librsvg \
    --enable-libshaderc \
    --enable-libzvbi \
    --enable-libaribcaption \
    --enable-libvvenc \
    --enable-libgme \
    --enable-frei0r \
    --enable-libvidstab \
    --enable-openal \
    --enable-opencl \
    --enable-opengl \
    --enable-sdl2 \
    --enable-vulkan \
    --enable-demuxer=dash \
    --enable-macos-kperf \
    --enable-videotoolbox \
    --enable-audiotoolbox \
    --enable-lto \
    --disable-doc \
    --disable-htmlpages \
    --disable-manpages \
    --disable-podpages \
    --disable-txtpages \
    --extra-cflags="$CFLAGS" \
    --extra-cxxflags="$CXXFLAGS $MPV_FFMPEG_CXX_DISABLE" \
    --extra-objcflags="$OBJCFLAGS" \
    --extra-ldflags="$ffmpeg_ldflags" \
    --extra-libs="-lc++ -framework AudioToolbox -framework CoreAudio -framework CoreFoundation -framework CoreMedia -framework CoreServices -framework CoreVideo -framework OpenCL -framework QuartzCore -framework Security -framework VideoToolbox"
}

build_ffmpeg() {
  make -C "$SOURCE_ROOT/ffmpeg" -j"$(ci_jobs)"
}

install_ffmpeg() {
  make -C "$SOURCE_ROOT/ffmpeg" install
}

print_ffmpeg_buildconf() {
  "$FFMPEG_PREFIX/bin/ffmpeg" -hide_banner -buildconf
}

ensure_vulkan_loader_links() {
  local lib_dir="$1"
  local versioned_loader

  if [[ ! -e "$lib_dir/libvulkan.1.dylib" ]]; then
    versioned_loader="$(find "$lib_dir" -maxdepth 1 -type f -name 'libvulkan.*.dylib' ! -name 'libvulkan.1.dylib' | sort | head -n1 || true)"
    if [[ -n "$versioned_loader" ]]; then
      ln -sf "$(basename "$versioned_loader")" "$lib_dir/libvulkan.1.dylib"
    fi
  fi

  if [[ -e "$lib_dir/libvulkan.1.dylib" ]]; then
    ln -sf libvulkan.1.dylib "$lib_dir/libvulkan.dylib"
  fi
}

bundle_vulkan_runtime_into_ffmpeg_prefix() {
  local ffmpeg_lib_dir="$FFMPEG_PREFIX/lib"
  local ffmpeg_share_dir="$FFMPEG_PREFIX/share/vulkan"
  local moltenvk_library
  local moltenvk_basename="libMoltenVK.dylib"

  mkdir -p "$ffmpeg_lib_dir" "$ffmpeg_share_dir/icd.d" "$ffmpeg_share_dir/explicit_layer.d"

  while IFS= read -r dylib; do
    cp "$dylib" "$ffmpeg_lib_dir/$(basename "$dylib")"
    chmod u+w "$ffmpeg_lib_dir/$(basename "$dylib")"
  done < <(find "$SOURCE_PREFIX/lib" -maxdepth 1 -type f \( -name 'libvulkan*.dylib' -o -name 'libMoltenVK*.dylib' \) | sort)

  ensure_vulkan_loader_links "$ffmpeg_lib_dir"

  moltenvk_library="$(find "$ffmpeg_lib_dir" -maxdepth 1 -type f -name 'libMoltenVK*.dylib' | head -n1 || true)"
  if [[ -n "$moltenvk_library" ]]; then
    moltenvk_basename="$(basename "$moltenvk_library")"
  fi

  while IFS= read -r json_file; do
    cp "$json_file" "$ffmpeg_share_dir/icd.d/$(basename "$json_file")"
  done < <(find "$SOURCE_PREFIX/share/vulkan/icd.d" -type f -name '*.json' 2>/dev/null | sort)

  while IFS= read -r json_file; do
    cp "$json_file" "$ffmpeg_share_dir/explicit_layer.d/$(basename "$json_file")"
  done < <(find "$SOURCE_PREFIX/share/vulkan/explicit_layer.d" -type f -name '*.json' 2>/dev/null | sort)

  python3 - "$ffmpeg_share_dir" "$moltenvk_basename" <<'PY'
import json
import pathlib
import sys

share_dir = pathlib.Path(sys.argv[1])
moltenvk_basename = sys.argv[2]
for json_path in share_dir.rglob("*.json"):
    try:
        data = json.loads(json_path.read_text())
    except json.JSONDecodeError:
        continue
    if data.get("ICD", {}).get("library_path"):
        data["ICD"]["library_path"] = f"../../../lib/{moltenvk_basename}"
    if data.get("layer", {}).get("library_path"):
        data["layer"]["library_path"] = f"../../../lib/{moltenvk_basename}"
    json_path.write_text(json.dumps(data, indent=2) + "\n")
PY

  while IFS= read -r dylib; do
    install_name_tool -id "@rpath/$(basename "$dylib")" "$dylib"
  done < <(find "$ffmpeg_lib_dir" -maxdepth 1 -type f \( -name 'libvulkan*.dylib' -o -name 'libMoltenVK*.dylib' \) | sort)

  while IFS= read -r target; do
    while IFS= read -r oldref; do
      basename="$(basename "$oldref")"
      install_name_tool -change "$oldref" "@executable_path/../lib/$basename" "$target"
    done < <(otool -L "$target" | awk '/libvulkan.*[.]dylib|libMoltenVK.*[.]dylib/ {print $1}')
  done < <(find "$FFMPEG_PREFIX/bin" -maxdepth 1 -type f \( -name 'ffmpeg' -o -name 'ffprobe' -o -name 'ffplay' \) | sort)

  while IFS= read -r dylib; do
    while IFS= read -r oldref; do
      basename="$(basename "$oldref")"
      install_name_tool -change "$oldref" "@loader_path/$basename" "$dylib"
    done < <(otool -L "$dylib" | awk '/libvulkan.*[.]dylib|libMoltenVK.*[.]dylib/ {print $1}')
  done < <(find "$ffmpeg_lib_dir" -maxdepth 1 -type f \( -name 'libvulkan*.dylib' -o -name 'libMoltenVK*.dylib' \) | sort)
}

bundle_vapoursynth_runtime_into_ffmpeg_prefix() {
  local source_runtime_dir="$SOURCE_PREFIX/lib/vapoursynth"
  local ffmpeg_runtime_dir="$FFMPEG_PREFIX/lib/vapoursynth"
  local target

  [[ -d "$source_runtime_dir" ]] || die "missing VapourSynth runtime dir: $source_runtime_dir"
  rm -rf "$ffmpeg_runtime_dir"
  mkdir -p "$ffmpeg_runtime_dir"
  cp -R "$source_runtime_dir"/. "$ffmpeg_runtime_dir"/
  normalize_vapoursynth_runtime_dir "$ffmpeg_runtime_dir"

  while IFS= read -r target; do
    rewrite_vapoursynth_ref "$target" "@rpath/libvsscript.dylib"
    add_rpath_if_missing "$target" "@executable_path/../lib/vapoursynth"
  done < <(find "$FFMPEG_PREFIX/bin" -maxdepth 1 -type f \( -name 'ffmpeg' -o -name 'ffprobe' -o -name 'ffplay' \) | sort)
}

normalize_ffmpeg_prefix_runtime_refs() {
  local target

  while IFS= read -r target; do
    is_mach_o "$target" || continue
    normalize_llvm_runtime_refs "$target"
  done < <(find "$FFMPEG_PREFIX/bin" "$FFMPEG_PREFIX/lib" -type f \( -perm -111 -o -name '*.dylib' -o -name '*.so' -o -name '*.bundle' \) 2>/dev/null | sort)

  assert_no_system_cxx_runtime_refs \
    "FFmpeg install prefix" \
    "$FFMPEG_PREFIX/bin/ffmpeg" \
    "$FFMPEG_PREFIX/bin/ffprobe" \
    "$FFMPEG_PREFIX/bin/ffplay"
}

run_logged "ffmpeg-checkout" checkout_ffmpeg
run_logged "ffmpeg-apply-patches" apply_ffmpeg_patches
run_logged "ffmpeg-fix-configure-probes" fix_ffmpeg_configure_probes "$SOURCE_ROOT/ffmpeg/configure"
run_logged "ffmpeg-configure" configure_ffmpeg
run_logged "ffmpeg-build" build_ffmpeg
run_logged "ffmpeg-install" install_ffmpeg
run_logged "ffmpeg-bundle-vapoursynth-runtime" bundle_vapoursynth_runtime_into_ffmpeg_prefix
run_logged "ffmpeg-bundle-vulkan-runtime" bundle_vulkan_runtime_into_ffmpeg_prefix
run_logged "ffmpeg-normalize-runtime-refs" normalize_ffmpeg_prefix_runtime_refs
run_logged "ffmpeg-buildconf" print_ffmpeg_buildconf
