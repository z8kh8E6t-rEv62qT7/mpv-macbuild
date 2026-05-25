#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

kind="${1:-build}"

case "$kind" in
  configure|build)
    log_path="$MPV_DIR/build/meson-logs/meson-log.txt"
    ;;
  test|tests)
    log_path="$MPV_DIR/build/meson-logs/testlog.txt"
    ;;
  *)
    die "unknown Meson log kind: $kind"
    ;;
esac

if [[ -f "$log_path" ]]; then
  cat "$log_path"
else
  echo "Meson log not found: $log_path" >&2
fi
