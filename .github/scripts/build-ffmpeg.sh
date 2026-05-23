#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_source_env

superbuild_dir="$BUILD_ROOT/source-superbuild"
[[ -d "$superbuild_dir" ]] || die "source superbuild is not configured: $superbuild_dir"

run_logged "cmake-build-ffmpeg-static" \
  cmake --build "$superbuild_dir" --target ffmpeg-static --verbose
