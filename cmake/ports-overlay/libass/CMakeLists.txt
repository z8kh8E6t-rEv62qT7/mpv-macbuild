cmake_minimum_required(VERSION 3.9)
project(libass C)

include(CheckCSourceCompiles)

include_directories("${CMAKE_CURRENT_SOURCE_DIR}/libass" "${CMAKE_CURRENT_BINARY_DIR}")

set(CONFIG_FREETYPE 1)
set(CONFIG_FRIBIDI 1)
set(CONFIG_HARFBUZZ 1)
set(CONFIG_UNIBREAK 1)

file(GLOB_RECURSE SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/libass/*.c")

set(PKG_REQUIRES_LIBASS "libunibreak >= 7.0, harfbuzz >= 1.2.3, fribidi >= 0.19.1, freetype2 >= 9.17.3")
set(PKG_LIBS_LIBASS)

if(NOT APPLE)
  message(FATAL_ERROR "This overlay port only supports macOS/CoreText builds.")
endif()

set(CONFIG_CORETEXT 1)
list(FILTER SOURCES EXCLUDE REGEX ".*ass_directwrite.c$")
list(FILTER SOURCES EXCLUDE REGEX ".*ass_fontconfig.c$")

check_c_source_compiles(
  "
  #include <ApplicationServices/ApplicationServices.h>
  int main(void){
    CTFontDescriptorCopyAttribute(NULL, kCTFontURLAttribute);
    return 0;
  }
  "
  CHECK_OLD_OSX
)
if(CHECK_OLD_OSX)
  set(FONT_LIBRARY "-framework ApplicationServices -framework CoreFoundation")
  set(PKG_LIBS_LIBASS "-framework ApplicationServices -framework CoreFoundation")
else()
  set(FONT_LIBRARY "-framework CoreText -framework CoreFoundation")
  set(PKG_LIBS_LIBASS "-framework CoreText -framework CoreFoundation")
endif()

set(PKG_LIBS_LIBASS "${PKG_LIBS_LIBASS} -lm")

find_package(Freetype REQUIRED)

find_package(PkgConfig REQUIRED)
pkg_check_modules(FRIBIDI REQUIRED IMPORTED_TARGET fribidi)
pkg_check_modules(HARFBUZZ REQUIRED IMPORTED_TARGET harfbuzz)
pkg_check_modules(UNIBREAK REQUIRED IMPORTED_TARGET libunibreak)

configure_file("${CMAKE_CURRENT_SOURCE_DIR}/config.h.in" config.h)

add_library(ass ${SOURCES} "${CMAKE_CURRENT_SOURCE_DIR}/libass.def")

target_include_directories(ass PRIVATE
  PkgConfig::FRIBIDI
  PkgConfig::HARFBUZZ
  PkgConfig::UNIBREAK
)
target_link_libraries(ass PRIVATE
  Freetype::Freetype
  PkgConfig::FRIBIDI
  PkgConfig::HARFBUZZ
  PkgConfig::UNIBREAK
  ${FONT_LIBRARY}
)

install(TARGETS ass
  RUNTIME DESTINATION bin
  LIBRARY DESTINATION lib
  ARCHIVE DESTINATION lib
)

set(prefix "${CMAKE_INSTALL_PREFIX}")
set(exec_prefix "${CMAKE_INSTALL_PREFIX}")
set(libdir "${CMAKE_INSTALL_PREFIX}/lib")
set(includedir "${CMAKE_INSTALL_PREFIX}/include")
set(PACKAGE_VERSION "${LIBASS_VERSION}")
if(BUILD_SHARED_LIBS)
  set(PKG_REQUIRES_PUBLIC "${PKG_REQUIRES_LIBASS}")
  set(PKG_LIBS_PUBLIC "${PKG_LIBS_LIBASS}")
else()
  set(PKG_REQUIRES_PRIVATE "${PKG_REQUIRES_LIBASS}")
  set(PKG_LIBS_PRIVATE "${PKG_LIBS_LIBASS}")
endif()
configure_file(libass.pc.in libass.pc @ONLY)
install(FILES
        "${CMAKE_CURRENT_BINARY_DIR}/libass.pc"
        DESTINATION "${CMAKE_INSTALL_LIBDIR}/pkgconfig")
