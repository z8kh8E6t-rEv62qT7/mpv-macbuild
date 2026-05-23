#!/usr/bin/env bash
set -euo pipefail

: "${VCPKG_ROOT:?VCPKG_ROOT is not set}"
: "${VCPKG_INSTALLED_DIR:?VCPKG_INSTALLED_DIR is not set}"
: "${VCPKG_BINARY_CACHE:?VCPKG_BINARY_CACHE is not set}"

configure_nuget_source() {
  local nuget_exe
  local mono_bin

  [[ -n "${NUGET_FEED_URL:-}" ]] || return 0
  [[ -n "${NUGET_CONFIG_PATH:-}" ]] || return 0
  [[ -n "${NUGET_SOURCE_NAME:-}" ]] || return 0
  [[ -n "${GITHUB_TOKEN:-}" ]] || die "GITHUB_TOKEN is required for NuGet cache configuration"
  [[ -n "${GITHUB_REPOSITORY_OWNER:-}" ]] || die "GITHUB_REPOSITORY_OWNER is required for NuGet cache configuration"

  mkdir -p "$(dirname "$NUGET_CONFIG_PATH")"
  rm -f "$NUGET_CONFIG_PATH"
  cat > "$NUGET_CONFIG_PATH" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <config>
    <add key="defaultPushSource" value="$NUGET_FEED_URL" />
  </config>
</configuration>
EOF

  nuget_exe="$("$VCPKG_ROOT/vcpkg" fetch nuget | tail -n1 | tr -d '\r')"
  [[ -x "$nuget_exe" || -f "$nuget_exe" ]] || die "failed to resolve nuget.exe path from vcpkg fetch nuget"

  mono_bin="$(command -v mono || true)"
  [[ -n "$mono_bin" ]] || die "mono is required to configure the NuGet source on macOS"

  "$mono_bin" "$nuget_exe" sources Add \
    -Name "$NUGET_SOURCE_NAME" \
    -Source "$NUGET_FEED_URL" \
    -Username "$GITHUB_REPOSITORY_OWNER" \
    -Password "$GITHUB_TOKEN" \
    -StorePasswordInClearText \
    -ConfigFile "$NUGET_CONFIG_PATH"

  "$mono_bin" "$nuget_exe" sources List -ConfigFile "$NUGET_CONFIG_PATH"
}

die() {
  echo "error: $*" >&2
  exit 1
}

configure_vcpkg_binary_sources() {
  local nuget_mode

  [[ -z "${VCPKG_BINARY_SOURCES:-}" ]] || return 0

  VCPKG_BINARY_SOURCES="clear;files,$VCPKG_BINARY_CACHE,readwrite"

  if [[ -n "${NUGET_FEED_URL:-}" || -n "${NUGET_CONFIG_PATH:-}" || -n "${NUGET_SOURCE_NAME:-}" ]]; then
    [[ -n "${NUGET_FEED_URL:-}" ]] || die "NUGET_FEED_URL is required when NuGet cache is configured"
    [[ -n "${NUGET_CONFIG_PATH:-}" ]] || die "NUGET_CONFIG_PATH is required when NuGet cache is configured"
    [[ -n "${NUGET_SOURCE_NAME:-}" ]] || die "NUGET_SOURCE_NAME is required when NuGet cache is configured"

    nuget_mode="${NUGET_CACHE_MODE:-read}"
    case "$nuget_mode" in
      read|readwrite) ;;
      *) die "unsupported NUGET_CACHE_MODE: $nuget_mode" ;;
    esac

    VCPKG_BINARY_SOURCES="$VCPKG_BINARY_SOURCES;nugetconfig,$NUGET_CONFIG_PATH,$nuget_mode"
  fi

  export VCPKG_BINARY_SOURCES
}

configure_vcpkg_binary_sources
configure_nuget_source
echo "VCPKG_BINARY_SOURCES=$VCPKG_BINARY_SOURCES"

exec "${VCPKG_ROOT}/vcpkg" install \
  "$@" \
  --triplet arm64-osx-static \
  --overlay-ports "${BUILDER_DIR}/cmake/ports-overlay" \
  --overlay-triplets "${BUILDER_DIR}/cmake/triplets" \
  --x-install-root "${VCPKG_INSTALLED_DIR}" \
  --clean-after-build \
  --recurse \
  --allow-unsupported \
  --keep-going
