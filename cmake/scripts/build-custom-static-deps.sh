#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/superbuild-common.sh"
init_superbuild_environment

vulkan_sdk="$(PYTHONPATH="$CI_SCRIPT_DIR" python3 -c 'import ci_matrix; print(ci_matrix.VULKAN_SDK_TAG, ci_matrix.VULKAN_SDK_VERSION)')"
read -r VULKAN_SDK_TAG VULKAN_SDK_VERSION <<< "$vulkan_sdk"

source "$(dirname "${BASH_SOURCE[0]}")/deps/lua.sh"
source "$(dirname "${BASH_SOURCE[0]}")/deps/rust.sh"
source "$(dirname "${BASH_SOURCE[0]}")/deps/graphics.sh"
source "$(dirname "${BASH_SOURCE[0]}")/deps/media.sh"
source "$(dirname "${BASH_SOURCE[0]}")/deps/vapoursynth.sh"

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
