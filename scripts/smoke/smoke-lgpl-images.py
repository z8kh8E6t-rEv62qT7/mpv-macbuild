#!/usr/bin/env python3
"""Exercise the delivered image CLI and custom-AVIO consumer without external codecs."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys


def verify_rgba(path, case):
    data = path.read_bytes()
    expected_size = case["width"] * case["height"] * 4 * case["frames"]
    if len(data) != expected_size:
        raise ValueError(f"RGBA size {len(data)} != {expected_size} ({case['frames']} frames)")
    for sample in case["pixels"]:
        offset = ((sample["frame"] * case["height"] + sample["y"]) * case["width"] + sample["x"]) * 4
        actual = data[offset:offset + 4]
        if any(abs(a - b) > case["tolerance"] for a, b in zip(actual, sample["rgba"])):
            raise ValueError(f"pixel {sample}: got {list(actual)}")


def main():
    ffmpeg, fixtures, work, summary = map(Path, sys.argv[1:5])
    consumer = Path(sys.argv[5]) if len(sys.argv) == 6 else None
    work.mkdir(parents=True, exist_ok=True)
    cases = json.loads((fixtures / "manifest.json").read_text())
    env = {key: value for key, value in os.environ.items() if not key.startswith("DYLD_")}
    failures = []

    def run(name, command, check):
        log = work / f"{name}.log"
        print("$ " + shlex.join(str(arg) for arg in command), flush=True)
        try:
            result = subprocess.run([str(arg) for arg in command], env=env, timeout=30,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            log.write_text(result.stdout)
            print(result.stdout, end="", flush=True)
            if result.returncode < 0:
                raise ValueError(f"terminated by signal {-result.returncode}")
            check(result)
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            failures.append(name)
            with log.open("a") as output:
                output.write(f"\nFAIL: {error}\n")
            outcome = f"FAIL: {error}"
        else:
            outcome = "PASS"
        print(f"{name}: {outcome}", flush=True)
        with summary.open("a") as output:
            output.write(f"\n- {name}: {outcome}\n")

    def decode_command(source, output):
        return [ffmpeg, "-nostdin", "-hide_banner", "-v", "info", "-xerror", "-y", "-i", source,
                "-map", "0:v:0", "-an", "-sn", "-dn", "-fps_mode", "passthrough",
                "-pix_fmt", "rgba", "-c:v", "rawvideo", "-f", "rawvideo", output]

    for case in cases:
        source = fixtures / case["file"]
        if hashlib.sha256(source.read_bytes()).hexdigest() != case["sha256"]:
            raise ValueError(f"fixture checksum mismatch: {source}")
        output = work / f"{source.name}.rgba"

        def check_cli(result):
            if result.returncode:
                raise ValueError(f"decode exited {result.returncode}")
            # Inspect the output stream, not the input's advertised dimensions.
            output_info = result.stdout.partition("Output #0,")[2]
            dimensions = rf"Video: rawvideo[^\n]*\b{case['width']}x{case['height']}\b"
            if not re.search(dimensions, output_info):
                raise ValueError("missing expected rawvideo output dimensions")
            verify_rgba(output, case)

        run(source.name, decode_command(source, output), check_cli)
        if consumer:
            memory_output = work / f"{source.name}.avio.rgba"

            def check_consumer(result):
                if result.returncode:
                    raise ValueError(f"custom AVIO exited {result.returncode}")
                if f"{case['width']} {case['height']} {case['frames']}" not in result.stdout.splitlines():
                    raise ValueError("unexpected custom AVIO dimensions/frame count")
                verify_rgba(memory_output, case)

            run(f"{source.name}-avio", [consumer, source, memory_output], check_consumer)

    def must_fail(result):
        if result.returncode == 0:
            raise ValueError("unsupported or corrupt input unexpectedly succeeded")

    for filename, content in (("truncated.png", b"\x89PNG\r\n\x1a\n"),
                              ("corrupt.png", b"not an image"),
                              ("unsupported.svg", b'<svg xmlns="http://www.w3.org/2000/svg"/>')):
        source = work / filename
        source.write_bytes(content)
        run(filename, decode_command(source, work / f"{filename}.rgba"), must_fail)
        if consumer:
            run(f"{filename}-avio", [consumer, source, work / f"{filename}.avio.rgba"], must_fail)

    def check_protocols(result):
        if result.returncode or result.stdout.split().count("file") != 2:
            raise ValueError("missing file input/output protocol")
        protocols = result.stdout.partition("Input:")[2]
        if set(protocols.replace("Output:", "").split()) != {"file"}:
            raise ValueError("unexpected enabled protocol")

    run("protocols", [ffmpeg, "-hide_banner", "-protocols"], check_protocols)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
