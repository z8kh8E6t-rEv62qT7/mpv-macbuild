#!/usr/bin/env python3
"""Check the exact public SDK surface, allowing only the bundled compiler runtime."""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
libs = {"avcodec", "avfilter", "avformat", "avutil", "swscale"}
expected_pc = {f"lib{name}.pc" for name in libs}
expected_headers = {f"lib{name}" for name in libs}
for directory, expected in ((root / "include", expected_headers), (root / "lib/pkgconfig", expected_pc)):
    actual = {path.name for path in directory.iterdir()}
    if actual != expected:
        raise SystemExit(f"unexpected SDK layout in {directory}: {sorted(actual ^ expected)}")
pattern = re.compile(r"lib(?:" + "|".join(sorted(libs)) + r")(?:\.[0-9]+)*\.dylib$")
for path in (root / "lib").iterdir():
    if path.name == "pkgconfig" or pattern.fullmatch(path.name):
        continue
    if path.name not in {"libc++.1.dylib", "libc++abi.1.dylib", "libunwind.1.dylib"}:
        raise SystemExit(f"unexpected LGPL library: {path.name}")
for path in root.rglob("*"):
    if path.is_symlink() and (not path.exists() or not path.resolve().is_relative_to(root.resolve())):
        raise SystemExit(f"broken or escaping artifact symlink: {path}")
print("LGPL artifact layout: PASS")
