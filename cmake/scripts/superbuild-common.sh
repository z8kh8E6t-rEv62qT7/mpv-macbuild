#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

init_superbuild_environment() {
  require_build_environment superbuild

  export PKG_CONFIG_PATH=
  export PKG_CONFIG_LIBDIR="${FFMPEG_PREFIX}/lib/pkgconfig:${FFMPEG_PREFIX}/share/pkgconfig:${SOURCE_PREFIX}/lib/pkgconfig:${SOURCE_PREFIX}/share/pkgconfig:${VCPKG_TARGET_PREFIX}/lib/pkgconfig:${VCPKG_TARGET_PREFIX}/share/pkgconfig"
  export CMAKE_PREFIX_PATH="${FFMPEG_PREFIX};${SOURCE_PREFIX};${VCPKG_TARGET_PREFIX}"
  export CPATH="${FFMPEG_PREFIX}/include:${SOURCE_PREFIX}/include:${VCPKG_TARGET_PREFIX}/include${CPATH:+:$CPATH}"
  export LIBRARY_PATH="${FFMPEG_PREFIX}/lib:${SOURCE_PREFIX}/lib:${VCPKG_TARGET_PREFIX}/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
  export CPPFLAGS="-I${FFMPEG_PREFIX}/include -I${SOURCE_PREFIX}/include -I${VCPKG_TARGET_PREFIX}/include ${CPPFLAGS:-}"
  export LDFLAGS="${SOURCE_LDFLAGS} -L${FFMPEG_PREFIX}/lib -L${SOURCE_PREFIX}/lib -L${VCPKG_TARGET_PREFIX}/lib"
  export PKG_CONFIG_ALL_STATIC=1

  mkdir -p "$SOURCE_PREFIX" "$FFMPEG_PREFIX" "$SOURCE_PREFIX/lib/pkgconfig" "$SOURCE_PREFIX/share/pkgconfig" "$FFMPEG_PREFIX/lib/pkgconfig" "$FFMPEG_PREFIX/share/pkgconfig" "$SOURCE_ROOT" "$BUILD_ROOT"
}

run_parallel_batch() {
  local batch="$1"
  shift
  local max_jobs="${SOURCE_DEP_PARALLELISM:-4}"
  local -a pids=()
  local -a titles=()
  local -a logs=()
  local -a failed_titles=()
  local -a failed_logs=()
  local failures=0

  wait_first_job() {
    local pid="${pids[0]}"
    local title="${titles[0]}"
    local log_path="${logs[0]}"

    if wait "$pid"; then
      echo "OK: $title (log: $log_path)"
    else
      echo "::error title=$title::failed; see $log_path"
      failed_titles+=("$title")
      failed_logs+=("$log_path")
      failures=$((failures + 1))
    fi

    pids=("${pids[@]:1}")
    titles=("${titles[@]:1}")
    logs=("${logs[@]:1}")
  }

  ci_group "parallel batch: $batch"
  while [[ "$#" -gt 0 ]]; do
    local title="$1"
    local function_name="$2"
    local log_path
    shift 2

    while [[ "${#pids[@]}" -ge "$max_jobs" ]]; do
      wait_first_job
    done

    log_path="$(log_path_for_title "$title")"
    echo "START: $title (log: $log_path)"
    CI_PARALLEL_CHILD=1 run_logged_to_file "$title" "$function_name" &
    pids+=("$!")
    titles+=("$title")
    logs+=("$log_path")
  done

  while [[ "${#pids[@]}" -gt 0 ]]; do
    wait_first_job
  done

  if [[ "$failures" -gt 0 ]]; then
    local idx
    for idx in "${!failed_titles[@]}"; do
      ci_group "failed log: ${failed_titles[$idx]}"
      cat "${failed_logs[$idx]}" || true
      ci_endgroup
    done
  fi
  ci_endgroup

  [[ "$failures" -eq 0 ]]
}

clone_or_update() {
  local repo="$1"
  local dest="$2"
  local ref="${3:-}"

  if [[ ! -d "$dest/.git" ]]; then
    git clone --depth 1 "$repo" "$dest"
  fi

  if [[ -n "$ref" ]]; then
    git -C "$dest" fetch --depth 1 origin "$ref"
    git -C "$dest" checkout --detach FETCH_HEAD
  fi
}

run_autogen_if_present() {
  local src="$1"

  if [[ -x "$src/autogen.sh" ]]; then
    (cd "$src" && ./autogen.sh)
  elif [[ -x "$src/bootstrap" ]]; then
    (cd "$src" && ./bootstrap)
  elif [[ -f "$src/configure.ac" || -f "$src/configure.in" ]]; then
    (cd "$src" && autoreconf -fi)
  fi
}

configure_make_install_static() {
  local src="$1"
  shift

  run_autogen_if_present "$src"
  (
    cd "$src"
    ./configure \
      --prefix="$SOURCE_PREFIX" \
      --disable-shared \
      --enable-static \
      "$@"
    make -j"$(ci_jobs)"
    make install
  )
}

meson_static_install() {
  local src="$1"
  local build="$2"
  shift 2

  meson setup "$build" "$src" \
    --prefix="$SOURCE_PREFIX" \
    --buildtype=release \
    --default-library=static \
    -Db_lto=true \
    -Dprefer_static=true \
    --wrap-mode=nodownload \
    "$@"
  meson compile -C "$build"
  meson install -C "$build"
}

cmake_static_configure() {
  local src="$1"
  local build="$2"
  shift 2

  cmake -S "$src" -B "$build" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$SOURCE_PREFIX" \
    -DCMAKE_PREFIX_PATH="$CMAKE_PREFIX_PATH" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_AR="$AR" \
    -DCMAKE_RANLIB="$RANLIB" \
    -DCMAKE_NM="$NM" \
    -DCMAKE_STRIP="$STRIP" \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DCMAKE_C_FLAGS="$CFLAGS" \
    -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
    -DCMAKE_MODULE_LINKER_FLAGS="$LDFLAGS" \
    -DBUILD_SHARED_LIBS=OFF \
    "$@"
}

cmake_static_install() {
  local src="$1"
  local build="$2"
  shift 2

  cmake_static_configure "$src" "$build" "$@"
  cmake --build "$build"
  cmake --install "$build"
}

remove_dynamic_artifacts() {
  find "$SOURCE_PREFIX/lib" -maxdepth 1 \( -name '*.dylib' -o -name '*.so' \) \
    ! -name 'libvulkan*.dylib' \
    ! -name 'libMoltenVK*.dylib' \
    -print -delete 2>/dev/null || true
}
