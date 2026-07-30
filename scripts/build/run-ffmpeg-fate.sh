#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

require_source_env
require_github_file GITHUB_STEP_SUMMARY

samples_dir="${FFMPEG_FATE_SAMPLES:-${FATE_SAMPLES:-$BUILD_ROOT/fate-suite}}"
frei0r_source_dir="$SOURCE_PREFIX/lib/frei0r-1"
frei0r_fate_dir="$BUILD_ROOT/ffmpeg-fate/frei0r-1"
summary="$AUDIT_DIR/ffmpeg-fate-summary.md"
failure_preview_limit=10
last_command_status=0
sample_sync_status=0

profile_names=()
profile_results=()
profile_setup_statuses=()
profile_clear_statuses=()
profile_fate_statuses=()
profile_list_statuses=()
profile_failure_counts=()
profile_failure_lists=()
profile_fate_logs=()

resolve_fate_jobs() {
  local jobs

  if [[ -n "${FFMPEG_FATE_JOBS:-}" ]]; then
    printf '%s\n' "$FFMPEG_FATE_JOBS"
    return
  fi

  if jobs="$(ci_jobs 2>/dev/null)" && [[ -n "$jobs" ]]; then
    printf '%s\n' "$jobs"
    return
  fi

  printf '8\n'
}

emit_warning() {
  local title="$1"
  local message="$2"

  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    printf '::warning title=%s::%s\n' "$title" "$message"
  else
    printf 'warning: %s: %s\n' "$title" "$message" >&2
  fi
}

run_nonblocking() {
  local title="$1"
  shift

  if run_logged "$title" "$@"; then
    last_command_status=0
  else
    last_command_status=$?
  fi
}

validate_profile_source() {
  local profile="$1"
  local source_dir="$2"

  if [[ ! -d "$source_dir" ]]; then
    echo "error: $profile FFmpeg source directory does not exist: $source_dir" >&2
    return 1
  fi
  if [[ ! -f "$source_dir/ffbuild/config.mak" ]]; then
    echo "error: $profile FFmpeg source tree is not configured: $source_dir" >&2
    return 1
  fi
}

prepare_frei0r_fate_plugins() {
  local plugin
  local alias
  local count=0

  if [[ ! -d "$frei0r_source_dir" ]]; then
    echo "error: missing frei0r plugin directory: $frei0r_source_dir" >&2
    return 1
  fi

  rm -rf "$frei0r_fate_dir"
  mkdir -p "$frei0r_fate_dir"

  shopt -s nullglob
  for plugin in "$frei0r_source_dir"/*.so; do
    alias="$frei0r_fate_dir/$(basename "${plugin%.so}").dylib"
    ln -s "$plugin" "$alias"
    count=$((count + 1))
  done
  shopt -u nullglob

  if [[ "$count" -eq 0 ]]; then
    echo "error: no frei0r .so plugins found in $frei0r_source_dir" >&2
    return 1
  fi
}

execute_fate_profile() {
  local source_dir="$1"
  local install_prefix="$2"
  local use_frei0r="$3"
  local jobs="$4"
  local dyld_library_path="$SOURCE_PREFIX/lib:$install_prefix/lib"

  if [[ -n "${DYLD_LIBRARY_PATH:-}" ]]; then
    dyld_library_path="$dyld_library_path:$DYLD_LIBRARY_PATH"
  fi

  if [[ "$use_frei0r" == "true" ]]; then
    env \
      DYLD_LIBRARY_PATH="$dyld_library_path" \
      FREI0R_PATH="$frei0r_fate_dir" \
      make -C "$source_dir" -j"$jobs" fate "SAMPLES=$samples_dir"
  else
    env \
      DYLD_LIBRARY_PATH="$dyld_library_path" \
      FREI0R_PATH="" \
      make -C "$source_dir" -j"$jobs" fate "SAMPLES=$samples_dir"
  fi
}

capture_failing_tests() {
  local source_dir="$1"
  local failure_list="$2"

  make --no-print-directory -s -C "$source_dir" \
    fate-list-failing "SAMPLES=$samples_dir" \
    | awk 'NF' \
    | tee "$failure_list"
}

count_nonempty_lines() {
  local path="$1"

  awk 'NF { count += 1 } END { print count + 0 }' "$path"
}

record_profile_result() {
  local profile="$1"
  local result="$2"
  local setup_status="$3"
  local clear_status="$4"
  local fate_status="$5"
  local list_status="$6"
  local failure_count="$7"
  local failure_list="$8"
  local fate_log="$9"
  local index="${#profile_names[@]}"

  profile_names[index]="$profile"
  profile_results[index]="$result"
  profile_setup_statuses[index]="$setup_status"
  profile_clear_statuses[index]="$clear_status"
  profile_fate_statuses[index]="$fate_status"
  profile_list_statuses[index]="$list_status"
  profile_failure_counts[index]="$failure_count"
  profile_failure_lists[index]="$failure_list"
  profile_fate_logs[index]="$fate_log"
}

run_fate_profile() {
  local profile="$1"
  local source_dir="$2"
  local install_prefix="$3"
  local use_frei0r="$4"
  local jobs="$5"
  local setup_status=0
  local clear_status
  local fate_status
  local list_status
  local failure_count
  local result="passed"
  local failure_list="$AUDIT_DIR/ffmpeg-fate-$profile-failures.txt"
  local fate_log="$AUDIT_DIR/logs/ffmpeg-fate-$profile.log"

  run_nonblocking "ffmpeg-fate-$profile-validate" \
    validate_profile_source "$profile" "$source_dir"
  setup_status="$last_command_status"

  if [[ "$use_frei0r" == "true" ]]; then
    run_nonblocking "ffmpeg-fate-$profile-prepare-frei0r" \
      prepare_frei0r_fate_plugins
    if [[ "$last_command_status" -ne 0 && "$setup_status" -eq 0 ]]; then
      setup_status="$last_command_status"
    fi
  fi

  run_nonblocking "ffmpeg-fate-$profile-clear-reports" \
    make -C "$source_dir" fate-clear-reports "SAMPLES=$samples_dir"
  clear_status="$last_command_status"

  run_nonblocking "ffmpeg-fate-$profile" \
    execute_fate_profile "$source_dir" "$install_prefix" "$use_frei0r" "$jobs"
  fate_status="$last_command_status"

  : > "$failure_list"
  run_nonblocking "ffmpeg-fate-$profile-list-failing" \
    capture_failing_tests "$source_dir" "$failure_list"
  list_status="$last_command_status"
  failure_count="$(count_nonempty_lines "$failure_list")"

  if [[ "$setup_status" -ne 0
    || "$clear_status" -ne 0
    || "$fate_status" -ne 0
    || "$list_status" -ne 0 ]]; then
    result="warning"
    emit_warning \
      "FFmpeg FATE $profile" \
      "Diagnostic FATE run did not pass; setup=$setup_status, clear=$clear_status, fate=$fate_status, list=$list_status, failed_tests=$failure_count. Release and NuGet maintenance remain unblocked."
  fi

  record_profile_result \
    "$profile" \
    "$result" \
    "$setup_status" \
    "$clear_status" \
    "$fate_status" \
    "$list_status" \
    "$failure_count" \
    "$failure_list" \
    "$fate_log"
}

write_fate_summary() {
  local jobs="$1"
  local index
  local shown
  local failure
  local remaining

  {
    echo "# FFmpeg FATE Summary"
    echo
    echo "- policy: diagnostic only; FATE results do not gate mpv, release publishing, or NuGet maintenance"
    echo "- samples: \`$samples_dir\`"
    echo "- jobs: \`$jobs\`"
    echo "- shared sample sync exit code: \`$sample_sync_status\`"
    echo
    echo "| Profile | Result | Setup | Clear reports | FATE | Failure scan | Failed tests |"
    echo "| --- | --- | ---: | ---: | ---: | ---: | ---: |"
    for ((index = 0; index < ${#profile_names[@]}; index += 1)); do
      printf '| `%s` | %s | `%s` | `%s` | `%s` | `%s` | %s |\n' \
        "${profile_names[$index]}" \
        "${profile_results[$index]}" \
        "${profile_setup_statuses[$index]}" \
        "${profile_clear_statuses[$index]}" \
        "${profile_fate_statuses[$index]}" \
        "${profile_list_statuses[$index]}" \
        "${profile_failure_counts[$index]}"
    done

    for ((index = 0; index < ${#profile_names[@]}; index += 1)); do
      echo
      echo "## ${profile_names[$index]} diagnostics"
      echo
      echo "- FATE log: \`${profile_fate_logs[$index]}\`"
      echo "- complete failing-test list: \`${profile_failure_lists[$index]}\`"
      echo "- failed tests: ${profile_failure_counts[$index]}"

      if [[ "${profile_failure_counts[$index]}" -gt 0 ]]; then
        echo
        echo "First $failure_preview_limit failing tests:"
        echo
        shown=0
        while IFS= read -r failure; do
          [[ -n "$failure" ]] || continue
          printf -- '- `%s`\n' "$failure"
          shown=$((shown + 1))
          [[ "$shown" -ge "$failure_preview_limit" ]] && break
        done < "${profile_failure_lists[$index]}"

        remaining=$((
          ${profile_failure_counts[$index]} - shown
        ))
        if [[ "$remaining" -gt 0 ]]; then
          echo "- ... and $remaining more in the complete failing-test list"
        fi
      elif [[ "${profile_results[$index]}" != "passed" ]]; then
        echo "- no failing test names were reported; inspect the setup, FATE, and failure-scan logs"
      fi
    done
  } > "$summary"

  cat "$summary" >> "$GITHUB_STEP_SUMMARY"
}

jobs="$(resolve_fate_jobs)"

mkdir -p "$samples_dir" "$AUDIT_DIR/logs"

run_nonblocking "ffmpeg-fate-rsync" \
  make -C "$SOURCE_ROOT/ffmpeg" fate-rsync "SAMPLES=$samples_dir"
sample_sync_status="$last_command_status"
if [[ "$sample_sync_status" -ne 0 ]]; then
  emit_warning \
    "FFmpeg FATE sample sync" \
    "Shared FATE sample synchronization failed with exit code $sample_sync_status. Both profiles will still be attempted, and release and NuGet maintenance remain unblocked."
fi

run_fate_profile \
  "gplv3-nonfree" \
  "$SOURCE_ROOT/ffmpeg" \
  "$FFMPEG_PREFIX" \
  "true" \
  "$jobs"
run_fate_profile \
  "lgpl" \
  "$SOURCE_ROOT/ffmpeg-lgpl" \
  "$FFMPEG_LGPL_PREFIX" \
  "false" \
  "$jobs"

write_fate_summary "$jobs"

exit 0
