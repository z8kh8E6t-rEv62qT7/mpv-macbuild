#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_source_env

project="${1:-}"
[[ -n "$project" ]] || die "usage: print-superbuild-log.sh <external-project-name>"

log_glob="$BUILD_ROOT/superbuild/$project/src/${project}-stamp/${project}-*.log"
found=0

for log_path in $log_glob; do
  [[ -f "$log_path" ]] || continue
  found=1
  echo "===== $log_path ====="
  cat "$log_path"
  echo
done

if [[ "$found" == 0 ]]; then
  echo "No superbuild logs found for $project at $log_glob" >&2
fi
