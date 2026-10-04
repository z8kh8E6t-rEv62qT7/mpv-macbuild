#!/usr/bin/env bash

build_davs2() {
  local davs2_patch="$BUILDER_DIR/patch/davs2-0001-skip-lto-sensitive-endian-probe-on-macos-arm64.patch"

  clone_or_update https://github.com/saindriches/davs2.git "$SOURCE_ROOT/davs2"
  git -C "$SOURCE_ROOT/davs2" apply --check "$davs2_patch"
  git -C "$SOURCE_ROOT/davs2" apply "$davs2_patch"
  (
    cd "$SOURCE_ROOT/davs2/build/linux"
    CC="$CXX" \
    CFLAGS="$CXXFLAGS" \
    CXXFLAGS="$CXXFLAGS" \
    LDFLAGS="$LDFLAGS" \
      ./configure \
        --prefix="$SOURCE_PREFIX" \
        --disable-cli \
        --bit-depth=10
    make -j"$(ci_jobs)"
    make install
  )
  remove_dynamic_artifacts
  pkg-config --exists davs2
}

build_uavs3d() {
  clone_or_update https://github.com/uavs3/uavs3d.git "$SOURCE_ROOT/uavs3d"
  cmake_static_install "$SOURCE_ROOT/uavs3d" "$BUILD_ROOT/uavs3d" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCOMPILE_10BIT=1
  remove_dynamic_artifacts
  pkg-config --exists uavs3d
}

build_libzvbi() {
  clone_or_update https://github.com/zapping-vbi/zvbi.git "$SOURCE_ROOT/zvbi"
  configure_make_install_static "$SOURCE_ROOT/zvbi" \
    --disable-dvb \
    --without-doxygen
  remove_dynamic_artifacts
  pkg-config --exists zvbi-0.2
}

build_zimg() {
  clone_or_update https://github.com/sekrit-twc/zimg.git "$SOURCE_ROOT/zimg"
  git -C "$SOURCE_ROOT/zimg" submodule update --init --recursive
  configure_make_install_static "$SOURCE_ROOT/zimg"
  remove_dynamic_artifacts
  pkg-config --exists zimg
}

build_game_music_emu() {
  clone_or_update https://github.com/libgme/game-music-emu.git "$SOURCE_ROOT/game-music-emu"
  cmake_static_install "$SOURCE_ROOT/game-music-emu" "$BUILD_ROOT/game-music-emu" \
    -DENABLE_UBSAN=OFF
  remove_dynamic_artifacts
  pkg-config --exists libgme || pkg-config --exists gme
}

build_libbs2b() {
  clone_or_update https://github.com/alexmarsev/libbs2b.git "$SOURCE_ROOT/libbs2b"
  local libbs2b_patch="$BUILDER_DIR/patch/libbs2b-0001-build-library-without-sndfile-tools.patch"
  git -C "$SOURCE_ROOT/libbs2b" apply --check "$libbs2b_patch"
  git -C "$SOURCE_ROOT/libbs2b" apply "$libbs2b_patch"
  configure_make_install_static "$SOURCE_ROOT/libbs2b"
  remove_dynamic_artifacts
  pkg-config --exists libbs2b
}

build_libcaca() {
  clone_or_update https://github.com/cacalabs/libcaca.git "$SOURCE_ROOT/libcaca"
  configure_make_install_static "$SOURCE_ROOT/libcaca" \
    --disable-doc \
    --disable-examples \
    --disable-python \
    --disable-ruby \
    --disable-csharp \
    --disable-java \
    --disable-imlib2 \
    --disable-ncurses
  remove_dynamic_artifacts
  pkg-config --exists caca
}

build_libcdio() {
  local iconv_cflags
  local iconv_libs

  clone_or_update https://github.com/libcdio/libcdio-C.git "$SOURCE_ROOT/libcdio"
  iconv_cflags="$(pkg-config --cflags libiconv 2>/dev/null || pkg-config --cflags iconv 2>/dev/null || true)"
  iconv_libs="$(pkg-config --libs --static libiconv 2>/dev/null || pkg-config --libs --static iconv 2>/dev/null || printf '%s' '-liconv')"
  (
    export MAKEINFO=true
    export CPPFLAGS="$CPPFLAGS $iconv_cflags"
    export LIBS="${LIBS:-} $iconv_libs"
    export am_cv_func_iconv=yes
    export am_cv_func_iconv_works=yes
    configure_make_install_static "$SOURCE_ROOT/libcdio" \
      --without-cd-drive \
      --without-cd-info \
      --without-cdda-player \
      --without-iso-info \
      --without-iso-read \
      --without-cd-read
  )
  remove_dynamic_artifacts
  pkg-config --exists libcdio

  clone_or_update https://github.com/libcdio/libcdio-paranoia.git "$SOURCE_ROOT/libcdio-paranoia"
  local libcdio_paranoia_patch="$BUILDER_DIR/patch/libcdio-paranoia-0001-build-libraries-only.patch"
  git -C "$SOURCE_ROOT/libcdio-paranoia" apply --check "$libcdio_paranoia_patch"
  git -C "$SOURCE_ROOT/libcdio-paranoia" apply "$libcdio_paranoia_patch"
  (
    export MAKEINFO=true
    export CPPFLAGS="$CPPFLAGS $iconv_cflags"
    export LIBS="${LIBS:-} $iconv_libs"
    export am_cv_func_iconv=yes
    export am_cv_func_iconv_works=yes
    configure_make_install_static "$SOURCE_ROOT/libcdio-paranoia"
  )
  remove_dynamic_artifacts
  pkg-config --exists libcdio_cdda
  pkg-config --exists libcdio_paranoia
}

build_libvidstab() {
  clone_or_update https://github.com/georgmartius/vid.stab.git "$SOURCE_ROOT/vid.stab"
  cmake_static_install "$SOURCE_ROOT/vid.stab" "$BUILD_ROOT/vid.stab" \
    -DUSE_OMP=OFF
  remove_dynamic_artifacts
  pkg-config --exists vidstab
}

build_kvazaar() {
  clone_or_update https://github.com/ultravideo/kvazaar.git "$SOURCE_ROOT/kvazaar"
  configure_make_install_static "$SOURCE_ROOT/kvazaar"
  remove_dynamic_artifacts
  pkg-config --exists kvazaar
}

build_xvidcore() {
  local archive="$SOURCE_ROOT/xvidcore-1.3.7.tar.gz"
  local src="$SOURCE_ROOT/xvidcore"
  if [[ ! -d "$src" ]]; then
    curl -L https://downloads.xvid.com/downloads/xvidcore-1.3.7.tar.gz -o "$archive"
    mkdir -p "$src"
    tar -xzf "$archive" -C "$src" --strip-components=1
  fi
  (
    cd "$src/build/generic"
    ./configure \
      --prefix="$SOURCE_PREFIX" \
      --disable-shared \
      --enable-static
    make -j"$(ci_jobs)"
    make install
  )
  remove_dynamic_artifacts
  pkg-config --exists xvidcore || true
}

build_frei0r() {
  local frei0r_module_ldflags

  clone_or_update https://github.com/dyne/frei0r.git "$SOURCE_ROOT/frei0r"
  frei0r_module_ldflags="$(pkg-config --libs --static cairo pixman-1)"

  LDFLAGS="$LDFLAGS $frei0r_module_ldflags" cmake_static_install "$SOURCE_ROOT/frei0r" "$BUILD_ROOT/frei0r" \
    -DWITHOUT_OPENCV=ON \
    -DWITHOUT_GAVL=ON
  pkg-config --exists frei0r
}
