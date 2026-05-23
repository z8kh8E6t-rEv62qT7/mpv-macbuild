#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_github_file GITHUB_STEP_SUMMARY
export AUDIT_DIR

python3 "$CI_SCRIPT_DIR/cleanup_nuget_cache.py"
