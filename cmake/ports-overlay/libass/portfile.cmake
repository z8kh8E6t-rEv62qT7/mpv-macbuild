vcpkg_check_linkage(ONLY_STATIC_LIBRARY)

vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO rcombs/libass
    REF 09283f57d303af9a71ed80c83fe6242e4f035486
    SHA512 3ea3ea7c24a81f1884556a09138a2ba0435d0161bec8ff58c02c25606d591631bc73a603fff99b4fcbac69894e1a5f620defb404a338a86fa19806470c6c5a32
    HEAD_REF threading
    PATCHES
        0001-try-to-parse-script-properties.patch
)

file(COPY
    "${CMAKE_CURRENT_LIST_DIR}/CMakeLists.txt"
    "${CMAKE_CURRENT_LIST_DIR}/config.h.in"
    "${CMAKE_CURRENT_LIST_DIR}/libass.def"
    DESTINATION "${SOURCE_PATH}"
)

file(COPY
    "${SOURCE_PATH}/libass/ass.h"
    "${SOURCE_PATH}/libass/ass_types.h"
    DESTINATION "${CURRENT_PACKAGES_DIR}/include/ass"
)

vcpkg_find_acquire_program(PKGCONFIG)
get_filename_component(PKGCONFIG_EXE_PATH "${PKGCONFIG}" DIRECTORY)
vcpkg_add_to_path("${PKGCONFIG_EXE_PATH}")

vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS -DLIBASS_VERSION=${VERSION}
)

vcpkg_cmake_install()
vcpkg_copy_pdbs()
vcpkg_fixup_pkgconfig()

file(INSTALL "${SOURCE_PATH}/COPYING" DESTINATION "${CURRENT_PACKAGES_DIR}/share/${PORT}" RENAME copyright)
