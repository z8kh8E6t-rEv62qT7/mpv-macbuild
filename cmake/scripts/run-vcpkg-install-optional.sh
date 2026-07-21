#!/usr/bin/env bash
set -euo pipefail

: "${AUDIT_DIR:?AUDIT_DIR is not set}"
: "${BUILDER_DIR:?BUILDER_DIR is not set}"
: "${VCPKG_ROOT:?VCPKG_ROOT is not set}"

install_script="$BUILDER_DIR/cmake/scripts/run-vcpkg-install.sh"
report="$AUDIT_DIR/ffmpeg-lgpl-optional-dependencies.tsv"
mkdir -p "$AUDIT_DIR/logs"
printf 'dependency\tstatus\tdetail\n' > "$report"

for dependency in "$@"; do
  log="$AUDIT_DIR/logs/vcpkg-optional-${dependency}.log"
  if bash "$install_script" "$dependency" >"$log" 2>&1; then
    printf '%s\tenabled\tinstalled\n' "$dependency" >> "$report"
  else
    status=$?
    detail="vcpkg install exited with status $status"
    printf '%s\tskipped\t%s\n' "$dependency" "$detail" >> "$report"
    echo "Optional LGPL dependency skipped: $dependency ($detail)"
  fi
done

cat "$report"
