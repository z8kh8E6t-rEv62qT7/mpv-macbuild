#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_github_file GITHUB_ENV
require_github_file GITHUB_OUTPUT
require_github_file GITHUB_STEP_SUMMARY

event_name="${GITHUB_EVENT_NAME:-}"
head_commit_message="${HEAD_COMMIT_MESSAGE:-}"
repo_owner="${GITHUB_REPOSITORY_OWNER:-}"

[[ -n "$event_name" ]] || die "GITHUB_EVENT_NAME is not set"
[[ -n "$repo_owner" ]] || die "GITHUB_REPOSITORY_OWNER is not set"

mode="read"
reason="push without [release] marker"
release_enabled="false"
nuget_write_enabled="false"

if [[ "$event_name" == "workflow_dispatch" ]]; then
  mode="readwrite"
  reason="workflow_dispatch enables persistent NuGet writes and release publishing"
  release_enabled="true"
  nuget_write_enabled="true"
elif [[ "$event_name" == "push" && "$head_commit_message" == *"[release]"* ]]; then
  mode="readwrite"
  reason="head commit message contains [release]"
  release_enabled="true"
  nuget_write_enabled="true"
fi

feed_url="https://nuget.pkg.github.com/${repo_owner}/index.json"

{
  echo "NUGET_CACHE_MODE=$mode"
  echo "NUGET_CACHE_REASON=$reason"
  echo "NUGET_FEED_URL=$feed_url"
  echo "NUGET_SOURCE_NAME=github"
} >> "$GITHUB_ENV"

{
  echo "mode=$mode"
  echo "reason=$reason"
  echo "feed_url=$feed_url"
  echo "source_name=github"
  echo "release_enabled=$release_enabled"
  echo "nuget_write_enabled=$nuget_write_enabled"
} >> "$GITHUB_OUTPUT"

{
  echo "## NuGet cache mode"
  echo
  echo "- mode: \`$mode\`"
  echo "- reason: $reason"
  echo "- feed: \`$feed_url\`"
  echo "- release enabled: \`$release_enabled\`"
  echo "- NuGet write enabled: \`$nuget_write_enabled\`"
} >> "$GITHUB_STEP_SUMMARY"
