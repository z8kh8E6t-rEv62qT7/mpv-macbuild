#!/usr/bin/env bash

normalize_vapoursynth_install() {
  local runtime_dir="$SOURCE_PREFIX/lib/vapoursynth"
  local include_dir="$SOURCE_PREFIX/include/vapoursynth"
  local installed_pc
  local installed_pkgconfig_dir
  local installed_runtime_dir
  local source_include_dir
  local pc_dir="$SOURCE_PREFIX/lib/pkgconfig"
  local vapoursynth_version
  local header
  local library

  installed_pc="$(find "$SOURCE_PREFIX" -type f -path '*/vapoursynth/pkgconfig/vapoursynth.pc' -print -quit)"
  if [[ -z "$installed_pc" ]]; then
    installed_pc="$(find "$SOURCE_PREFIX" -type f -name vapoursynth.pc -print -quit)"
  fi
  [[ -n "$installed_pc" ]] || die "vapoursynth.pc was not installed"

  installed_pkgconfig_dir="$(dirname "$installed_pc")"
  installed_runtime_dir=
  if [[ "$installed_pkgconfig_dir" == */vapoursynth/pkgconfig ]]; then
    installed_runtime_dir="$(dirname "$installed_pkgconfig_dir")"
  fi
  [[ -n "$installed_runtime_dir" ]] || die "could not derive VapourSynth runtime dir from $installed_pc"
  source_include_dir="$installed_runtime_dir/include"
  [[ -d "$source_include_dir" ]] || die "VapourSynth include dir was not installed: $source_include_dir"

  mkdir -p "$runtime_dir" "$include_dir" "$pc_dir"
  if [[ -n "$installed_runtime_dir" && "$installed_runtime_dir" != "$runtime_dir" ]]; then
    cp -R "$installed_runtime_dir"/. "$runtime_dir"/
  fi

  for header in VapourSynth4.h VSScript4.h VSConstants4.h VSHelper4.h; do
    [[ -f "$source_include_dir/$header" ]] || die "VapourSynth header was not installed: $source_include_dir/$header"
    cp "$source_include_dir/$header" "$include_dir/$header"
    cp "$source_include_dir/$header" "$SOURCE_PREFIX/include/$header"
  done

  for library in libvapoursynth.dylib libvsscript.dylib; do
    [[ -e "$runtime_dir/$library" ]] || die "VapourSynth runtime library was not installed: $runtime_dir/$library"
  done
  normalize_vapoursynth_runtime_dir "$runtime_dir"

  vapoursynth_version="$(awk -F: '/^Version:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' "$installed_pc")"
  vapoursynth_version="${vapoursynth_version:-0}"
  cat > "$pc_dir/vapoursynth.pc" <<EOF
prefix=$SOURCE_PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib/vapoursynth
includedir=\${prefix}/include

Name: vapoursynth
Description: A frameserver for the 21st century
Version: $vapoursynth_version
Cflags: -I\${includedir}
EOF

  cat > "$pc_dir/vapoursynth-script.pc" <<EOF
prefix=$SOURCE_PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib/vapoursynth
includedir=\${prefix}/include

Name: vapoursynth-script
Description: VapourSynth scripting API
Version: $vapoursynth_version
Requires: vapoursynth
Libs: -L\${libdir} -lvsscript
Cflags: -I\${includedir}
EOF
}

prepare_vapoursynth_subprojects() {
  local source_dir="$SOURCE_ROOT/vapoursynth"
  local glslang_dir="$source_dir/subprojects/glslang"

  # VapourSynth embeds glslang through subproject('glslang'), so the vcpkg
  # glslang installation is not sufficient. Fetch the revision pinned by the
  # repository's glslang.wrap before configuration disables wrap downloads.
  [[ -f "$source_dir/subprojects/glslang.wrap" ]] || die "VapourSynth glslang.wrap is missing"
  meson subprojects download --sourcedir "$source_dir" glslang
  [[ -f "$glslang_dir/meson.build" ]] || die "VapourSynth glslang subproject is incomplete: $glslang_dir"
}

build_vapoursynth() {
  local vapoursynth_api_flags
  local vapoursynth_release

  clone_or_update https://github.com/vapoursynth/vapoursynth.git "$SOURCE_ROOT/vapoursynth"
  prepare_vapoursynth_subprojects
  vapoursynth_release="$(awk '/VS_CURRENT_RELEASE/ {print $3; exit}' "$SOURCE_ROOT/vapoursynth/VAPOURSYNTH_VERSION")"
  vapoursynth_release="${vapoursynth_release:-77}"
  vapoursynth_api_flags="-DVS_CURRENT_RELEASE=$vapoursynth_release -DVS_GRAPH_API -DVS_USE_LATEST_API -DVSSCRIPT_USE_LATEST_API"

  CFLAGS="$CFLAGS $vapoursynth_api_flags" \
  CXXFLAGS="$CXXFLAGS $vapoursynth_api_flags" \
    meson setup "$BUILD_ROOT/vapoursynth" "$SOURCE_ROOT/vapoursynth" \
    --prefix="$SOURCE_PREFIX" \
    --buildtype=release \
    --wrap-mode=nodownload
  meson compile -C "$BUILD_ROOT/vapoursynth"
  meson install -C "$BUILD_ROOT/vapoursynth"
  normalize_vapoursynth_install
  pkg-config --exists vapoursynth
  pkg-config --exists vapoursynth-script
}
