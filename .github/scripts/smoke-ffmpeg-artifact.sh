#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_source_env

ffmpeg_bin="$FFMPEG_PREFIX/bin/ffmpeg"
[[ -x "$ffmpeg_bin" ]] || die "missing executable FFmpeg tool: $ffmpeg_bin"

mkdir -p "$AUDIT_DIR/logs" "$AUDIT_DIR/crash-reports"

summary="$AUDIT_DIR/ffmpeg-smoke-summary.md"
runtime_report="$AUDIT_DIR/ffmpeg-smoke-runtime.txt"
smoke_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ffmpeg-smoke.XXXXXX")"
crash_marker="$smoke_dir/crash-marker"
failures=0

cleanup() {
  rm -rf "$smoke_dir"
}
trap cleanup EXIT

touch "$crash_marker"

format_command() {
  local part

  printf '%q' "$ffmpeg_bin"
  for part in "$@"; do
    printf ' %q' "$part"
  done
}

run_ffmpeg_clean() {
  env \
    -u DYLD_FRAMEWORK_PATH \
    -u DYLD_FALLBACK_FRAMEWORK_PATH \
    -u DYLD_FALLBACK_LIBRARY_PATH \
    -u DYLD_LIBRARY_PATH \
    "$ffmpeg_bin" "$@"
}

write_runtime_report() {
  {
    echo "# FFmpeg Smoke Runtime"
    echo
    echo "generated_utc: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "ffmpeg: $ffmpeg_bin"
    echo "prefix: $FFMPEG_PREFIX"
    echo
    echo "## file"
    file "$ffmpeg_bin" "$FFMPEG_PREFIX/bin/ffprobe" "$FFMPEG_PREFIX/bin/ffplay" 2>&1 || true
    echo
    echo "## otool -L ffmpeg"
    otool -L "$ffmpeg_bin" 2>&1 || true
    echo
    echo "## Vulkan runtime files"
    find "$FFMPEG_PREFIX/lib" -maxdepth 1 \( -name 'libvulkan*.dylib' -o -name 'libMoltenVK*.dylib' \) -exec ls -l {} + 2>&1 || true
    echo
    echo "## FFmpeg load command identity"
    otool -l "$ffmpeg_bin" 2>&1 | awk '
      /cmd LC_UUID/ || /cmd LC_BUILD_VERSION/ || /cmd LC_RPATH/ {
        print
        capture = 1
        next
      }
      capture && /^Load command/ {
        capture = 0
      }
      capture {
        print
      }
    ' || true
  } > "$runtime_report"
}

init_summary() {
  {
    echo "# FFmpeg Smoke Summary"
    echo
    echo "- ffmpeg: \`$ffmpeg_bin\`"
    echo "- smoke dir: \`$smoke_dir\`"
    echo "- clean dyld: \`DYLD_FRAMEWORK_PATH\`, \`DYLD_FALLBACK_FRAMEWORK_PATH\`, \`DYLD_FALLBACK_LIBRARY_PATH\`, and \`DYLD_LIBRARY_PATH\` unset"
    echo
    echo "| Case | Exit | Output | Command |"
    echo "| --- | ---: | --- | --- |"
  } > "$summary"
}

append_summary_note() {
  {
    echo
    echo "$1"
  } >> "$summary"
}

run_case() {
  local slug="$1"
  local output_path="$2"
  shift 2
  local status=0
  local command_text
  local output_state="n/a"
  local output_ok=0
  local output_size

  command_text="$(format_command "$@")"

  if run_logged "ffmpeg-smoke-$slug" run_ffmpeg_clean "$@"; then
    status=0
  else
    status=$?
  fi

  if [[ -n "$output_path" ]]; then
    if [[ -s "$output_path" ]]; then
      output_size="$(wc -c < "$output_path" | tr -d '[:space:]')"
      output_state="nonempty (${output_size} bytes)"
      output_ok=1
    else
      output_state="missing or empty"
    fi
  else
    output_ok=1
  fi

  printf '| `%s` | `%s` | `%s` | `%s` |\n' \
    "$slug" "$status" "$output_state" "$command_text" >> "$summary"

  if [[ "$status" -ne 0 || "$output_ok" -ne 1 ]]; then
    failures=$((failures + 1))
  fi
}

symbolize_crash_report() {
  local report="$1"
  local output="$2"

  python3 - "$ffmpeg_bin" "$report" "$output" <<'PY'
import json
import pathlib
import subprocess
import sys

ffmpeg_bin = pathlib.Path(sys.argv[1])
report_path = pathlib.Path(sys.argv[2])
output_path = pathlib.Path(sys.argv[3])

def write_note(message):
    output_path.write_text(message + "\n", encoding="utf-8")

try:
    with report_path.open("r", encoding="utf-8", errors="replace") as fh:
        fh.readline()
        report = json.load(fh)
except Exception as exc:
    write_note(f"unable to parse macOS crash report as ips JSON: {exc}")
    raise SystemExit(0)

used_images = report.get("usedImages", [])
threads = report.get("threads", [])
faulting_thread_index = report.get("faultingThread")

ffmpeg_image_index = None
for index, image in enumerate(used_images):
    name = image.get("name", "")
    path = image.get("path", "")
    if name.startswith("ffmpeg") or pathlib.PurePosixPath(path).name.startswith("ffmpeg"):
        ffmpeg_image_index = index
        break

if ffmpeg_image_index is None:
    write_note("unable to find ffmpeg image in crash report")
    raise SystemExit(0)

ffmpeg_image = used_images[ffmpeg_image_index]
base = int(ffmpeg_image.get("base", 0))
arch = ffmpeg_image.get("arch", "arm64")
nm_symbols = []

try:
    nm_output = subprocess.run(
        ["nm", "-n", str(ffmpeg_bin)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    ).stdout
except Exception:
    nm_output = ""

for line in nm_output.splitlines():
    parts = line.split(maxsplit=2)
    if len(parts) < 3:
        continue
    try:
        address = int(parts[0], 16)
    except ValueError:
        continue
    nm_symbols.append((address, parts[2]))

def nearest_nm_symbol(offset):
    # Mach-O executable symbols are normally reported at the default vmaddr
    # base plus the crash report image offset. This is only a fallback for
    # stripped atos output, so keep it best-effort.
    linked_address = 0x100000000 + offset
    best = None
    for address, name in nm_symbols:
        if address <= linked_address:
            best = (address, name)
        else:
            break
    if best is None:
        return "nm nearest unavailable"
    address, name = best
    return f"{name}+0x{linked_address - address:x}"

def symbolize(address, offset):
    if not ffmpeg_bin.exists():
        return "ffmpeg binary missing"
    try:
        completed = subprocess.run(
            [
                "atos",
                "-o",
                str(ffmpeg_bin),
                "-arch",
                arch,
                "-l",
                hex(base),
                hex(address),
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    except Exception as exc:
        return f"atos unavailable: {exc}"
    atos_output = completed.stdout.strip() or "atos produced no output"
    nm_output = nearest_nm_symbol(offset)
    return f"atos={atos_output}; nm={nm_output}"

lines = [
    "# Symbolized FFmpeg Crash Report",
    "",
    f"report: {report_path}",
    f"binary: {ffmpeg_bin}",
    f"image_name: {ffmpeg_image.get('name', '')}",
    f"image_uuid: {ffmpeg_image.get('uuid', '')}",
    f"image_arch: {arch}",
    f"image_base: {hex(base)}",
    f"faulting_thread: {faulting_thread_index}",
    f"exception: {report.get('exception', {})}",
    f"termination: {report.get('termination', {})}",
    "",
]

for thread_index, thread in enumerate(threads):
    triggered = thread.get("triggered", False)
    if thread_index != faulting_thread_index and not triggered:
        continue
    lines.append(f"## Thread {thread_index}")
    for frame_index, frame in enumerate(thread.get("frames", [])):
        if frame.get("imageIndex") != ffmpeg_image_index:
            symbol = frame.get("symbol", "")
            image_index = frame.get("imageIndex", "")
            lines.append(f"- frame {frame_index}: non-ffmpeg image={image_index} symbol={symbol}")
            continue
        offset = int(frame.get("imageOffset", 0))
        address = base + offset
        lines.append(
            f"- frame {frame_index}: offset={hex(offset)} addr={hex(address)} symbol={symbolize(address, offset)}"
        )
    lines.append("")

output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

collect_crash_reports() {
  local diagnostic_dir="$HOME/Library/Logs/DiagnosticReports"
  local copied=0
  local report
  local dest

  # macOS crash reports are produced asynchronously; give ReportCrash a moment.
  sleep 2

  if [[ ! -d "$diagnostic_dir" ]]; then
    append_summary_note "Crash reports: diagnostic directory not found: \`$diagnostic_dir\`"
    return
  fi

  while IFS= read -r report; do
    dest="$AUDIT_DIR/crash-reports/$(basename "$report")"
    cp "$report" "$dest"
    symbolize_crash_report "$dest" "${dest}.symbolized.txt" || true
    copied=$((copied + 1))
  done < <(find "$diagnostic_dir" -type f -newer "$crash_marker" \( -name 'ffmpeg*.ips' -o -name 'ffmpeg*.crash' \) | sort)

  if [[ "$copied" -eq 0 ]]; then
    append_summary_note "Crash reports: none found for this smoke run."
  else
    append_summary_note "Crash reports: copied ${copied} report(s) into \`crash-reports/\`."
  fi
}

collect_symbol_diagnostics() {
  local script_dir
  local diagnostics_script

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  diagnostics_script="$script_dir/diagnose-ffmpeg-symbols.sh"

  if [[ ! -x "$diagnostics_script" ]]; then
    append_summary_note "Symbol diagnostics: script not executable: \`$diagnostics_script\`"
    return
  fi

  if run_logged "ffmpeg-symbol-diagnostics" "$diagnostics_script" "$ffmpeg_bin"; then
    append_summary_note "Symbol diagnostics: wrote \`ffmpeg-symbol-diagnostics.txt\`."
  else
    append_summary_note "Symbol diagnostics: failed; see \`logs/ffmpeg-symbol-diagnostics.log\`."
  fi
}

write_runtime_report
init_summary

audio_flac="$smoke_dir/audio.flac"
audio_wav="$smoke_dir/audio.wav"
video_mkv="$smoke_dir/video.mkv"
video_ffv1_mkv="$smoke_dir/video-ffv1.mkv"
testsrc_hd="testsrc=duration=2:size=1280x720"
testsrc_x264_boundary="testsrc=duration=2:size=128x128:rate=25"
testsrc_x264_yuv420p="testsrc=duration=2:size=128x128:rate=25,format=yuv420p"

run_case "hwaccels" "" -hide_banner -hwaccels
run_case "lavfi-sine-null" "" -v error -y -f lavfi -i sine=frequency=1000:duration=2 -f null -
run_case "lavfi-sine-flac" "$audio_flac" -v error -y -f lavfi -i sine=frequency=1000:duration=2 "$audio_flac"
run_case "lavfi-sine-pcm-wav" "$audio_wav" -v error -y -f lavfi -i sine=frequency=1000:duration=2 -c:a pcm_s16le "$audio_wav"
run_case "lavfi-testsrc-null" "" -v error -y -f lavfi -i "$testsrc_hd" -f null -
run_case "lavfi-testsrc-ffv1-mkv" "$video_ffv1_mkv" -v error -y -f lavfi -i "$testsrc_x264_boundary" -c:v ffv1 "$video_ffv1_mkv"
run_case "lavfi-testsrc-mkv" "$video_mkv" -v error -y -f lavfi -i "$testsrc_hd" "$video_mkv"

# x264 regression cases keep the default libx264 path under the same clean dyld
# smoke gate as the rest of the FFmpeg artifact.
run_case "x264-default-null" "" -v error -y -f lavfi -i "$testsrc_x264_boundary" -c:v libx264 -f null -
run_case "x264-yuv420p-null" "" -v error -y -f lavfi -i "$testsrc_x264_yuv420p" -c:v libx264 -f null -
run_case "x264-frames1-null" "" -v error -y -f lavfi -i "$testsrc_x264_boundary" -c:v libx264 -frames:v 1 -f null -
run_case "x264-tune-zerolatency-null" "" -v error -y -f lavfi -i "$testsrc_x264_boundary" -c:v libx264 -tune zerolatency -f null -
run_case "x264-rc-lookahead0-null" "" -v error -y -f lavfi -i "$testsrc_x264_boundary" -c:v libx264 -x264-params rc-lookahead=0 -f null -
run_case "x264-rc-lookahead1-null" "" -v error -y -f lavfi -i "$testsrc_x264_boundary" -c:v libx264 -x264-params rc-lookahead=1 -f null -
run_case "x264-sync-lookahead0-null" "" -v error -y -f lavfi -i "$testsrc_x264_boundary" -c:v libx264 -x264-params sync-lookahead=0 -f null -
run_case "x264-mbtree0-null" "" -v error -y -f lavfi -i "$testsrc_x264_boundary" -c:v libx264 -x264-params mbtree=0 -f null -
run_case "x264-asm0-null" "" -v error -y -f lavfi -i "$testsrc_x264_boundary" -c:v libx264 -x264-params asm=0 -f null -
run_case "x264-bframes0-null" "" -v error -y -f lavfi -i "$testsrc_x264_boundary" -c:v libx264 -x264-params bframes=0 -f null -
run_case "x264-threads1-null" "" -v error -y -f lavfi -i "$testsrc_x264_boundary" -c:v libx264 -x264-params threads=1 -f null -
run_case "x264-sliced-threads1-null" "" -v error -y -f lavfi -i "$testsrc_x264_boundary" -c:v libx264 -x264-params sliced-threads=1 -f null -
run_case "x264-scenecut0-null" "" -v error -y -f lavfi -i "$testsrc_x264_boundary" -c:v libx264 -x264-params scenecut=0 -f null -
run_case "x264-ref1-null" "" -v error -y -f lavfi -i "$testsrc_x264_boundary" -c:v libx264 -x264-params ref=1 -f null -
run_case "x264-subme0-null" "" -v error -y -f lavfi -i "$testsrc_x264_boundary" -c:v libx264 -x264-params subme=0 -f null -
run_case "x264-aq-mode0-null" "" -v error -y -f lavfi -i "$testsrc_x264_boundary" -c:v libx264 -x264-params aq-mode=0 -f null -
run_case "x264-cabac0-null" "" -v error -y -f lavfi -i "$testsrc_x264_boundary" -c:v libx264 -x264-params cabac=0 -f null -
run_case "x264-trellis0-null" "" -v error -y -f lavfi -i "$testsrc_x264_boundary" -c:v libx264 -x264-params trellis=0 -f null -
run_case "x264-8x8dct0-null" "" -v error -y -f lavfi -i "$testsrc_x264_boundary" -c:v libx264 -x264-params 8x8dct=0 -f null -

collect_crash_reports

if [[ "$failures" -ne 0 ]]; then
  collect_symbol_diagnostics
  append_summary_note "Result: FAIL (${failures} failing smoke case(s))."
  die "FFmpeg smoke failed; see $summary and $AUDIT_DIR/crash-reports"
fi

append_summary_note "Result: PASS."
