#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_source_env

phase="${1:-all}"
cd "$MPV_DIR"

run_build() {
  run_logged "mpv-meson-compile" meson compile -C build -j4
  run_logged "mpv-normalize-build-runtime" normalize_mpv_build_runtime
  run_logged "mpv-meson-install" meson install -C build
  run_logged "mpv-smoke-test" ./build/mpv -v --no-config
}

run_tests() {
  local test_home="$RUNNER_TEMP/mpv-test-home"
  local test_config_dir="$test_home/.config/mpv"

  rm -rf "$test_home"
  mkdir -p "$test_config_dir"
  cat > "$test_config_dir/mpv.conf" <<'EOF'
vo=null
ao=null
gpu-context=no
hwdec=no
EOF

  run_logged "mpv-meson-test" \
    env \
      HOME="$test_home" \
      XDG_CONFIG_HOME="$test_home/.config" \
      MPV_HOME="$test_config_dir" \
      SDL_VIDEODRIVER=dummy \
      SDL_AUDIODRIVER=dummy \
      meson test -C build --print-errorlogs
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

copy_vulkan_runtime_into_bundle() {
  local framework_root="build/mpv.app/Contents/Frameworks"
  local resource_root="build/mpv.app/Contents/Resources/vulkan"
  local moltenvk_library
  local moltenvk_basename="libMoltenVK.dylib"

  mkdir -p "$framework_root" "$resource_root/icd.d" "$resource_root/explicit_layer.d"

  while IFS= read -r dylib; do
    cp "$dylib" "$framework_root/$(basename "$dylib")"
    chmod u+w "$framework_root/$(basename "$dylib")"
  done < <(find "$FFMPEG_PREFIX/lib" -maxdepth 1 -type f \( -name 'libvulkan*.dylib' -o -name 'libMoltenVK*.dylib' \) | sort)

  ensure_vulkan_loader_links "$framework_root"

  moltenvk_library="$(find "$framework_root" -maxdepth 1 -type f -name 'libMoltenVK*.dylib' | head -n1 || true)"
  if [[ -n "$moltenvk_library" ]]; then
    moltenvk_basename="$(basename "$moltenvk_library")"
  fi

  while IFS= read -r json_file; do
    cp "$json_file" "$resource_root/icd.d/$(basename "$json_file")"
  done < <(find "$FFMPEG_PREFIX/share/vulkan/icd.d" -type f -name '*.json' 2>/dev/null | sort)

  while IFS= read -r json_file; do
    cp "$json_file" "$resource_root/explicit_layer.d/$(basename "$json_file")"
  done < <(find "$FFMPEG_PREFIX/share/vulkan/explicit_layer.d" -type f -name '*.json' 2>/dev/null | sort)

  python3 - "$resource_root" "$moltenvk_basename" <<'PY'
import json
import pathlib
import sys

resource_root = pathlib.Path(sys.argv[1])
moltenvk_basename = sys.argv[2]
for json_path in resource_root.rglob("*.json"):
    try:
        data = json.loads(json_path.read_text())
    except json.JSONDecodeError:
        continue
    if data.get("ICD", {}).get("library_path"):
        data["ICD"]["library_path"] = f"../../../Frameworks/{moltenvk_basename}"
    if data.get("layer", {}).get("library_path"):
        data["layer"]["library_path"] = f"../../../Frameworks/{moltenvk_basename}"
    json_path.write_text(json.dumps(data, indent=2) + "\n")
PY

  while IFS= read -r dylib; do
    install_name_tool -id "@rpath/$(basename "$dylib")" "$dylib"
  done < <(find "$framework_root" -maxdepth 1 -type f \( -name 'libvulkan*.dylib' -o -name 'libMoltenVK*.dylib' \) | sort)

  while IFS= read -r oldref; do
    basename="$(basename "$oldref")"
    install_name_tool -change "$oldref" "@executable_path/../Frameworks/$basename" "build/mpv.app/Contents/MacOS/mpv"
  done < <(otool -L build/mpv.app/Contents/MacOS/mpv | awk '/libvulkan.*[.]dylib|libMoltenVK.*[.]dylib/ {print $1}')
  delete_rpath_if_present "build/mpv.app/Contents/MacOS/mpv" "$FFMPEG_PREFIX/lib"

  while IFS= read -r dylib; do
    while IFS= read -r oldref; do
      basename="$(basename "$oldref")"
      install_name_tool -change "$oldref" "@loader_path/$basename" "$dylib"
    done < <(otool -L "$dylib" | awk '/libvulkan.*[.]dylib|libMoltenVK.*[.]dylib/ {print $1}')
  done < <(find "$framework_root" -maxdepth 1 -type f \( -name 'libvulkan*.dylib' -o -name 'libMoltenVK*.dylib' \) | sort)
}

copy_llvm_runtime_into_bundle() {
  local framework_root="build/mpv.app/Contents/Frameworks"
  local bundle_binary="build/mpv.app/Contents/MacOS/mpv"
  local macos_lib_root="build/mpv.app/Contents/MacOS/lib"
  local library
  local loader_ref
  local target

  copy_llvm_runtime_into_dir "$framework_root"

  while IFS= read -r target; do
    is_mach_o "$target" || continue
    if [[ "$target" == "$bundle_binary" ]]; then
      loader_ref="@executable_path/../Frameworks"
    elif [[ "$target" == "$framework_root"/* ]]; then
      loader_ref="@loader_path"
    else
      loader_ref="$(loader_path_to_dir "$target" "$framework_root")"
    fi
    rewrite_llvm_runtime_refs_to_bundle "$target" "$loader_ref"
    delete_llvm_runtime_rpaths "$target"
  done < <(find build/mpv.app -type f \( -perm -111 -o -name '*.dylib' -o -name '*.so' -o -name '*.bundle' \) | sort)

  if [[ -d "$macos_lib_root" ]]; then
    for library in "$LLVM_LIBCXX_DYLIB" "$LLVM_LIBCXXABI_DYLIB" "$LLVM_LIBUNWIND_DYLIB"; do
      rm -f "$macos_lib_root/$(basename "$library")"
    done
  fi
}

normalize_mpv_build_runtime() {
  local target
  local targets=()

  for target in build/mpv build/libmpv.2.dylib; do
    [[ -e "$target" ]] || continue
    normalize_llvm_runtime_refs "$target"
    rewrite_vapoursynth_ref "$target" "@rpath/libvsscript.dylib"
    add_rpath_if_missing "$target" "$SOURCE_PREFIX/lib/vapoursynth"
    add_rpath_if_missing "$target" "$FFMPEG_PREFIX/lib"
    targets+=("$target")
  done

  [[ "${#targets[@]}" -gt 0 ]] || die "no mpv build products found for runtime normalization"
  assert_uses_llvm_runtime_refs "mpv build tree" "${targets[@]}"
}

fix_vapoursynth_bundle_refs() {
  local runtime_dir="build/mpv.app/Contents/PlugIns/source-built/vapoursynth"
  local bundle_binary="build/mpv.app/Contents/MacOS/mpv"
  local target

  [[ -d "$runtime_dir" ]] || die "missing bundled VapourSynth runtime dir: $runtime_dir"
  normalize_vapoursynth_runtime_dir "$runtime_dir"
  while IFS= read -r target; do
    has_vapoursynth_ref "$target" || continue
    rewrite_vapoursynth_ref "$target" "@rpath/libvsscript.dylib"
    delete_rpath_if_present "$target" "$SOURCE_PREFIX/lib/vapoursynth"
    if [[ "$target" == "$bundle_binary" ]]; then
      add_rpath_if_missing "$target" "@executable_path/../PlugIns/source-built/vapoursynth"
    else
      add_rpath_if_missing "$target" "$(loader_path_to_dir "$target" "$runtime_dir")"
    fi
  done < <(find build/mpv.app -type f \( -perm -111 -o -name '*.dylib' -o -name '*.so' -o -name '*.bundle' \) | sort)

  find build/mpv.app/Contents/MacOS/lib -maxdepth 1 -type f \
    \( -name 'libvsscript*.dylib' -o -name 'libvapoursynth*.dylib' \) \
    -delete 2>/dev/null || true
}

run_bundle() {
  run_logged "mpv-macos-bundle" meson compile -C build macos-bundle
  test -d build/mpv.app

  plugin_root="build/mpv.app/Contents/PlugIns/source-built"
  mkdir -p "$plugin_root"

  for plugin_dir in \
    "$SOURCE_PREFIX/lib/frei0r-1" \
    "$SOURCE_PREFIX/lib/vapoursynth" \
    "$SOURCE_PREFIX/luarocks/lib/lua/5.1"
  do
    if [[ -d "$plugin_dir" ]]; then
      dest="$plugin_root/$(basename "$plugin_dir")"
      rm -rf "$dest"
      mkdir -p "$dest"
      cp -R "$plugin_dir"/. "$dest"/
    fi
  done

  copy_vulkan_runtime_into_bundle
  fix_vapoursynth_bundle_refs
  copy_llvm_runtime_into_bundle
}

case "$phase" in
  build)
    run_build
    ;;
  test)
    run_tests
    ;;
  bundle)
    run_bundle
    ;;
  all)
    run_build
    run_tests
    run_bundle
    ;;
  *)
    die "unknown build-test-bundle phase: $phase"
    ;;
esac
