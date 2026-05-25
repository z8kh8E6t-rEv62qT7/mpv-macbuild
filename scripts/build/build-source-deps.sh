#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

require_source_env

ffmpeg_ref="${RESOLVED_FFMPEG_REF:-${FFMPEG_REF:-}}"
[[ -n "$ffmpeg_ref" ]] || die "RESOLVED_FFMPEG_REF is not set"

superbuild_dir="$BUILD_ROOT/source-superbuild"
mkdir -p "$AUDIT_DIR/logs"

run_logged "cmake-configure-source-superbuild" \
  cmake -S "$BUILDER_DIR/cmake" -B "$superbuild_dir" \
    -G Ninja \
    -DBUILDER_DIR="$BUILDER_DIR" \
    -DSOURCE_PREFIX="$SOURCE_PREFIX" \
    -DFFMPEG_PREFIX="$FFMPEG_PREFIX" \
    -DSOURCE_ROOT="$SOURCE_ROOT" \
    -DBUILD_ROOT="$BUILD_ROOT" \
    -DAUDIT_DIR="$AUDIT_DIR" \
    -DFFMPEG_REF="$ffmpeg_ref"

run_logged "cmake-build-source-static-deps" \
  cmake --build "$superbuild_dir" --target source-static-deps --verbose
