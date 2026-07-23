#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$CI_SCRIPT_ROOT/lib/ffmpeg-package-common.sh"

require_github_file GITHUB_OUTPUT
require_source_env

output_dir="$MPV_DIR/release-assets"
stage_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ffmpeg-package.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
mkdir -p "$output_dir"

gpl_name="ffmpeg-gplv3-nonfree-macos15-arm64"
lgpl_name="ffmpeg-lgpl-macos15-arm64"

stage_ffmpeg_shared_prefix "$FFMPEG_PREFIX" "$stage_dir/ffmpeg-gplv3-nonfree"
validate_ffmpeg_shared_stage "$stage_dir/ffmpeg-gplv3-nonfree" ffmpeg ffprobe ffplay
stage_ffmpeg_shared_prefix "$FFMPEG_LGPL_PREFIX" "$stage_dir/ffmpeg-lgpl"
validate_ffmpeg_shared_stage "$stage_dir/ffmpeg-lgpl" ffmpeg
mkdir -p \
  "$stage_dir/ffmpeg-gplv3-nonfree/share/licenses/ffmpeg" \
  "$stage_dir/ffmpeg-lgpl/share/licenses/ffmpeg"
cp "$SOURCE_ROOT/ffmpeg/COPYING.GPLv3" \
  "$stage_dir/ffmpeg-gplv3-nonfree/share/licenses/ffmpeg/"
cp "$SOURCE_ROOT/ffmpeg-lgpl/COPYING.LGPLv2.1" \
  "$stage_dir/ffmpeg-lgpl/share/licenses/ffmpeg/"
git -C "$SOURCE_ROOT/ffmpeg" rev-parse HEAD > \
  "$stage_dir/ffmpeg-gplv3-nonfree/share/ffmpeg-build-commit.txt"
git -C "$SOURCE_ROOT/ffmpeg-lgpl" rev-parse HEAD > \
  "$stage_dir/ffmpeg-lgpl/share/ffmpeg-build-commit.txt"
remove_macos_metadata "$stage_dir"

run_logged "package-ffmpeg-gpl-artifact" \
  create_clean_tar_xz "$output_dir/$gpl_name.tar.xz" -C "$stage_dir" ffmpeg-gplv3-nonfree
run_logged "package-ffmpeg-lgpl-artifact" \
  create_clean_tar_xz "$output_dir/$lgpl_name.tar.xz" -C "$stage_dir" ffmpeg-lgpl

{
  echo "ffmpeg_gpl_name=$gpl_name"
  echo "ffmpeg_gpl_path=mpv/release-assets/$gpl_name.tar.xz"
  echo "ffmpeg_lgpl_name=$lgpl_name"
  echo "ffmpeg_lgpl_path=mpv/release-assets/$lgpl_name.tar.xz"
} >> "$GITHUB_OUTPUT"
