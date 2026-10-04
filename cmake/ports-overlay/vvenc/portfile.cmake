vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO fraunhoferhhi/vvenc
    REF v${VERSION}
    SHA512 2b73f10a32da28bdc51913b5ecc229fe56ef0afe0d66a9bb1e76a9044dc04427e55587b6b9a0ca8d315220d4362b663e038a68a89e5b38ecf3ed2e7b5dcb0c58
    HEAD_REF master
    PATCHES
        fix-dependencies.patch
        vvenc-0001-explicitly-instantiate-loopfilter-deblockarea.patch
)

vcpkg_check_features(OUT_FEATURE_OPTIONS FEATURE_OPTIONS
    FEATURES
        tools VVENC_INSTALL_FULLFEATURE_APP
    INVERTED_FEATURES
        tools VVENC_LIBRARY_ONLY
)

vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS ${FEATURE_OPTIONS}
        -DCCACHE_FOUND=OFF
        -DVVENC_ENABLE_X86_SIMD=OFF
        -DVVENC_ENABLE_WERROR=OFF
        -DVVENC_ENABLE_THIRDPARTY_JSON=SYSTEM
)

vcpkg_cmake_install()
vcpkg_cmake_config_fixup(CONFIG_PATH lib/cmake/vvenc)

vcpkg_copy_pdbs()
vcpkg_fixup_pkgconfig()
# Upstream now derives the C++ runtime flags from the compiler. Do not require
# or rewrite the old hardcoded -lstdc++; validate the macOS result instead.
if(VCPKG_TARGET_IS_OSX)
    set(pkgconfig_files "${CURRENT_PACKAGES_DIR}/lib/pkgconfig/libvvenc.pc")
    if(NOT VCPKG_BUILD_TYPE)
        list(APPEND pkgconfig_files "${CURRENT_PACKAGES_DIR}/debug/lib/pkgconfig/libvvenc.pc")
    endif()
    foreach(pkgconfig_file IN LISTS pkgconfig_files)
        file(READ "${pkgconfig_file}" pkgconfig_contents)
        if(pkgconfig_contents MATCHES "-lstdc[+][+]")
            message(FATAL_ERROR "vvenc must not advertise libstdc++ on macOS: ${pkgconfig_file}")
        endif()
    endforeach()
endif()

if("tools" IN_LIST FEATURES)
    vcpkg_copy_tools(TOOL_NAMES vvencFFapp vvencapp AUTO_CLEAN)
endif()

file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/include")
file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/share")
file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/bin" "${CURRENT_PACKAGES_DIR}/debug/bin")
vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/LICENSE.txt")
