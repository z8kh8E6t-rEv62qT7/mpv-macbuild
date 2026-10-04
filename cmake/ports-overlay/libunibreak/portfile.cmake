vcpkg_check_linkage(ONLY_STATIC_LIBRARY)

string(REGEX REPLACE "^([0-9]*)[.].*" "\\1" MAJOR "${VERSION}")
string(REGEX REPLACE "^.*[.]([0-9]*)" "\\1" MINOR "${VERSION}")

vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO adah1972/libunibreak
    REF "libunibreak_${MAJOR}_${MINOR}"
    SHA512 5813b54458fd442def3d8b831147dada549f88f9a7831e72f4b608571d78c057fa05732d3b0d69dae365adf346825a89a1d7fdf74fa3b5465495019648820fdf
    HEAD_REF master
    PATCHES
        fix_export.patch
)

file(COPY
    "${CMAKE_CURRENT_LIST_DIR}/CMakeLists.txt"
    "${CMAKE_CURRENT_LIST_DIR}/libunibreak.pc.in"
    DESTINATION "${SOURCE_PATH}"
)

vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        -DLIBUNIBREAK_VERSION=${VERSION}
    OPTIONS_DEBUG
        -DDISABLE_INSTALL_HEADERS=ON
)

vcpkg_cmake_install()
vcpkg_fixup_pkgconfig()

configure_file(
    "${CMAKE_CURRENT_LIST_DIR}/libunibreak-config.cmake.in"
    "${CURRENT_PACKAGES_DIR}/share/${PORT}/libunibreak-config.cmake"
    @ONLY
)

vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/LICENCE")
