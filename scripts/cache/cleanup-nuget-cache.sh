#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

require_github_file GITHUB_STEP_SUMMARY

python3 "$CI_SCRIPT_ROOT/cache/cleanup_nuget_cache.py"
