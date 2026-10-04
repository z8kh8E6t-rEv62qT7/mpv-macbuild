#!/usr/bin/env bash
set -euo pipefail

root="$1"
work="$2"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Compile only in the artifact smoke job, using the extracted SDK exclusively.
export PKG_CONFIG_PATH=""
export PKG_CONFIG_LIBDIR="$root/lib/pkgconfig"
unset PKG_CONFIG_ALL_STATIC CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH CPPFLAGS LDFLAGS
read -r -a sdk_cflags <<< "$(pkg-config --cflags libavformat libavcodec libavutil libswscale libavfilter)"
read -r -a sdk_libs <<< "$(pkg-config --libs libavformat libavcodec libavutil libswscale libavfilter)"
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror "${sdk_cflags[@]}" \
  "$script_dir/lgpl-image-consumer.c" "${sdk_libs[@]}" \
  "-Wl,-rpath,$root/lib" -o "$work/lgpl-image-consumer"
