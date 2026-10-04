cmake_minimum_required(VERSION 3.24)
project(mpv_macos_static_superbuild NONE)

include(ExternalProject)

find_program(BASH_EXECUTABLE bash REQUIRED)
find_program(GIT_EXECUTABLE git REQUIRED)

set(BUILDER_DIR "" CACHE PATH "Checked out builder repository path")
set(SOURCE_PREFIX "" CACHE PATH "Install prefix for source-built dependencies")
set(FFMPEG_PREFIX "" CACHE PATH "Install prefix for source-built FFmpeg")
set(FFMPEG_LGPL_PREFIX "" CACHE PATH "Install prefix for LGPL shared FFmpeg")
set(SOURCE_ROOT "" CACHE PATH "Source checkout root")
set(BUILD_ROOT "" CACHE PATH "Build root")
set(AUDIT_DIR "" CACHE PATH "CI audit and log output directory")
set(FFMPEG_REF "" CACHE STRING "FFmpeg tag, branch, or commit")

set(VCPKG_ROOT "${SOURCE_ROOT}/vcpkg")
set(VCPKG_REF "5dd2e1600d049b498ff9fb9fe15997533ae0c804")
set(VCPKG_INSTALLED_DIR "${SOURCE_PREFIX}/vcpkg-installed")
set(VCPKG_TARGET_PREFIX "${VCPKG_INSTALLED_DIR}/arm64-osx-static")
set(VCPKG_OVERLAY_PORTS_DIR "${CMAKE_CURRENT_LIST_DIR}/ports-overlay")

set(BUILD_ENVIRONMENT_FILE "${BUILDER_DIR}/scripts/lib/build-environment.json")
if(NOT EXISTS "${BUILD_ENVIRONMENT_FILE}")
  message(FATAL_ERROR "build environment declaration is missing: ${BUILD_ENVIRONMENT_FILE}")
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${BUILD_ENVIRONMENT_FILE}")
file(READ "${BUILD_ENVIRONMENT_FILE}" BUILD_ENVIRONMENT_JSON)
string(JSON BUILD_ENVIRONMENT_LENGTH LENGTH "${BUILD_ENVIRONMENT_JSON}")
if(BUILD_ENVIRONMENT_LENGTH LESS 1)
  message(FATAL_ERROR "build environment declaration is empty")
endif()

# ExternalProject uses lists internally; protect literal semicolons until it
# constructs the final command arguments.
set(SUPERBUILD_LIST_SEPARATOR "__MPV_ENV_SEMICOLON__")
function(encode_superbuild_environment output name value)
  string(FIND "${value}" "${SUPERBUILD_LIST_SEPARATOR}" separator_index)
  if(NOT separator_index EQUAL -1)
    message(FATAL_ERROR "${name} contains the reserved environment list separator")
  endif()
  string(REPLACE ";" "${SUPERBUILD_LIST_SEPARATOR}" encoded_value "${value}")
  set(${output} "${name}=${encoded_value}" PARENT_SCOPE)
endfunction()

set(SUPERBUILD_ENV)
math(EXPR BUILD_ENVIRONMENT_LAST_INDEX "${BUILD_ENVIRONMENT_LENGTH} - 1")
foreach(index RANGE ${BUILD_ENVIRONMENT_LAST_INDEX})
  string(JSON environment_name MEMBER "${BUILD_ENVIRONMENT_JSON}" ${index})
  string(JSON superbuild_source GET "${BUILD_ENVIRONMENT_JSON}" "${environment_name}" superbuild)
  if(superbuild_source STREQUAL "none")
    continue()
  elseif(superbuild_source STREQUAL "environment")
    set(environment_value "$ENV{${environment_name}}")
  elseif(superbuild_source STREQUAL "cmake")
    if(environment_name STREQUAL "PKG_CONFIG_LIBDIR")
      set(environment_value "${FFMPEG_PREFIX}/lib/pkgconfig:${FFMPEG_PREFIX}/share/pkgconfig:${SOURCE_PREFIX}/lib/pkgconfig:${SOURCE_PREFIX}/share/pkgconfig:${VCPKG_TARGET_PREFIX}/lib/pkgconfig:${VCPKG_TARGET_PREFIX}/share/pkgconfig")
    elseif(environment_name STREQUAL "PKG_CONFIG_PATH")
      set(environment_value "")
    else()
      if(NOT DEFINED ${environment_name})
        message(FATAL_ERROR "CMake build environment value is not defined: ${environment_name}")
      endif()
      set(environment_value "${${environment_name}}")
    endif()
  else()
    message(FATAL_ERROR "invalid superbuild source for ${environment_name}: ${superbuild_source}")
  endif()
  string(JSON required_count LENGTH "${BUILD_ENVIRONMENT_JSON}" "${environment_name}" required)
  if(required_count GREATER 0)
    math(EXPR required_last_index "${required_count} - 1")
    foreach(required_index RANGE ${required_last_index})
      string(JSON required_stage GET "${BUILD_ENVIRONMENT_JSON}" "${environment_name}" required ${required_index})
      if(required_stage STREQUAL "cmake")
        string(JSON allow_empty GET "${BUILD_ENVIRONMENT_JSON}" "${environment_name}" allow_empty)
        if(NOT allow_empty AND environment_value STREQUAL "")
          message(FATAL_ERROR "${environment_name} is required")
        endif()
      endif()
    endforeach()
  endif()
  encode_superbuild_environment(environment_assignment "${environment_name}" "${environment_value}")
  list(APPEND SUPERBUILD_ENV "${environment_assignment}")
endforeach()

foreach(compiler IN ITEMS RUSTC MPV_REAL_RUSTC)
  if(NOT EXISTS "$ENV{${compiler}}")
    message(FATAL_ERROR "${compiler} does not exist: $ENV{${compiler}}")
  endif()
endforeach()

# Apply vcpkg's isolated environment after the shared forwarding declarations.
set(VCPKG_INSTALL_ENV "${SUPERBUILD_ENV}")
foreach(environment_name IN ITEMS
    CFLAGS CXXFLAGS OBJCFLAGS OBJCXXFLAGS CPPFLAGS LDFLAGS CPATH
    LIBRARY_PATH DYLD_LIBRARY_PATH CMAKE_PREFIX_PATH
    MACOSX_DEPLOYMENT_TARGET CMAKE_OSX_DEPLOYMENT_TARGET
    CC CXX OBJC OBJCXX AR RANLIB STRIP NM)
  if(environment_name MATCHES "^(CC|CXX|OBJC|OBJCXX|AR|RANLIB|STRIP|NM)$")
    set(environment_value "$ENV{VCPKG_TARGET_${environment_name}}")
  elseif(environment_name MATCHES "^(MACOSX_DEPLOYMENT_TARGET|CMAKE_OSX_DEPLOYMENT_TARGET)$")
    set(environment_value "$ENV{${environment_name}}")
  else()
    set(environment_value "")
  endif()
  encode_superbuild_environment(environment_assignment "${environment_name}" "${environment_value}")
  list(APPEND VCPKG_INSTALL_ENV "${environment_assignment}")
endforeach()

set(VCPKG_STATIC_PORTS
  aom
  bzip2
  chromaprint
  dav1d
  expat
  fdk-aac
  fontconfig
  freetype
  fribidi
  harfbuzz
  lcms
  libarchive
  libaribcaption
  libass
  libbluray
  libdvdcss
  libdvdnav
  libdvdread
  libiconv
  libjxl
  libmysofa
  libmodplug
  libogg
  libunibreak
  mp3lame
  openjpeg
  openh264
  libopenmpt
  libpng
  libsrt
  libssh
  libtheora
  libudfread
  libvmaf
  libvorbis
  libvpx
  libwebp
  libxml2
  libjpeg-turbo
  liblzma
  librsvg
  librtmp
  lzo
  mujs
  openal-soft
  openssl
  opus
  rubberband
  sdl2
  shaderc
  snappy
  soxr
  speex
  spirv-cross
  svt-av1
  uchardet
  vvenc
  x264
  x265
  xxhash
  zlib
  zstd
)

ExternalProject_Add(vcpkg-tool
  PREFIX "${BUILD_ROOT}/superbuild/vcpkg-tool"
  GIT_REPOSITORY https://github.com/microsoft/vcpkg.git
  GIT_TAG "${VCPKG_REF}"
  SOURCE_DIR "${VCPKG_ROOT}"
  UPDATE_COMMAND ""
  CONFIGURE_COMMAND ""
  BUILD_COMMAND
    "${BASH_EXECUTABLE}" "${VCPKG_ROOT}/bootstrap-vcpkg.sh" -disableMetrics
  INSTALL_COMMAND ""
  LOG_DOWNLOAD ON
)

ExternalProject_Add(vcpkg-static-ports
  LIST_SEPARATOR "${SUPERBUILD_LIST_SEPARATOR}"
  PREFIX "${BUILD_ROOT}/superbuild/vcpkg-static-ports"
  DOWNLOAD_COMMAND ""
  UPDATE_COMMAND ""
  CONFIGURE_COMMAND ""
  BUILD_COMMAND
    "${CMAKE_COMMAND}" -E env ${VCPKG_INSTALL_ENV}
    "${BASH_EXECUTABLE}" "${CMAKE_CURRENT_LIST_DIR}/scripts/run-vcpkg-install.sh"
      ${VCPKG_STATIC_PORTS}
  INSTALL_COMMAND ""
  DEPENDS vcpkg-tool
)

ExternalProject_Add(custom-static-deps
  LIST_SEPARATOR "${SUPERBUILD_LIST_SEPARATOR}"
  PREFIX "${BUILD_ROOT}/superbuild/custom-static-deps"
  DOWNLOAD_COMMAND ""
  UPDATE_COMMAND ""
  CONFIGURE_COMMAND ""
  BUILD_COMMAND
    "${CMAKE_COMMAND}" -E env ${SUPERBUILD_ENV}
    "${BASH_EXECUTABLE}" "${CMAKE_CURRENT_LIST_DIR}/scripts/build-custom-static-deps.sh"
  INSTALL_COMMAND ""
  DEPENDS vcpkg-static-ports
)

ExternalProject_Add(ffmpeg-static
  LIST_SEPARATOR "${SUPERBUILD_LIST_SEPARATOR}"
  PREFIX "${BUILD_ROOT}/superbuild/ffmpeg-static"
  DOWNLOAD_COMMAND ""
  UPDATE_COMMAND ""
  CONFIGURE_COMMAND ""
  BUILD_COMMAND
    "${CMAKE_COMMAND}" -E env ${SUPERBUILD_ENV}
    "${BASH_EXECUTABLE}" "${CMAKE_CURRENT_LIST_DIR}/scripts/build-ffmpeg-static.sh"
  INSTALL_COMMAND ""
  DEPENDS custom-static-deps
)

ExternalProject_Add(ffmpeg-lgpl
  LIST_SEPARATOR "${SUPERBUILD_LIST_SEPARATOR}"
  PREFIX "${BUILD_ROOT}/superbuild/ffmpeg-lgpl"
  DOWNLOAD_COMMAND ""
  UPDATE_COMMAND ""
  CONFIGURE_COMMAND ""
  BUILD_COMMAND
    "${CMAKE_COMMAND}" -E env ${SUPERBUILD_ENV}
    "${BASH_EXECUTABLE}" "${CMAKE_CURRENT_LIST_DIR}/scripts/build-ffmpeg-lgpl.sh"
  INSTALL_COMMAND ""
  DEPENDS vcpkg-static-ports
)

add_custom_target(source-static-deps DEPENDS custom-static-deps)
