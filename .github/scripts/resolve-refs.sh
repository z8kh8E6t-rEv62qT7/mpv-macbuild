#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_github_file GITHUB_OUTPUT

requested_mpv_ref="${REQUESTED_MPV_REF:-latest}"
requested_ffmpeg_ref="${REQUESTED_FFMPEG_REF:-latest}"

if [[ "$requested_mpv_ref" == "latest" ]]; then
  mpv_ref="$(gh api repos/mpv-player/mpv/releases/latest --jq .tag_name)"
else
  mpv_ref="$requested_mpv_ref"
fi

if [[ "$requested_ffmpeg_ref" == "latest" ]]; then
  ffmpeg_ref="$(
    git ls-remote --tags --refs https://github.com/FFmpeg/FFmpeg.git 'n[0-9]*' |
    awk '{print $2}' |
    sed 's#refs/tags/##' |
    python3 -c 'import re, sys; tags = [line.strip() for line in sys.stdin if re.fullmatch(r"n[0-9]+(\.[0-9]+)*", line.strip())]; assert tags, "no FFmpeg release tags found"; print(max(tags, key=lambda tag: tuple(int(part) for part in tag[1:].split("."))))'
  )"
else
  ffmpeg_ref="$requested_ffmpeg_ref"
fi

safe_mpv_ref="${mpv_ref//\//-}"
safe_ffmpeg_ref="${ffmpeg_ref//\//-}"

{
  echo "mpv_ref=$mpv_ref"
  echo "safe_mpv_ref=$safe_mpv_ref"
  echo "ffmpeg_ref=$ffmpeg_ref"
  echo "safe_ffmpeg_ref=$safe_ffmpeg_ref"
} >> "$GITHUB_OUTPUT"

echo "Resolved mpv ref: $mpv_ref"
echo "Resolved FFmpeg ref: $ffmpeg_ref"
