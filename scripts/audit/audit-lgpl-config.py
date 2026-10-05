#!/usr/bin/env python3
"""Fail closed when configure drops a required image component or widens the profile."""
import pathlib
import re
import sys

build = pathlib.Path(sys.argv[1])


def read_config(name):
    return dict(re.findall(r"^#define CONFIG_(\w+) ([01])$", (build / name).read_text(), re.M))


config = read_config("config.h")
# Internal features such as FRAME_THREAD_ENCODER are not registered components.
components = read_config("config_components.h")


def exact_components(kind, expected):
    actual = {key.removesuffix("_" + kind).lower() for key, value in components.items()
              if key.endswith("_" + kind) and value == "1"}
    if actual != expected:
        raise SystemExit(f"{kind}: missing={sorted(expected - actual)}, unexpected={sorted(actual - expected)}")


# WebP's native decoder selects VP8; it is an intentional implementation dependency.
exact_components("DECODER", set(sys.argv[2].split(",")) | {"vp8"})
exact_components("PARSER", set(sys.argv[3].split(",")))
exact_components("DEMUXER", set(sys.argv[4].split(",")))
exact_components("ENCODER", {"rawvideo"})
exact_components("MUXER", {"rawvideo"})
exact_components("PROTOCOL", {"file"})
exact_components("HWACCEL", set())
exact_components("INDEV", set())
exact_components("OUTDEV", set())
exact_components("FILTER", {"aformat", "anull", "atrim", "crop", "format", "hflip", "null",
                            "rotate", "transpose", "trim", "vflip", "scale"})
for name in ("GPL", "VERSION3", "NONFREE", "NETWORK", "AVDEVICE", "SWRESAMPLE", "FFPROBE", "FFPLAY",
             "LIBJXL", "LIBRSVG", "LIBAOM", "LIBWEBP", "BZLIB", "ICONV", "VIDEOTOOLBOX", "AUDIOTOOLBOX"):
    if config.get(name) != "0":
        raise SystemExit(f"CONFIG_{name} must be disabled")
for name in ("AVCODEC", "AVFORMAT", "AVUTIL", "SWSCALE", "AVFILTER", "FFMPEG", "ZLIB", "LZMA", "LIBDAV1D"):
    if config.get(name) != "1":
        raise SystemExit(f"CONFIG_{name} must be enabled")
print("LGPL image configuration: PASS")
