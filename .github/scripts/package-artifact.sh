#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_github_file GITHUB_OUTPUT

mpv_ref="${SAFE_MPV_REF:-${MPV_REF:-}}"
ffmpeg_ref="${SAFE_FFMPEG_REF:-${FFMPEG_REF:-}}"
[[ -n "$mpv_ref" ]] || die "SAFE_MPV_REF is not set"
[[ -n "$ffmpeg_ref" ]] || die "SAFE_FFMPEG_REF is not set"

cd "$MPV_DIR"

remove_macos_metadata build/mpv.app

artifact_name="mpv-${mpv_ref}-ffmpeg-${ffmpeg_ref}-static-nonfree-macos-15-arm64"
run_logged "package-mpv-app-artifact" create_clean_tar_gz "${artifact_name}.tar.gz" -C build mpv.app

{
  echo "name=$artifact_name"
  echo "path=mpv/${artifact_name}.tar.gz"
} >> "$GITHUB_OUTPUT"
