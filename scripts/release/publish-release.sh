#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

require_github_file GITHUB_STEP_SUMMARY

release_tag="${RELEASE_TAG:-}"
release_title="${RELEASE_TITLE:-}"
mpv_asset="${MPV_RELEASE_ASSET:-}"
ffmpeg_gpl_asset="${FFMPEG_GPL_RELEASE_ASSET:-}"
ffmpeg_lgpl_asset="${FFMPEG_LGPL_RELEASE_ASSET:-}"

[[ -n "$release_tag" ]] || die "RELEASE_TAG is not set"
[[ -n "$release_title" ]] || die "RELEASE_TITLE is not set"
[[ -n "$mpv_asset" ]] || die "MPV_RELEASE_ASSET is not set"
[[ -n "$ffmpeg_gpl_asset" ]] || die "FFMPEG_GPL_RELEASE_ASSET is not set"
[[ -n "$ffmpeg_lgpl_asset" ]] || die "FFMPEG_LGPL_RELEASE_ASSET is not set"
[[ -f "$mpv_asset" ]] || die "mpv release asset not found: $mpv_asset"
[[ -f "$ffmpeg_gpl_asset" ]] || die "GPL FFmpeg release asset not found: $ffmpeg_gpl_asset"
[[ -f "$ffmpeg_lgpl_asset" ]] || die "LGPL FFmpeg release asset not found: $ffmpeg_lgpl_asset"

if gh release view "$release_tag" >/dev/null 2>&1; then
  run_logged "release-upload-assets" \
    gh release upload "$release_tag" "$mpv_asset" "$ffmpeg_gpl_asset" "$ffmpeg_lgpl_asset" --clobber
  run_logged "release-mark-latest" gh release edit "$release_tag" --latest
else
  run_logged "release-create" \
    gh release create "$release_tag" "$mpv_asset" "$ffmpeg_gpl_asset" "$ffmpeg_lgpl_asset" \
      --target "$GITHUB_SHA" \
      --title "$release_title" \
      --generate-notes \
      --latest
fi

release_url="$(gh release view "$release_tag" --json url --jq .url)"

{
  echo "## GitHub release"
  echo
  echo "- tag: \`$release_tag\`"
  echo "- title: $release_title"
  echo "- url: $release_url"
} >> "$GITHUB_STEP_SUMMARY"
