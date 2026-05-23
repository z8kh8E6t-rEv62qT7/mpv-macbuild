#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_github_file GITHUB_STEP_SUMMARY

release_tag="${RELEASE_TAG:-}"
release_title="${RELEASE_TITLE:-}"
mpv_asset="${MPV_RELEASE_ASSET:-}"
ffmpeg_asset="${FFMPEG_RELEASE_ASSET:-}"

[[ -n "$release_tag" ]] || die "RELEASE_TAG is not set"
[[ -n "$release_title" ]] || die "RELEASE_TITLE is not set"
[[ -n "$mpv_asset" ]] || die "MPV_RELEASE_ASSET is not set"
[[ -n "$ffmpeg_asset" ]] || die "FFMPEG_RELEASE_ASSET is not set"
[[ -f "$mpv_asset" ]] || die "mpv release asset not found: $mpv_asset"
[[ -f "$ffmpeg_asset" ]] || die "FFmpeg release asset not found: $ffmpeg_asset"

if gh release view "$release_tag" >/dev/null 2>&1; then
  run_logged "release-upload-assets" \
    gh release upload "$release_tag" "$mpv_asset" "$ffmpeg_asset" --clobber
else
  run_logged "release-create" \
    gh release create "$release_tag" "$mpv_asset" "$ffmpeg_asset" \
      --target "$GITHUB_SHA" \
      --title "$release_title" \
      --generate-notes
fi

release_url="$(gh release view "$release_tag" --json url --jq .url)"

{
  echo "## GitHub release"
  echo
  echo "- tag: \`$release_tag\`"
  echo "- title: $release_title"
  echo "- url: $release_url"
} >> "$GITHUB_STEP_SUMMARY"
