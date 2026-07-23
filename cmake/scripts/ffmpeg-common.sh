#!/usr/bin/env bash

fix_ffmpeg_configure_probes() {
  local configure_script="$1"

  python3 - "$configure_script" <<'PY'
import pathlib
import sys

configure_path = pathlib.Path(sys.argv[1])
text = configure_path.read_text()
replacements = {
    '''enabled libopenmpt        && require_pkg_config libopenmpt "libopenmpt >= 0.2.6557" libopenmpt/libopenmpt.h openmpt_module_create -lstdc++ && append libopenmpt_extralibs "-lstdc++"''':
    '''enabled libopenmpt        && require_pkg_config libopenmpt "libopenmpt >= 0.2.6557" libopenmpt/libopenmpt.h openmpt_module_create -lc++ && append libopenmpt_extralibs "-lc++"''',
    '''enabled librubberband     && require_pkg_config librubberband "rubberband >= 1.8.1" rubberband/rubberband-c.h rubberband_new -lstdc++ && append librubberband_extralibs "-lstdc++"''':
    '''enabled librubberband     && require_pkg_config librubberband "rubberband >= 1.8.1" rubberband/rubberband-c.h rubberband_new -lc++ && append librubberband_extralibs "-lc++"''',
    '''enabled libsnappy         && require libsnappy snappy-c.h snappy_compress -lsnappy -lstdc++''':
    '''enabled libsnappy         && require libsnappy snappy-c.h snappy_compress -lsnappy -lc++''',
}

for old, new in replacements.items():
    if old not in text:
        raise SystemExit("FFmpeg configure C++ stdlib probe did not match the expected form")
    text = text.replace(old, new, 1)
configure_path.write_text(text)
PY
}
