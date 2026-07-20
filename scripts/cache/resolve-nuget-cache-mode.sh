#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

require_github_file GITHUB_ENV
require_github_file GITHUB_OUTPUT
require_github_file GITHUB_STEP_SUMMARY

event_name="${GITHUB_EVENT_NAME:-}"
head_commit_message="${HEAD_COMMIT_MESSAGE:-}"
repo_owner="${GITHUB_REPOSITORY_OWNER:-}"
requested_nuget_cleanup_action="${REQUESTED_NUGET_CLEANUP_ACTION:-dry-run}"

[[ -n "$event_name" ]] || die "GITHUB_EVENT_NAME is not set"
[[ -n "$repo_owner" ]] || die "GITHUB_REPOSITORY_OWNER is not set"

mode="read"
reason="push without [release] marker"
release_enabled="false"
nuget_write_enabled="false"
nuget_cleanup_action="dry-run"

if [[ "$event_name" == "workflow_dispatch" ]]; then
  case "$requested_nuget_cleanup_action" in
    dry-run|delete) ;;
    *) die "unsupported NuGet cleanup action: $requested_nuget_cleanup_action" ;;
  esac
  mode="readwrite"
  reason="workflow_dispatch enables persistent NuGet writes and release publishing"
  release_enabled="true"
  nuget_write_enabled="true"
  nuget_cleanup_action="$requested_nuget_cleanup_action"
elif [[ "$event_name" == "push" && "$head_commit_message" == *"[release]"* ]]; then
  mode="readwrite"
  reason="head commit message contains [release]"
  release_enabled="true"
  nuget_write_enabled="true"
  nuget_cleanup_action="delete"
fi

feed_url="https://nuget.pkg.github.com/${repo_owner}/index.json"

{
  echo "NUGET_CACHE_MODE=$mode"
  echo "NUGET_CACHE_REASON=$reason"
  echo "NUGET_FEED_URL=$feed_url"
  echo "NUGET_SOURCE_NAME=github"
  echo "NUGET_CLEANUP_ACTION=$nuget_cleanup_action"
} >> "$GITHUB_ENV"

{
  echo "mode=$mode"
  echo "reason=$reason"
  echo "feed_url=$feed_url"
  echo "source_name=github"
  echo "release_enabled=$release_enabled"
  echo "nuget_write_enabled=$nuget_write_enabled"
  echo "nuget_cleanup_action=$nuget_cleanup_action"
} >> "$GITHUB_OUTPUT"

{
  echo "## NuGet cache mode"
  echo
  echo "- mode: \`$mode\`"
  echo "- reason: $reason"
  echo "- feed: \`$feed_url\`"
  echo "- release enabled: \`$release_enabled\`"
  echo "- NuGet write enabled: \`$nuget_write_enabled\`"
  echo "- NuGet cleanup action: \`$nuget_cleanup_action\`"
} >> "$GITHUB_STEP_SUMMARY"
