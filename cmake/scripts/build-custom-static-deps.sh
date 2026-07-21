#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/superbuild-common.sh"

VULKAN_SDK_TAG="vulkan-sdk-1.4.350.0"
VULKAN_SDK_VERSION="${VULKAN_SDK_TAG#vulkan-sdk-}"
VULKAN_SDK_VERSION="${VULKAN_SDK_VERSION%.0}"

strip_lto_flags() {
  local flag
  local -a kept=()

  for flag in "$@"; do
    case "$flag" in
      -flto|-flto=*) ;;
      *) kept+=("$flag") ;;
    esac
  done

  printf '%s' "${kept[*]}"
}

assert_luajit_protected_require_works() {
  luajit -e '
local ok, err = pcall(error, "plain-error")
assert(ok == false and err == "plain-error")

local loaded, require_err = pcall(require, "definitely-missing-mpv-macbuild-smoke-module")
assert(loaded == false, "missing module unexpectedly loaded")
assert(type(require_err) == "string", "missing module error is not a string")
assert(require_err:match("module .- not found"), require_err)
'
}

build_luajit() {
  # LuaJIT's VM/error unwinding is not safe under the global ThinLTO flags:
  # pcall(require, "missing") can bypass the protected frame and panic.
  local luajit_cflags
  local luajit_ldflags
  local -a luajit_make_args

  luajit_cflags="$(strip_lto_flags $CFLAGS)"
  luajit_ldflags="$(strip_lto_flags $LDFLAGS)"
  luajit_make_args=(
    PREFIX="$SOURCE_PREFIX"
    CC="$CC"
    CFLAGS="$luajit_cflags"
    LDFLAGS="$luajit_ldflags"
    TARGET_AR="$AR rcus"
    # LuaSocket modules use Darwin dynamic_lookup; keep Lua C API globals
    # exported from the luajit host used for runtime validation.
    TARGET_LDFLAGS="-Wl,-export_dynamic"
    TARGET_STRIP="$STRIP"
    STATIC_CC="$CC"
    DYNAMIC_CC="$CC -fPIC"
  )

  clone_or_update https://github.com/LuaJIT/LuaJIT.git "$SOURCE_ROOT/luajit"
  make -C "$SOURCE_ROOT/luajit" clean
  make -C "$SOURCE_ROOT/luajit" -j"$(ci_jobs)" amalg \
    "${luajit_make_args[@]}"
  make -C "$SOURCE_ROOT/luajit" install \
    "${luajit_make_args[@]}"
  remove_dynamic_artifacts
  pkg-config --exists luajit
  assert_luajit_protected_require_works
}

build_luasocket() {
  echo "Installing LuaSocket from source with LuaRocks variables: CC=$CC LD=$CC CFLAGS=$CFLAGS LDFLAGS=$LDFLAGS"
  luarocks --tree "$SOURCE_PREFIX/luarocks" --lua-version=5.1 --lua-dir="$SOURCE_PREFIX" install luasocket \
    CC="$CC" \
    LD="$CC" \
    CFLAGS="$CFLAGS -I$SOURCE_PREFIX/include/luajit-2.1" \
    LDFLAGS="$LDFLAGS"
  eval "$(luarocks --tree "$SOURCE_PREFIX/luarocks" --lua-version=5.1 path --bin)"
  luajit -e 'require("socket")'
}

build_libdovi() {
  clone_or_update https://github.com/quietvoid/dovi_tool.git "$SOURCE_ROOT/dovi_tool"
  cargo cinstall \
    --manifest-path "$SOURCE_ROOT/dovi_tool/dolby_vision/Cargo.toml" \
    --release \
    --prefix "$SOURCE_PREFIX"
  remove_dynamic_artifacts
  pkg-config --exists dovi
}

find_llvm_objcopy() {
  local candidate
  local -a candidates=()

  if [[ -n "${LLVM_PREFIX:-}" ]]; then
    candidates+=("$LLVM_PREFIX/bin/llvm-objcopy")
  fi
  if [[ -n "${OBJCOPY:-}" ]]; then
    candidates+=("$OBJCOPY")
  fi
  if candidate="$(command -v llvm-objcopy 2>/dev/null)"; then
    candidates+=("$candidate")
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  die "llvm-objcopy was not found"
}

write_defined_global_symbols() {
  local archive="$1"
  local output="$2"

  [[ -f "$archive" ]] || die "missing static archive: $archive"
  "$NM" -gU "$archive" 2>/dev/null |
    awk 'NF >= 3 && $2 ~ /^[A-Z]$/ && $2 !~ /^[UVW]$/ { print $3 }' |
    sort -u > "$output"
}

weaken_symbols_in_archive() {
  local archive="$1"
  local symbols_file="$2"
  local objcopy="$3"
  local tmp_archive="${archive}.weak.tmp"

  rm -f "$tmp_archive"
  "$objcopy" --weaken-symbols="$symbols_file" "$archive" "$tmp_archive"
  mv "$tmp_archive" "$archive"
  "$RANLIB" "$archive"
}

# Rust staticlibs embed Rust runtime objects. Keep each package's C API
# exported, but make shared Rust internals weak before FFmpeg links them.
normalize_rust_staticlibs() {
  local work_dir="$BUILD_ROOT/rust-staticlib-symbols"
  local overlap_symbols="$work_dir/overlap-symbols.txt"
  local report="$AUDIT_DIR/rust-staticlib-symbols.txt"
  local objcopy
  local overlap_count
  local index
  local archive_name
  local archive_path
  local symbols_file
  local weaken_file
  local weaken_count
  local -a archive_names=(libdovi librav1e librsvg-2)
  local -a archive_paths=(
    "$SOURCE_PREFIX/lib/libdovi.a"
    "$SOURCE_PREFIX/lib/librav1e.a"
    "$VCPKG_TARGET_PREFIX/lib/librsvg-2.a"
  )
  local -a symbol_files=()
  local -a weaken_files=()
  local -a weaken_counts=()

  mkdir -p "$work_dir" "$AUDIT_DIR"
  objcopy="$(find_llvm_objcopy)"

  for index in "${!archive_names[@]}"; do
    archive_name="${archive_names[$index]}"
    archive_path="${archive_paths[$index]}"
    symbols_file="$work_dir/$archive_name.global-symbols.txt"
    weaken_file="$work_dir/$archive_name.weaken-symbols.txt"
    write_defined_global_symbols "$archive_path" "$symbols_file"
    symbol_files+=("$symbols_file")
    weaken_files+=("$weaken_file")
  done

  sort "${symbol_files[@]}" | uniq -d > "$overlap_symbols"
  overlap_count="$(wc -l < "$overlap_symbols" | tr -d '[:space:]')"

  for index in "${!archive_names[@]}"; do
    comm -12 "${symbol_files[$index]}" "$overlap_symbols" > "${weaken_files[$index]}"
    weaken_count="$(wc -l < "${weaken_files[$index]}" | tr -d '[:space:]')"
    weaken_counts+=("$weaken_count")
  done

  {
    printf 'Rust staticlib overlap normalization\n'
    for index in "${!archive_names[@]}"; do
      printf '%s archive: %s\n' "${archive_names[$index]}" "${archive_paths[$index]}"
      printf '%s weakened symbol count: %s\n' "${archive_names[$index]}" "${weaken_counts[$index]}"
    done
    printf 'llvm-objcopy: %s\n' "$objcopy"
    printf 'overlap symbol count: %s\n' "$overlap_count"
    printf '\n'
    cat "$overlap_symbols"
  } > "$report"

  if [[ "$overlap_count" -eq 0 ]]; then
    echo "No overlapping Rust staticlib symbols found"
    return 0
  fi

  if grep -E '^_(dovi|rav1e|rsvg)_' "$overlap_symbols" >/dev/null; then
    die "public C API symbols unexpectedly overlap between Rust static libraries"
  fi

  for index in "${!archive_names[@]}"; do
    if [[ "${weaken_counts[$index]}" -gt 0 ]]; then
      weaken_symbols_in_archive "${archive_paths[$index]}" "${weaken_files[$index]}" "$objcopy"
    fi
  done

  echo "Weakened $overlap_count overlapping Rust staticlib symbols across libdovi.a, librav1e.a, and librsvg-2.a"
  echo "Report: $report"
}

ensure_vulkan_pc() {
  local pc_file="$SOURCE_PREFIX/lib/pkgconfig/vulkan.pc"

  if pkg-config --exists vulkan; then
    return 0
  fi

  cat > "$pc_file" <<EOF
prefix=$SOURCE_PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: Vulkan Loader
Description: Source-built Vulkan loader for macOS CI
Version: $VULKAN_SDK_VERSION
Libs: -L\${libdir} -lvulkan
Cflags: -I\${includedir}
EOF
}

build_vulkan_headers() {
  clone_or_update https://github.com/KhronosGroup/Vulkan-Headers.git "$SOURCE_ROOT/Vulkan-Headers" "$VULKAN_SDK_TAG"
  cmake_static_install "$SOURCE_ROOT/Vulkan-Headers" "$BUILD_ROOT/Vulkan-Headers" \
    -DVULKAN_HEADERS_ENABLE_TESTS=OFF \
    -DVULKAN_HEADERS_ENABLE_MODULE=OFF
  [[ -f "$SOURCE_PREFIX/share/cmake/VulkanHeaders/VulkanHeadersConfig.cmake" ]] || die "VulkanHeadersConfig.cmake was not installed"
  [[ -f "$SOURCE_PREFIX/share/vulkan/registry/vk.xml" ]] || die "vk.xml was not installed"
}

build_vulkan_loader() {
  local loader_ldflags
  local python_executable
  local vulkan_headers_config_dir
  clone_or_update https://github.com/KhronosGroup/Vulkan-Loader.git "$SOURCE_ROOT/Vulkan-Loader" "$VULKAN_SDK_TAG"
  python_executable="${PYTHON_VENV:+$PYTHON_VENV/bin/python3}"
  python_executable="${python_executable:-$(command -v python3)}"
  loader_ldflags="${LDFLAGS//-lvulkan/}"
  vulkan_headers_config_dir="$SOURCE_PREFIX/share/cmake/VulkanHeaders"

  cmake -S "$SOURCE_ROOT/Vulkan-Loader" -B "$BUILD_ROOT/Vulkan-Loader" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$SOURCE_PREFIX" \
    -DCMAKE_PREFIX_PATH="$CMAKE_PREFIX_PATH" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_AR="$AR" \
    -DCMAKE_RANLIB="$RANLIB" \
    -DCMAKE_NM="$NM" \
    -DCMAKE_STRIP="$STRIP" \
    -DCMAKE_C_FLAGS="$CFLAGS" \
    -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$loader_ldflags" \
    -DCMAKE_SHARED_LINKER_FLAGS="$loader_ldflags" \
    -DCMAKE_MODULE_LINKER_FLAGS="$loader_ldflags" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_TESTS=OFF \
    -DBUILD_WSI_XCB_SUPPORT=OFF \
    -DBUILD_WSI_XLIB_SUPPORT=OFF \
    -DBUILD_WSI_WAYLAND_SUPPORT=OFF \
    -DBUILD_WSI_DIRECTFB_SUPPORT=OFF \
    -DUSE_GAS=OFF \
    -DVulkanHeaders_DIR="$vulkan_headers_config_dir" \
    -DVULKAN_HEADERS_INSTALL_DIR="$SOURCE_PREFIX" \
    -DVulkanRegistry_DIR="$SOURCE_PREFIX/share/vulkan/registry" \
    -DPython3_EXECUTABLE="$python_executable"
  cmake --build "$BUILD_ROOT/Vulkan-Loader"
  cmake --install "$BUILD_ROOT/Vulkan-Loader"

  if [[ -f "$SOURCE_PREFIX/lib/libvulkan.1.dylib" && ! -e "$SOURCE_PREFIX/lib/libvulkan.dylib" ]]; then
    ln -sf libvulkan.1.dylib "$SOURCE_PREFIX/lib/libvulkan.dylib"
  fi

  ensure_vulkan_pc
  pkg-config --exists vulkan
}

build_libplacebo() {
  clone_or_update https://github.com/haasn/libplacebo.git "$SOURCE_ROOT/libplacebo"
  git -C "$SOURCE_ROOT/libplacebo" submodule update --init --recursive
  meson_static_install "$SOURCE_ROOT/libplacebo" "$BUILD_ROOT/libplacebo" \
    -Ddemos=false \
    -Dtests=false \
    -Dvulkan=enabled \
    -Dopengl=enabled \
    -Dshaderc=enabled \
    -Dglslang=disabled \
    -Dlcms=enabled \
    -Ddovi=enabled \
    -Dlibdovi=enabled \
    -Dxxhash=enabled \
    -Dvulkan-registry="$SOURCE_PREFIX/share/vulkan/registry/vk.xml"
  remove_dynamic_artifacts
  pkg-config --exists libplacebo
}

build_davs2() {
  local davs2_patch="$BUILDER_DIR/patch/davs2-0001-skip-lto-sensitive-endian-probe-on-macos-arm64.patch"

  clone_or_update https://github.com/saindriches/davs2.git "$SOURCE_ROOT/davs2"
  git -C "$SOURCE_ROOT/davs2" apply --check "$davs2_patch"
  git -C "$SOURCE_ROOT/davs2" apply "$davs2_patch"
  (
    cd "$SOURCE_ROOT/davs2/build/linux"
    CC="$CXX" \
    CFLAGS="$CXXFLAGS" \
    CXXFLAGS="$CXXFLAGS" \
    LDFLAGS="$LDFLAGS" \
      ./configure \
        --prefix="$SOURCE_PREFIX" \
        --disable-cli \
        --bit-depth=10
    make -j"$(ci_jobs)"
    make install
  )
  remove_dynamic_artifacts
  pkg-config --exists davs2
}

build_uavs3d() {
  clone_or_update https://github.com/uavs3/uavs3d.git "$SOURCE_ROOT/uavs3d"
  cmake_static_install "$SOURCE_ROOT/uavs3d" "$BUILD_ROOT/uavs3d" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCOMPILE_10BIT=1
  remove_dynamic_artifacts
  pkg-config --exists uavs3d
}

build_libzvbi() {
  clone_or_update https://github.com/zapping-vbi/zvbi.git "$SOURCE_ROOT/zvbi"
  configure_make_install_static "$SOURCE_ROOT/zvbi" \
    --disable-dvb \
    --without-doxygen
  remove_dynamic_artifacts
  pkg-config --exists zvbi-0.2
}

build_zimg() {
  clone_or_update https://github.com/sekrit-twc/zimg.git "$SOURCE_ROOT/zimg"
  git -C "$SOURCE_ROOT/zimg" submodule update --init --recursive
  configure_make_install_static "$SOURCE_ROOT/zimg"
  remove_dynamic_artifacts
  pkg-config --exists zimg
}

build_game_music_emu() {
  clone_or_update https://github.com/libgme/game-music-emu.git "$SOURCE_ROOT/game-music-emu"
  cmake_static_install "$SOURCE_ROOT/game-music-emu" "$BUILD_ROOT/game-music-emu" \
    -DENABLE_UBSAN=OFF
  remove_dynamic_artifacts
  pkg-config --exists libgme || pkg-config --exists gme
}

build_libbs2b() {
  clone_or_update https://github.com/alexmarsev/libbs2b.git "$SOURCE_ROOT/libbs2b"
  local libbs2b_patch="$BUILDER_DIR/patch/libbs2b-0001-build-library-without-sndfile-tools.patch"
  git -C "$SOURCE_ROOT/libbs2b" apply --check "$libbs2b_patch"
  git -C "$SOURCE_ROOT/libbs2b" apply "$libbs2b_patch"
  configure_make_install_static "$SOURCE_ROOT/libbs2b"
  remove_dynamic_artifacts
  pkg-config --exists libbs2b
}

build_libcaca() {
  clone_or_update https://github.com/cacalabs/libcaca.git "$SOURCE_ROOT/libcaca"
  configure_make_install_static "$SOURCE_ROOT/libcaca" \
    --disable-doc \
    --disable-examples \
    --disable-python \
    --disable-ruby \
    --disable-csharp \
    --disable-java \
    --disable-imlib2 \
    --disable-ncurses
  remove_dynamic_artifacts
  pkg-config --exists caca
}

build_libcdio() {
  local iconv_cflags
  local iconv_libs

  clone_or_update https://git.savannah.gnu.org/git/libcdio.git "$SOURCE_ROOT/libcdio"
  iconv_cflags="$(pkg-config --cflags libiconv 2>/dev/null || pkg-config --cflags iconv 2>/dev/null || true)"
  iconv_libs="$(pkg-config --libs --static libiconv 2>/dev/null || pkg-config --libs --static iconv 2>/dev/null || printf '%s' '-liconv')"
  (
    export MAKEINFO=true
    export CPPFLAGS="$CPPFLAGS $iconv_cflags"
    export LIBS="${LIBS:-} $iconv_libs"
    export am_cv_func_iconv=yes
    export am_cv_func_iconv_works=yes
    configure_make_install_static "$SOURCE_ROOT/libcdio" \
      --without-cd-drive \
      --without-cd-info \
      --without-cdda-player \
      --without-iso-info \
      --without-iso-read \
      --without-cd-read
  )
  remove_dynamic_artifacts
  pkg-config --exists libcdio

  clone_or_update https://github.com/libcdio/libcdio-paranoia.git "$SOURCE_ROOT/libcdio-paranoia"
  local libcdio_paranoia_patch="$BUILDER_DIR/patch/libcdio-paranoia-0001-build-libraries-only.patch"
  git -C "$SOURCE_ROOT/libcdio-paranoia" apply --check "$libcdio_paranoia_patch"
  git -C "$SOURCE_ROOT/libcdio-paranoia" apply "$libcdio_paranoia_patch"
  (
    export MAKEINFO=true
    export CPPFLAGS="$CPPFLAGS $iconv_cflags"
    export LIBS="${LIBS:-} $iconv_libs"
    export am_cv_func_iconv=yes
    export am_cv_func_iconv_works=yes
    configure_make_install_static "$SOURCE_ROOT/libcdio-paranoia"
  )
  remove_dynamic_artifacts
  pkg-config --exists libcdio_cdda
  pkg-config --exists libcdio_paranoia
}

build_rav1e() {
  clone_or_update https://github.com/xiph/rav1e.git "$SOURCE_ROOT/rav1e"
  cargo cinstall \
    --manifest-path "$SOURCE_ROOT/rav1e/Cargo.toml" \
    --release \
    --prefix "$SOURCE_PREFIX"
  remove_dynamic_artifacts
  pkg-config --exists rav1e
}

build_libvidstab() {
  clone_or_update https://github.com/georgmartius/vid.stab.git "$SOURCE_ROOT/vid.stab"
  cmake_static_install "$SOURCE_ROOT/vid.stab" "$BUILD_ROOT/vid.stab" \
    -DUSE_OMP=OFF
  remove_dynamic_artifacts
  pkg-config --exists vidstab
}

build_kvazaar() {
  clone_or_update https://github.com/ultravideo/kvazaar.git "$SOURCE_ROOT/kvazaar"
  configure_make_install_static "$SOURCE_ROOT/kvazaar"
  remove_dynamic_artifacts
  pkg-config --exists kvazaar
}

build_xvidcore() {
  local archive="$SOURCE_ROOT/xvidcore-1.3.7.tar.gz"
  local src="$SOURCE_ROOT/xvidcore"
  if [[ ! -d "$src" ]]; then
    curl -L https://downloads.xvid.com/downloads/xvidcore-1.3.7.tar.gz -o "$archive"
    mkdir -p "$src"
    tar -xzf "$archive" -C "$src" --strip-components=1
  fi
  (
    cd "$src/build/generic"
    ./configure \
      --prefix="$SOURCE_PREFIX" \
      --disable-shared \
      --enable-static
    make -j"$(ci_jobs)"
    make install
  )
  remove_dynamic_artifacts
  pkg-config --exists xvidcore || true
}

patch_moltenvk_dynamic_headerpad() {
  local project_file="$SOURCE_ROOT/MoltenVK/MoltenVK/MoltenVK.xcodeproj/project.pbxproj"

  [[ -f "$project_file" ]] || die "MoltenVK Xcode project was not found: $project_file"
  python3 - "$project_file" <<'PY'
import re
import sys
from pathlib import Path

project_file = Path(sys.argv[1])
text = project_file.read_text()
flag = '"-Wl,-headerpad_max_install_names",'

pattern = re.compile(
    r'(?P<prefix>LD_DYLIB_INSTALL_NAME = "@rpath/lib\$\{PRODUCT_NAME\}\.dylib";\n'
    r'(?P<indent>\s+)OTHER_LDFLAGS = \(\n)'
    r'(?P<body>.*?)'
    r'(?P<suffix>\s+\);)',
    re.DOTALL,
)

patched = 0
already_patched = 0

def add_headerpad(match):
    global patched, already_patched
    body = match.group("body")
    if flag in body:
        already_patched += 1
        return match.group(0)

    entry_indent_match = re.search(r'^(\s*)"', body, re.MULTILINE)
    entry_indent = entry_indent_match.group(1) if entry_indent_match else match.group("indent") + "\t"
    separator = "" if body.endswith("\n") else "\n"
    suffix = match.group("suffix")
    if suffix.startswith("\n"):
        suffix = suffix[1:]
    patched += 1
    return match.group("prefix") + body + separator + f"{entry_indent}{flag}\n" + suffix

updated = pattern.sub(add_headerpad, text)
if patched == 0 and already_patched == 0:
    raise SystemExit("did not find MoltenVK dynamic dylib OTHER_LDFLAGS blocks to patch")

if updated != text:
    project_file.write_text(updated)

print(f"MoltenVK dynamic dylib header padding: patched={patched}, already_patched={already_patched}")
PY
}

verify_moltenvk_dynamic_can_be_rewritten() {
  local dylib="$1"
  local probe="$BUILD_ROOT/moltenvk-headerpad-probe.dylib"

  [[ -f "$dylib" ]] || die "cannot verify missing MoltenVK dylib: $dylib"
  cp "$dylib" "$probe"
  chmod u+w "$probe"
  if ! normalize_llvm_runtime_refs "$probe"; then
    rm -f "$probe"
    die "MoltenVK dylib was built without enough header padding for runtime fixups: $dylib"
  fi
  rm -f "$probe"
}

build_moltenvk() {
  clone_or_update https://github.com/KhronosGroup/MoltenVK.git "$SOURCE_ROOT/MoltenVK"
  git -C "$SOURCE_ROOT/MoltenVK" submodule update --init --recursive
  (
    cd "$SOURCE_ROOT/MoltenVK"
    ./fetchDependencies --macos
    patch_moltenvk_dynamic_headerpad
    make macos
  )
  mkdir -p "$SOURCE_PREFIX/lib" "$SOURCE_PREFIX/share/vulkan/icd.d" "$SOURCE_PREFIX/share/vulkan/explicit_layer.d"
  moltenvk_static="$(find "$SOURCE_ROOT/MoltenVK" -path '*MoltenVK.xcframework*' -name libMoltenVK.a | head -n1 || true)"
  [[ -n "$moltenvk_static" ]] || die "libMoltenVK.a was not produced by MoltenVK"
  cp "$moltenvk_static" "$SOURCE_PREFIX/lib/libMoltenVK.a"

  moltenvk_dynamic="$(find "$SOURCE_ROOT/MoltenVK/Package" -path '*/dynamic/dylib/macOS/libMoltenVK*.dylib' | head -n1 || true)"
  [[ -n "$moltenvk_dynamic" ]] || die "libMoltenVK.dylib was not produced by MoltenVK"
  verify_moltenvk_dynamic_can_be_rewritten "$moltenvk_dynamic"
  cp "$moltenvk_dynamic" "$SOURCE_PREFIX/lib/$(basename "$moltenvk_dynamic")"

  while IFS= read -r icd_json; do
    cp "$icd_json" "$SOURCE_PREFIX/share/vulkan/icd.d/$(basename "$icd_json")"
  done < <(find "$SOURCE_ROOT/MoltenVK" -type f -name '*icd*.json' | sort)

  while IFS= read -r layer_json; do
    cp "$layer_json" "$SOURCE_PREFIX/share/vulkan/explicit_layer.d/$(basename "$layer_json")"
  done < <(find "$SOURCE_ROOT/MoltenVK" -type f -name '*layer*.json' | sort)
}

build_frei0r() {
  local frei0r_module_ldflags

  clone_or_update https://github.com/dyne/frei0r.git "$SOURCE_ROOT/frei0r"
  frei0r_module_ldflags="$(pkg-config --libs --static cairo pixman-1)"

  LDFLAGS="$LDFLAGS $frei0r_module_ldflags" cmake_static_install "$SOURCE_ROOT/frei0r" "$BUILD_ROOT/frei0r" \
    -DWITHOUT_OPENCV=ON \
    -DWITHOUT_GAVL=ON
  pkg-config --exists frei0r
}

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

build_vapoursynth() {
  local vapoursynth_api_flags
  local vapoursynth_release

  clone_or_update https://github.com/vapoursynth/vapoursynth.git "$SOURCE_ROOT/vapoursynth"
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

run_logged "source-dep-vulkan-headers" build_vulkan_headers

run_parallel_batch "bootstrap source deps" \
  "source-dep-luajit" build_luajit \
  "source-dep-libdovi" build_libdovi \
  "source-dep-vulkan-loader" build_vulkan_loader \
  "source-dep-moltenvk" build_moltenvk

run_parallel_batch "independent source deps" \
  "source-dep-davs2" build_davs2 \
  "source-dep-uavs3d" build_uavs3d \
  "source-dep-libzvbi" build_libzvbi \
  "source-dep-zimg" build_zimg \
  "source-dep-game-music-emu" build_game_music_emu \
  "source-dep-libbs2b" build_libbs2b \
  "source-dep-libcaca" build_libcaca \
  "source-dep-libcdio" build_libcdio \
  "source-dep-rav1e" build_rav1e \
  "source-dep-libvidstab" build_libvidstab \
  "source-dep-kvazaar" build_kvazaar \
  "source-dep-xvidcore" build_xvidcore \
  "source-dep-frei0r" build_frei0r

run_logged "source-dep-vapoursynth" build_vapoursynth

run_logged "rust-staticlib-symbol-normalization" normalize_rust_staticlibs

run_parallel_batch "source deps with local prerequisites" \
  "source-dep-luasocket" build_luasocket \
  "source-dep-libplacebo" build_libplacebo
