#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_github_file GITHUB_OUTPUT

ffmpeg_ref="${SAFE_FFMPEG_REF:-${FFMPEG_REF:-}}"
[[ -n "$ffmpeg_ref" ]] || die "SAFE_FFMPEG_REF is not set"
[[ -n "${FFMPEG_PREFIX:-}" ]] || die "FFMPEG_PREFIX is not set"
[[ -d "$FFMPEG_PREFIX" ]] || die "FFMPEG_PREFIX does not exist: $FFMPEG_PREFIX"

remove_macos_metadata "$FFMPEG_PREFIX"

cd "$MPV_DIR"

ffmpeg_artifact_name="ffmpeg-${ffmpeg_ref}-static-nonfree-m4-macos-15-arm64"
run_logged "package-ffmpeg-prefix-artifact" create_clean_tar_gz "${ffmpeg_artifact_name}.tar.gz" -C "$FFMPEG_PREFIX" .

{
  echo "ffmpeg_name=$ffmpeg_artifact_name"
  echo "ffmpeg_path=mpv/${ffmpeg_artifact_name}.tar.gz"
} >> "$GITHUB_OUTPUT"
