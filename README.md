# mpv macOS build

This repository builds a macOS arm64 `mpv.app` with GitHub Actions.

The workflow checks out `mpv-player/mpv`, runs a CMake superbuild for third-party
dependencies, builds and uploads a static source-built FFmpeg artifact, then
builds and bundles mpv on GitHub's `macos-15` runner. Local compilation is
intentionally not required.

## Usage

Run the workflow manually:

```sh
gh workflow run mpv.yml \
  --repo z8kh8E6t-rEv62qT7/mpv-macbuild \
  --ref master \
  -f mpv_ref=latest \
  -f ffmpeg_ref=latest \
  -f run_ffmpeg_fate=false
```

Set `run_ffmpeg_fate=true` to run the full upstream FATE suite sequentially
against both the GPLv3+nonfree and LGPL FFmpeg profiles. FATE is diagnostic:
sample synchronization, setup, test, or result-collection failures emit
warnings and are recorded in the job summary and full audit artifact, but do
not block the later mpv build, GitHub Release publishing, or NuGet maintenance.

Watch the newest run:

```sh
run_id="$(gh run list \
  --repo z8kh8E6t-rEv62qT7/mpv-macbuild \
  --workflow mpv.yml \
  --branch master \
  --limit 1 \
  --json databaseId \
  --jq '.[0].databaseId')"

gh run watch "$run_id" \
  --repo z8kh8E6t-rEv62qT7/mpv-macbuild \
  --exit-status \
  --compact
```

If a run fails:

```sh
gh run view "$run_id" \
  --repo z8kh8E6t-rEv62qT7/mpv-macbuild \
  --log-failed
```

Release behavior:

- Every `push` to `master` runs the full macOS build.
- `workflow_dispatch` runs the full build, enables NuGet writeback, and
  publishes or updates a GitHub Release. NuGet expiration defaults to
  `dry-run`; select `delete` explicitly to remove expired packages.
- A `push` only publishes or updates a GitHub Release when the head commit
  message contains `[release]`; these release pushes automatically delete
  expired NuGet packages after a successful write-enabled source build.

## Workflow structure

- `params` runs on `ubuntu-latest` and resolves source refs, NuGet mode, and
  release metadata.
- `build` runs on `macos-15` and keeps source deps, FFmpeg, and mpv
  build/test/bundle on the same runner so the temp prefixes stay local. Inside
  the job, `Build source` finishes vcpkg/custom static deps, `Build FFmpeg`
  creates the FFmpeg install prefix, and the FFmpeg Actions artifact is uploaded
  before its clean-runtime smoke test, runtime dependency audit, optional
  non-blocking FATE runs for both FFmpeg profiles, and the later mpv
  configure/build/test/bundle steps. The mpv Actions artifact is also uploaded
  before bundle runtime audit. Package retention audit runs after both artifact
  upload points.
- `publish-release` runs on `ubuntu-latest` only after a successful release
  build and uploads the two final tarballs to the GitHub Release identified by
  `mpv-<mpv-ref>-ffmpeg-<ffmpeg-ref>-macos15-arm64`.
- `maintain-nuget-cache` runs on `ubuntu-latest` after source deps succeeded
  and NuGet writes were enabled. It reports or deletes repository-linked
  GitHub Packages NuGet packages whose `updated_at` timestamp is more than 30
  days old, but does not block the release pipeline if maintenance fails.

## Build model

- `mpv_ref=latest` resolves to the latest GitHub release from `mpv-player/mpv`.
- `ffmpeg_ref=latest` resolves to the latest FFmpeg release tag, such as
  `n8.1.1`; FFmpeg is not built from `master` by default.
- Homebrew installs build tools only: LLVM/lld, CMake, Ninja, Meson, pkgconf,
  autotools, libtool, nasm, Rust/cargo-c, Python, mono, git, curl, and
  related build helpers.
- Third-party media/runtime libraries are source-built into
  `$RUNNER_TEMP/source-prefix`; FFmpeg installs into
  `$RUNNER_TEMP/ffmpeg-prefix`; Homebrew library formula paths are excluded from
  `PKG_CONFIG_LIBDIR`, `CMAKE_PREFIX_PATH`, and target include/library search
  paths.
- The CMake superbuild under `cmake/` uses vcpkg with a static
  `arm64-osx-static` triplet for broad package coverage, with repo-local
  overlay ports under `cmake/ports-overlay/` for macOS-specific fixes, then
  builds custom source packages for dyphire/mpv-specific needs.
- vcpkg itself is pinned to commit
  `56bb2411609227288b70117ead2c47585ba07713`, so official port recipes do not
  float with `microsoft/vcpkg` `master`.
- vcpkg binary packages are cached through GitHub Actions' cache service using
  a filesystem binary cache at `$RUNNER_TEMP/vcpkg-binary-cache`. The workflow
  restores the newest matching cache before the vcpkg build and saves it after
  that step even when later source dependency compilation fails, so successful
  vcpkg ports can be reused by the next run. This Actions cache remains a
  best-effort accelerator; the workflow does not add a separate keep-alive job
  or guarantee long-term retention beyond GitHub's normal cache policy.
- The workflow also exposes a GitHub Packages NuGet cache for vcpkg:
  ordinary `push` runs read from NuGet only, while `workflow_dispatch` and
  `push` commits tagged with `[release]` enable `readwrite` mode so vcpkg can
  publish back into the NuGet cache. NuGet network operations use a 300-second
  timeout so large binary packages are not limited by vcpkg's 100-second
  default.
- NuGet maintenance uses a strict 30-day TTL for individual package versions,
  measured from each version's immutable `created_at` timestamp. The manual
  workflow defaults to reporting expired versions without deleting them, while
  a manually selected `delete` action and `[release]` pushes remove every
  expired version. No newest-version exemption is applied, so a package
  disappears when its final version expires.
- GitHub Packages does not expose a last-download timestamp through this API.
  Consuming a cached version therefore does not refresh its TTL.
- Actions cache and NuGet cache are intentionally treated differently:
  `actions/cache` speeds up rebuilds when available, while GitHub Packages
  NuGet is the persistence layer this workflow explicitly maintains.
- vcpkg runs with `--keep-going` and custom source dependencies are built in
  dependency-safe parallel batches, so one run can surface multiple independent
  failures. Per-package logs are written under `audit/logs/`, and the workflow
  prints a diagnostics dump on failure.
- CI build orchestration stays in Bash, while package-retention policy and
  audit tables live in `scripts/lib/ci_matrix.py` and
  `scripts/audit/audit_packages.py`.
- Source-built C/C++ uses Homebrew LLVM with thin LTO, PIC, and M4-only CPU
  tuning:
  `-flto=thin -O3 -pipe -fPIC -march=armv8.7-a -mcpu=apple-m4 -mtune=apple-m4`.
  The artifact targets Apple M4 or newer Macs and uses
  `MACOSX_DEPLOYMENT_TARGET=15.0`.
- FFmpeg is built as a stripped release binary while keeping O3, thin LTO,
  `-fstrict-aliasing`, `ld64.lld`, `-Wl,--dead-strip-duplicates`,
  `-Wl,-headerpad_max_install_names`, and all enabled features.
- Homebrew LLVM runtime libraries are intentionally retained: `compiler-rt`
  through the LLVM resource dir and `libc++`, `libc++abi`, and `libunwind`
  through the LLVM runtime library directories. The mpv app bundle carries
  copies of the LLVM C++ runtime dylibs in `Contents/Frameworks`; other
  Homebrew runtime dylibs are not allowed in FFmpeg or mpv artifacts.
- Compile and link flags are split deliberately: C/ObjC compile probes do not
  receive C++ or link-only flags such as `-stdlib=libc++` or
  `--unwindlib=libunwind`; those stay in the C++ or linker flag buckets.
- Cargo's `aarch64-apple-darwin` linker is set to the same Homebrew LLVM clang,
  and Rust builds receive matching `rustc` flags for O3, thin LTO, Apple M4
  CPU tuning, PIC, LLVM tuning args, and link paths so crates with C build
  scripts do not fall back to Apple `cc` for LLVM bitcode.
- `-march=armv8.7-a` is used as LLVM's closest architecture baseline for
  Apple M4; `-march=apple-m4` is intentionally omitted because clang rejects
  that spelling on arm64 Darwin.
- `-fno-exceptions -fno-rtti` are scoped to mpv/FFmpeg C++ flags only, not
  global third-party dependency builds.
- The GPLv3+nonfree FFmpeg build is configured with `--enable-shared`, `--enable-static`,
  `--pkg-config-flags=--static`, `--enable-pic`, VideoToolbox, AudioToolbox,
  OpenCL, Vulkan, and the retained codec/filter extensions; mpv Meson uses
  `-Dprefer_static=true`.
- Apple system libraries, Apple frameworks, and the precise Homebrew LLVM
  runtime dylibs may remain dynamic. `libiconv` uses Apple's system library on
  macOS; mpv Meson receives explicit iconv link flags because the pinned vcpkg
  `libiconv` port is an empty wrapper on this target. LuaSocket, VapourSynth,
  and frei0r are source-built plugin/runtime exceptions; VapourSynth keeps
  `libvsscript.dylib` dynamic but rewrites it to `@rpath` for FFmpeg and mpv.
- The FFmpeg command-line package intentionally carries the seven shared
  FFmpeg libraries. Vulkan-loader and MoltenVK remain the non-plugin
  third-party runtime exceptions and are bundled where required.
- FFmpeg is configured with `--enable-nonfree` for `libfdk-aac`.

Custom source-built and overlay-managed components include:

- `libdovi` from `quietvoid/dovi_tool` HEAD, installed as the C API package
  `dovi`.
- `libdovi`, `rav1e`, and the overlay-managed `librsvg` are Rust `staticlib`
  C API packages. After all three are installed, CI weakens only their
  overlapping Rust runtime symbols so FFmpeg can link libplacebo/libdovi,
  `--enable-librav1e`, and `--enable-librsvg` together without hiding any
  public C API.
- `Vulkan-Headers` from `vulkan-sdk-1.4.350.0`, installed into the source
  prefix with the matching CMake package config and Vulkan registry files.
- `Vulkan-Loader` from `vulkan-sdk-1.4.350.0`, built as the bundled Vulkan
  loader runtime for macOS against the source-built matching headers.
- `MoltenVK` from HEAD, used both as a source-built static input and bundled
  runtime component.
- `libass` remains dyphire-aligned through a repo-local vcpkg overlay that
  tracks `rcombs/libass` `threading`, keeps the subtitle parsing patch, and
  links against the repo-local `libunibreak` vcpkg overlay.
- `libplacebo` from HEAD with Vulkan, shaderc, LCMS, dovi, and libdovi enabled,
  plus dyphire-aligned cherry-picks of upstream MR !850 and !852 while those
  merge requests remain open.
- `davs2` from `saindriches/davs2`, matching dyphire's 10-bit-capable source,
  with a macOS arm64 endian-probe patch for LTO builds.
- `uavs3d` HEAD with 10-bit enabled.
- `libzvbi`, `zimg`, `libbs2b`, `libcaca`, `libcdio`, `libcdio-paranoia`,
  `rav1e`, `libvidstab`, `kvazaar`, `frei0r`, and VapourSynth.
  `libcdio-paranoia` is patched to build the libraries and pkg-config files
  only; the unrelated `cd-paranoia` CLI is not part of the FFmpeg dependency
  surface.
- `vvenc` now comes from a repo-local vcpkg overlay that keeps the build on
  `1.7.0`, disables x86 SIMD on arm64, and installs only the library pieces
  FFmpeg needs.
- `libmysofa` now comes from the pinned vcpkg registry rather than a separate
  source-prefix build.
- `libunibreak` now comes from a repo-local vcpkg overlay that preserves the
  pinned registry source version while installing pkg-config metadata for the
  libass overlay and CI audit.
- `libiconv` uses Apple's system `libiconv` on macOS. mpv keeps `iconv`
  enabled with explicit Meson-stage link flags, and FFmpeg keeps
  `--enable-iconv`.
- FFmpeg latest release, linked against static vcpkg and source-built
  dependencies.
- Dyphire source behavior patches for libass subtitles, FFmpeg ASS/subtitle
  probing, and TrueHD SPDIF timing.

Vulkan compile-time headers and registry files now come from the source prefix,
not from the vcpkg static prefix.

Artifacts:

- `mpv-<mpv-ref>-ffmpeg-<ffmpeg-ref>-static-nonfree-macos-15-arm64`:
  compressed `mpv.app`.
- `ffmpeg-gplv3-nonfree-macos15-arm64.tar.xz`: GPLv3+nonfree FFmpeg package
  rooted at `ffmpeg-gplv3-nonfree/`. It includes the three command-line tools,
  seven shared FFmpeg libraries, headers, relocatable pkg-config files, and
  their runtime closure; static archives remain internal for the mpv build.
- `ffmpeg-lgpl-macos15-arm64.tar.xz`: strict LGPL FFmpeg package rooted at
  `ffmpeg-lgpl/`, with only the `ffmpeg` command-line executable, the same
  shared-library layout, and mandatory JXL/SVG decoding through libjxl and
  librsvg 2.62.3. The workflow uploads both FFmpeg Actions artifacts immediately
  after `Build FFmpeg`, then extracts and smoke-tests both delivered tarballs in
  a clean dyld environment before auditing runtime dependencies. Both profiles
  exercise common built-in codecs plus real JXL encode/decode and SVG decode;
  the GPLv3+nonfree profile additionally runs the x264 default-encoding
  regression matrix so AArch64 assembly/runtime issues are caught before mpv
  starts. Later smoke, audit, or mpv failures do not remove the FFmpeg tarballs
  from the run.
- `package-audit-<mpv-ref>-<ffmpeg-ref>`: package and feature audit.
- `full-audit-<mpv-ref>-<ffmpeg-ref>`: package audit plus FFmpeg and bundle
  `otool` data; when FATE is enabled, it also contains the combined FATE
  summary, per-profile command logs, and complete failing-test lists.

## Dyphire alignment

The macOS workflow ports dyphire's source-level behavior patches where they
apply cleanly:

- libass: parse `ScriptType:` even when `[Script Info]` is missing.
- libplacebo: apply upstream MR !850 for PQ/HDR metadata black-level handling
  and MR !852 for HDR linear scaling behavior while both MRs remain open.
- FFmpeg subtitles: broader ASS probing, UTF-16 double-BOM handling, and
  preserved negative ASS event durations.
- FFmpeg SPDIF: tolerate long TrueHD `input_timing` gaps.
- FFmpeg/libvmaf close symbol hygiene: internal parser/feature callbacks named
  `close` are renamed so ld64.lld/Thin-LTO cannot bind POSIX `close(fd)` to a
  local static callback. This keeps optimization, LTO, linker, and feature
  settings unchanged.
- FFmpeg extensions: `libfdk-aac`, `frei0r`, `libvidstab`, `libgme`,
  `chromaprint`, `libcaca`, `libcdio`, `libopenjpeg`, `libopenh264`,
  `libkvazaar`, `libsnappy`, `librtmp`, `libtheora`, `libvmaf`, `librsvg`,
  `libvvenc`, OpenCL, VideoToolbox, AudioToolbox, macOS kperf, and Vulkan
  support are enabled and audited.

Windows build-tool patches are intentionally not restored. The old package
rename patch, Windows OpenSSL winstore patch, AMF/CUDA/NVENC/VPL paths, and
Windows ANGLE behavior do not apply to this macOS arm64 target. VideoToolbox
stays enabled on macOS.

## Information about packages

The original Windows package list is preserved as a macOS retention audit. Each
macOS-capable third-party package is source-built static, source-built as an
explicit plugin exception, mapped to Apple system functionality, or marked not
applicable.

| Package | macOS retention | Notes |
| --- | --- | --- |
| mpv | Source | Checked out from `mpv-player/mpv` at `mpv_ref`; linked with static third-party deps where possible. |
| FFmpeg | Source static + shared | The GPLv3+nonfree profile keeps static archives internally for mpv while its command-line tools link the seven shared FFmpeg libraries. The independent public LGPL profile is shared-only. |
| libass | vcpkg overlay static | Repo-local overlay keeps `rcombs/libass` `threading` plus the dyphire subtitle patch while moving the package onto the vcpkg cache path. |
| libplacebo | Source static | Built from HEAD with Vulkan, shaderc, LCMS, dovi, and libdovi enabled, plus temporary upstream MR !850/!852 cherry-picks for dyphire alignment. |
| vulkan-header | Source static/header | `Vulkan-Headers` is source-built from the same SDK tag as `Vulkan-Loader` and installed into the source prefix. |
| vulkan | Source runtime exception/Apple dynamic boundary | Source-built Vulkan headers, loader, and registry are aligned on the same SDK tag; the loader and MoltenVK runtime are bundled, and FFmpeg/mpv hard-enable Vulkan without `--enable-vulkan-static`. |
| ANGLE | Mapped | macOS uses Cocoa/OpenGL plus Vulkan/MoltenVK; Win32 ANGLE is not claimed. |
| aom | Source static/FFmpeg | Audited as `--enable-libaom`. |
| xz | Source static/FFmpeg | Audited as `--enable-lzma`. |
| x264 | vcpkg overlay static/FFmpeg | Audited as `--enable-libx264`; overlay preserves AArch64 NEON, MB-tree, lookahead, and default asm while fixing strict-aliasing preallocation, MB-tree tail/index bounds, and AArch64 CAVLC coefficient level-run mask/zero-block handling. |
| x265 (multilib) | Source static mapped | macOS arm64 static source build is retained; Windows multilib does not apply. |
| uchardet | Source static/mpv | mpv `uchardet` is forced on. |
| rubberband | Source static/mpv/FFmpeg | mpv and FFmpeg support are audited. |
| opus | Source static/FFmpeg | Audited as `--enable-libopus`. |
| ogg | Source static | Retained through Vorbis/codec dependency chain. |
| openal-soft | Source static/mpv/FFmpeg | mpv `openal` and FFmpeg `openal` are audited. |
| luajit | Source static/mpv | mpv uses `-Dlua=luajit`; LuaJIT is built without LTO so protected Lua errors keep unwinding correctly, while its validation host still exports Lua C API symbols for LuaSocket dynamic modules. |
| libvpx | Source static/FFmpeg | Audited as `--enable-libvpx`. |
| luasocket | Source plugin exception | Built from source through LuaRocks against source-built LuaJIT and bundled as a runtime module. |
| libwebp | Source static/FFmpeg | Audited as `--enable-libwebp`. |
| libpng | Source static | Retained for image/font/video dependency chain. |
| libsdl2 | Source static/mpv/FFmpeg | mpv SDL features and FFmpeg `--enable-sdl2` are audited. |
| libsoxr | Source static/FFmpeg | Audited as `--enable-libsoxr`. |
| libzimg | Source static/mpv/FFmpeg | mpv and FFmpeg support are audited. |
| libdvdread | Source static/FFmpeg | Used by DVD stack. |
| libdvdnav | Source static/mpv/FFmpeg | mpv `dvdnav` and FFmpeg support are audited. |
| libdvdcss | Source static | Retained for DVD stack coverage. |
| libudfread | Source static | Used by `libbluray`. |
| libbluray | Source static/mpv/FFmpeg | mpv and FFmpeg support are audited. |
| libunibreak | vcpkg overlay static | Repo-local overlay preserves the pinned registry source version and provides pkg-config metadata used by the libass overlay. |
| libmysofa | vcpkg static/FFmpeg | Provided by the pinned vcpkg registry and audited as `--enable-libmysofa`. |
| lcms2 | Source static/mpv/FFmpeg | mpv and FFmpeg support are audited. |
| lame | Source static/FFmpeg | Audited as `--enable-libmp3lame`. |
| fdk-aac | Source static nonfree | Audited as `--enable-libfdk-aac` and `--enable-nonfree`. |
| frei0r | Source plugin exception/FFmpeg | Source-built plugin files are allowed as explicit runtime exception; Cairo modules link static private deps such as pixman. |
| harfbuzz | Source static | Provided by vcpkg and used by the libass overlay plus FFmpeg. |
| game-music-emu | Source static/FFmpeg | Audited as `--enable-libgme`. |
| freetype2 | Source static | Provided by vcpkg and used by libass and FFmpeg. |
| mujs | Source static/mpv | Used by mpv JavaScript support. |
| libarchive | Source static/mpv | mpv `libarchive` is forced on. |
| libjpeg | Source static/mpv | `jpeg-turbo` source package backs mpv `jpeg`. |
| shaderc | Source static/FFmpeg/libplacebo | Source-built in the static prefix and used by libplacebo/FFmpeg. |
| speex | Source static/FFmpeg | Audited as `--enable-libspeex`. |
| spirv-cross | Source static | Retained for shader/Vulkan package coverage. |
| fribidi | Source static | Provided by vcpkg and used by the libass overlay plus FFmpeg. |
| libxml2 | Source static/FFmpeg | Audited as `--enable-libxml2`. |
| chromaprint | Source static/FFmpeg | Audited as `--enable-chromaprint`. |
| libcaca | Source static/mpv/FFmpeg | mpv `caca` and FFmpeg `--enable-libcaca` are audited. |
| libcdio | Source static/FFmpeg | FFmpeg CDIO support is audited as `--enable-libcdio`; configure is given explicit iconv cache values for macOS static builds, and `libcdio-paranoia` is patched to skip the unneeded CLI build. |
| opencl | Apple system dynamic/FFmpeg | Audited as `--enable-opencl`; uses Apple's OpenCL framework boundary. |
| openjpeg | Source static/FFmpeg | Audited as `--enable-libopenjpeg`. |
| openh264 | Source static/FFmpeg | Audited as `--enable-libopenh264`. |
| kvazaar | Source static/FFmpeg | Built from `ultravideo/kvazaar`; audited as `--enable-libkvazaar`. |
| snappy | Source static/FFmpeg | Audited as `--enable-libsnappy`. |
| librtmp | Source static/FFmpeg | Audited as `--enable-librtmp`. |
| libtheora | Source static/FFmpeg | Audited as `--enable-libtheora`. |
| libvmaf | vcpkg overlay static/FFmpeg | Audited as `--enable-libvmaf`; overlay keeps vcpkg `3.1.0` while renaming internal `close` callbacks to avoid local `_close` symbol collisions. |
| librsvg | Source static/FFmpeg | Audited as `--enable-librsvg`. |
| libvvenc | vcpkg overlay static/FFmpeg | Repo-local overlay keeps `1.7.0`, disables x86 SIMD on arm64, and provides the FFmpeg-facing library artifacts. |
| VideoToolbox | Apple system dynamic/FFmpeg/mpv | FFmpeg and mpv VideoToolbox paths are enabled and audited. |
| AudioToolbox | Apple system dynamic/FFmpeg | FFmpeg AudioToolbox support is enabled and audited. |
| amf-headers | Not applicable | AMD AMF is Windows-specific here; macOS uses VideoToolbox. |
| avisynth-headers | Mapped | VapourSynth is source-built and required instead. |
| nvcodec-headers | Not applicable | NVIDIA NVENC/NVDEC headers are not a macOS arm64 target. |
| libvpl | Not applicable | Intel VPL/QSV is not the macOS arm64 target path. |
| bzip2 | Source static/FFmpeg | Audited as `--enable-bzlib`. |
| dav1d | Source static/FFmpeg | Audited as `--enable-libdav1d`. |
| expat | Source static | Used by XML/font dependency chain. |
| fontconfig | Source static | Retained for broader package coverage even though the macOS libass overlay uses CoreText. |
| libbs2b | Source static/FFmpeg | Audited as `--enable-libbs2b`; command-line tools needing `libsndfile` are not built. |
| libssh | Source static/FFmpeg | Audited as `--enable-libssh`. |
| libsrt | Source static/FFmpeg | Audited as `--enable-libsrt`. |
| libjxl | Source static/FFmpeg | Audited as `--enable-libjxl`. |
| libmodplug | Source static/FFmpeg | Audited as `--enable-libmodplug`. |
| libvidstab | Source static/FFmpeg | Audited as `--enable-libvidstab`. |
| uavs3d | Source static/FFmpeg | Built from HEAD with 10-bit enabled; audited as `--enable-libuavs3d`. |
| davs2 | Source static/FFmpeg | Built from dyphire-aligned `saindriches/davs2` with 10-bit enabled and the macOS arm64 endian-probe patch; audited as `--enable-libdavs2`. |
| libdovi | Source static via libplacebo | Built from `dovi_tool`; mpv and FFmpeg do not link it directly. |
| libzvbi | Source static/FFmpeg | Built from HEAD and audited as `--enable-libzvbi`. |
| rav1e | Source static/FFmpeg | Audited as `--enable-librav1e`. |
| libaribcaption | Source static/FFmpeg | Audited as `--enable-libaribcaption`. |
| zlib | Source static/mpv/FFmpeg | mpv and FFmpeg zlib support are audited. |
| zstd | Source static | Retained as `libzstd`. |
| xvidcore | Source static/FFmpeg | Audited as `--enable-libxvid`. |
| lzo | Source static | Retained for archive/compression coverage. |
| libopenmpt | Source static/FFmpeg | Audited as `--enable-libopenmpt`. |
| libiconv | Apple system dynamic/mpv/FFmpeg | mpv `iconv` gets explicit Meson-stage link flags on macOS; FFmpeg `--enable-iconv` remains audited. |
| vapoursynth | Source plugin exception/mpv/FFmpeg | Source-built runtime/API exception; `libvsscript.dylib` stays dynamic and is published through rpath. |

## Verification policy

Local checks are limited to non-build validation:

```sh
find scripts cmake/scripts -name '*.sh' -print0 | xargs -0 -n1 bash -n
find scripts -name '*.py' -print0 | xargs -0 python3 -m py_compile
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/mpv.yml")'
cmake -S cmake -B /tmp/mpv-macbuild-superbuild-check \
  -DBUILDER_DIR="$PWD" \
  -DSOURCE_PREFIX=/tmp/mpv-macbuild-prefix \
  -DFFMPEG_PREFIX=/tmp/mpv-macbuild-ffmpeg-prefix \
  -DSOURCE_ROOT=/tmp/mpv-macbuild-src \
  -DBUILD_ROOT=/tmp/mpv-macbuild-build \
  -DAUDIT_DIR=/tmp/mpv-macbuild-audit \
  -DFFMPEG_REF=n8.1.1
git diff --check
rg -n "mpv-[w]in|[w]inbuild|[m]ingw|[m]svc|libmpv-2\\.[d]ll|[f]fmpeg-full|--[w]error|--disable-[v]ideotoolbox" .github cmake README.md
rg -n -- "--overlay-ports" .github cmake README.md
rg -n -- "--enable-vulkan-static" .github cmake && false
rg -n -- "-[m]arch=native|-[m]tune=native|-[m]cpu=native|-[f]lto=full" .github cmake README.md
rg -n -- "-march=armv8.7-a|-mcpu=apple-m4|-mtune=apple-m4|-flto=thin|-fPIC|-fveclib=Accelerate|-Wl,-dead_strip" .github cmake README.md
rg -n -- "--enable-pic|--enable-opencl|--enable-libvmaf|--enable-libvvenc|--enable-macos-kperf|--enable-audiotoolbox|ffmpeg-prefix" .github cmake README.md
```

Compilation, tests, bundling, static link auditing, and artifact verification
happen in GitHub Actions.
