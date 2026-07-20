#!/usr/bin/env bash
set -euo pipefail

real_rustc="${MPV_REAL_RUSTC:-}"
diagnostic_log="${MPV_RUSTC_DIAGNOSTIC_LOG:-}"
rustc_args=("$@")

if [[ -z "$real_rustc" ]]; then
  echo "error: MPV_REAL_RUSTC is not set" >&2
  exit 126
fi
if [[ ! -x "$real_rustc" ]]; then
  echo "error: MPV_REAL_RUSTC is not executable: $real_rustc" >&2
  exit 126
fi
if [[ "$real_rustc" -ef "$0" ]]; then
  echo "error: MPV_REAL_RUSTC resolves to the diagnostic wrapper" >&2
  exit 126
fi

is_cfg_probe=0
is_macos_arm64_target=0
previous_arg=""
for arg in "${rustc_args[@]}"; do
  if [[ "$previous_arg" == "--print" && "$arg" == "cfg" ]]; then
    is_cfg_probe=1
  fi
  if [[ "$previous_arg" == "--target" && "$arg" == "aarch64-apple-darwin" ]]; then
    is_macos_arm64_target=1
  fi
  case "$arg" in
    --print=cfg)
      is_cfg_probe=1
      ;;
    --target=aarch64-apple-darwin)
      is_macos_arm64_target=1
      ;;
  esac
  previous_arg="$arg"
done

if [[ "$is_cfg_probe" != 1 || "$is_macos_arm64_target" != 1 ]]; then
  exec "$real_rustc" "${rustc_args[@]}"
fi

if [[ -z "$diagnostic_log" ]]; then
  echo "error: MPV_RUSTC_DIAGNOSTIC_LOG is not set" >&2
  exit 126
fi

probe_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mpv-rustc-probe.XXXXXX")"
probe_stdout="$probe_temp_dir/stdout"
probe_stderr="$probe_temp_dir/stderr"

cleanup() {
  rm -f "$probe_stdout" "$probe_stderr"
  rmdir "$probe_temp_dir" 2>/dev/null || true
}
trap cleanup EXIT

set +e
"$real_rustc" "${rustc_args[@]}" >"$probe_stdout" 2>"$probe_stderr"
probe_status=$?
set -e

[[ ! -s "$probe_stdout" ]] || /bin/cat "$probe_stdout"
[[ ! -s "$probe_stderr" ]] || /bin/cat "$probe_stderr" >&2

if [[ "$probe_status" == 0 ]]; then
  exit 0
fi

diagnostic_dir="$(dirname "$diagnostic_log")"
diagnostic_temp="$diagnostic_log.tmp.$$"
write_diagnostic() {
  mkdir -p "$diagnostic_dir" || return 1
  {
    printf 'rustc target probe failure\n'
    printf 'timestamp_utc: '
    date -u '+%Y-%m-%dT%H:%M:%SZ'
    printf 'exit_status: %d\n' "$probe_status"
    printf 'cwd: %s\n' "$PWD"
    printf 'wrapper: %s\n' "$0"
    printf 'real_rustc: %s\n' "$real_rustc"
    printf 'arguments:\n'
    arg_index=0
    for arg in "${rustc_args[@]}"; do
      printf '  argv[%d]=%q\n' "$arg_index" "$arg"
      arg_index=$((arg_index + 1))
    done

    printf '\nselected_environment:\n'
    selected_environment=(
      PATH
      TMPDIR
      SDKROOT
      DEVELOPER_DIR
      MACOSX_DEPLOYMENT_TARGET
      DYLD_LIBRARY_PATH
      DYLD_FALLBACK_LIBRARY_PATH
      DYLD_FRAMEWORK_PATH
      DYLD_FALLBACK_FRAMEWORK_PATH
      LIBRARY_PATH
      LD_LIBRARY_PATH
      CARGO
      CARGO_HOME
      CARGO_ENCODED_RUSTFLAGS
      CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS
      RUSTC
      MPV_REAL_RUSTC
      RUSTFLAGS
      RUSTUP_HOME
      RUSTUP_TOOLCHAIN
    )
    for name in "${selected_environment[@]}"; do
      printf '  %s=%q\n' "$name" "${!name-}"
    done

    printf '\nsystem:\n'
    uname -a || true
    sw_vers || true
    xcode-select -p || true
    ulimit -a || true

    printf '\nreal_rustc_file:\n'
    file "$real_rustc" || true
    printf '\nreal_rustc_dependencies:\n'
    otool -L "$real_rustc" || true
    printf '\nreal_rustc_load_commands:\n'
    otool -l "$real_rustc" || true

    printf '\nstdout:\n'
    /bin/cat "$probe_stdout"
    printf '\nstderr:\n'
    /bin/cat "$probe_stderr"
  } >"$diagnostic_temp" 2>&1 || return 1

  mv -f "$diagnostic_temp" "$diagnostic_log" || return 1
}

if ! write_diagnostic; then
  rm -f "$diagnostic_temp" 2>/dev/null || true
  echo "warning: failed to publish rustc diagnostic log: $diagnostic_log" >&2
fi

exit "$probe_status"
