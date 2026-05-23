if(NOT VCPKG_TARGET_IS_OSX OR NOT VCPKG_TARGET_ARCHITECTURE STREQUAL "arm64")
    message(FATAL_ERROR "This libvpx overlay port is intended for macOS arm64 only.")
endif()

vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO webmproject/libvpx
    REF "v${VERSION}"
    SHA512 07f5e352411d6c0be331706d1835ac89bafbeddcbbac5542b473323766e9e974f4f68b33590f2aa50a7d8d69468a642b508cbb0a7c49a82c9933b07820f9c9d9
    HEAD_REF master
    PATCHES
        0005-dont-expect-gnu-diff.patch
)

vcpkg_find_acquire_program(PERL)
get_filename_component(PERL_EXE_PATH "${PERL}" DIRECTORY)
find_program(BASH NAMES bash REQUIRED NO_CACHE)

vcpkg_cmake_get_vars(cmake_vars_file)
include("${cmake_vars_file}")

set(ENV{PATH} "${PERL_EXE_PATH}:$ENV{PATH}")
set(ENV{CC} "${VCPKG_DETECTED_CMAKE_C_COMPILER}")
set(ENV{CXX} "${VCPKG_DETECTED_CMAKE_CXX_COMPILER}")
set(ENV{AR} "${VCPKG_DETECTED_CMAKE_AR}")
set(ENV{LD} "${VCPKG_DETECTED_CMAKE_CXX_COMPILER}")
set(ENV{RANLIB} "${VCPKG_DETECTED_CMAKE_RANLIB}")
set(ENV{STRIP} "${VCPKG_DETECTED_CMAKE_STRIP}")

set(LIBVPX_TARGET "arm64-darwin20-gcc")
set(OPTIONS
    --disable-examples
    --disable-tools
    --disable-docs
    --disable-unit-tests
    --enable-pic
)

if(VCPKG_LIBRARY_LINKAGE STREQUAL "dynamic")
    list(APPEND OPTIONS --disable-static --enable-shared)
else()
    list(APPEND OPTIONS --enable-static --disable-shared)
endif()

if("realtime" IN_LIST FEATURES)
    list(APPEND OPTIONS --enable-realtime-only)
endif()

if("highbitdepth" IN_LIST FEATURES)
    list(APPEND OPTIONS --enable-vp9-highbitdepth)
endif()

if(DEFINED VCPKG_OSX_DEPLOYMENT_TARGET)
    set(MAC_OSX_MIN_VERSION_CFLAGS
        "--extra-cflags=-mmacosx-version-min=${VCPKG_OSX_DEPLOYMENT_TARGET}"
        "--extra-cxxflags=-mmacosx-version-min=${VCPKG_OSX_DEPLOYMENT_TARGET}"
    )
endif()

if(VCPKG_HOST_IS_BSD)
    set(MAKE_BINARY "gmake")
else()
    set(MAKE_BINARY "make")
endif()

function(libvpx_distclean log_suffix)
    if(EXISTS "${SOURCE_PATH}/Makefile")
        vcpkg_execute_required_process(
            COMMAND
                "${BASH}" --noprofile --norc -c "${MAKE_BINARY} distclean"
            WORKING_DIRECTORY "${SOURCE_PATH}"
            LOGNAME distclean-${TARGET_TRIPLET}-${log_suffix}
        )
    endif()
endfunction()

function(libvpx_build_config config_name install_prefix)
    set(extra_configure_options ${ARGN})

    libvpx_distclean(pre-${config_name})

    message(STATUS "Configuring libvpx for ${config_name}")
    vcpkg_execute_required_process(
        COMMAND
            "${BASH}" --noprofile --norc
            "${SOURCE_PATH}/configure"
            "--target=${LIBVPX_TARGET}"
            ${OPTIONS}
            ${extra_configure_options}
            "--prefix=${install_prefix}"
            ${MAC_OSX_MIN_VERSION_CFLAGS}
        WORKING_DIRECTORY "${SOURCE_PATH}"
        LOGNAME configure-${TARGET_TRIPLET}-${config_name}
    )

    message(STATUS "Building libvpx for ${config_name}")
    vcpkg_execute_required_process(
        COMMAND
            "${BASH}" --noprofile --norc -c "${MAKE_BINARY} -j${VCPKG_CONCURRENCY}"
        WORKING_DIRECTORY "${SOURCE_PATH}"
        LOGNAME build-${TARGET_TRIPLET}-${config_name}
    )

    message(STATUS "Installing libvpx for ${config_name}")
    vcpkg_execute_required_process(
        COMMAND
            "${BASH}" --noprofile --norc -c "${MAKE_BINARY} install"
        WORKING_DIRECTORY "${SOURCE_PATH}"
        LOGNAME install-${TARGET_TRIPLET}-${config_name}
    )

    libvpx_distclean(post-${config_name})
endfunction()

message(STATUS "Build info. Target: ${LIBVPX_TARGET}; Options: ${OPTIONS}")

if(NOT DEFINED VCPKG_BUILD_TYPE OR VCPKG_BUILD_TYPE STREQUAL "release")
    libvpx_build_config(rel "${CURRENT_PACKAGES_DIR}")
endif()

if(NOT DEFINED VCPKG_BUILD_TYPE OR VCPKG_BUILD_TYPE STREQUAL "debug")
    libvpx_build_config(
        dbg
        "${CURRENT_PACKAGES_DIR}/debug"
        --enable-debug-libs
        --enable-debug
    )

    file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/include")
    file(REMOVE "${CURRENT_PACKAGES_DIR}/debug/lib/libvpx_g.a")
endif()

vcpkg_fixup_pkgconfig()

if(NOT DEFINED VCPKG_BUILD_TYPE OR VCPKG_BUILD_TYPE STREQUAL "debug")
    set(LIBVPX_CONFIG_DEBUG ON)
else()
    set(LIBVPX_CONFIG_DEBUG OFF)
endif()

configure_file("${CMAKE_CURRENT_LIST_DIR}/unofficial-libvpx-config.cmake.in" "${CURRENT_PACKAGES_DIR}/share/unofficial-libvpx/unofficial-libvpx-config.cmake" @ONLY)

vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/LICENSE")
