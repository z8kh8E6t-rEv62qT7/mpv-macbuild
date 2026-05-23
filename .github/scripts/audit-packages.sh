#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_source_env
require_github_file GITHUB_STEP_SUMMARY

export BUILDER_DIR
export WORKSPACE_DIR
export MPV_DIR
export AUDIT_DIR

run_logged "package-retention-audit" python3 "$CI_SCRIPT_DIR/audit_packages.py"
