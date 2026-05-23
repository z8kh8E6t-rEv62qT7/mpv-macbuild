vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO breakfastquay/rubberband
    REF "v${VERSION}"
    SHA512 f581e900a71f78fde3361d2bed2fe165952c2ca087168c5f4e4994586bd832267eea58e0662a74b6a7430bc361fe80b5307b2ee6bf631a3561a8cba86e1cd3f2
    HEAD_REF default
    PATCHES
        fix-libcxx-size_t.patch
)

if("cli" IN_LIST FEATURES)
    set(CLI_FEATURE enabled)
else()
    set(CLI_FEATURE disabled)
endif()

if(
    (VCPKG_TARGET_IS_WINDOWS AND (VCPKG_TARGET_ARCHITECTURE STREQUAL "x86" OR VCPKG_TARGET_ARCHITECTURE STREQUAL "arm" OR VCPKG_TARGET_ARCHITECTURE STREQUAL "arm64"))
    OR VCPKG_TARGET_IS_OSX
    OR VCPKG_TARGET_IS_IOS
    OR VCPKG_TARGET_IS_EMSCRIPTEN
)
    set(FFT_LIB "fftw")
else()
    set(FFT_LIB "sleef")
endif()

vcpkg_configure_meson(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        -Dfft=${FFT_LIB}
        -Dresampler=libsamplerate
        -Dipp_path=
        -Dextra_include_dirs=
        -Dextra_lib_dirs=
        -Djni=disabled
        -Dladspa=disabled
        -Dlv2=disabled
        -Dvamp=disabled
        -Dcmdline=${CLI_FEATURE}
        -Dtests=disabled
)

vcpkg_install_meson()

vcpkg_fixup_pkgconfig()
vcpkg_copy_pdbs()

if(EXISTS "${CURRENT_PACKAGES_DIR}/bin/rubberband-program${VCPKG_TARGET_EXECUTABLE_SUFFIX}")
  set(RUBBERBAND_PROGRAM_NAMES rubberband-program rubberband-program-r3)
else()
  set(RUBBERBAND_PROGRAM_NAMES rubberband rubberband-r3)
endif()

if("cli" IN_LIST FEATURES)
  vcpkg_copy_tools(TOOL_NAMES ${RUBBERBAND_PROGRAM_NAMES} AUTO_CLEAN)
endif()

vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/COPYING")
