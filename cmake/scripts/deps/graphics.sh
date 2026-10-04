#!/usr/bin/env bash

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
