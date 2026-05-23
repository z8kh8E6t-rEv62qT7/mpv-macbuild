cmake_minimum_required(VERSION 3.8.0)
project(libunibreak C)

include(GNUInstallDirs)

set(LIBUNIBREAK_VERSION "" CACHE STRING "libunibreak package version")
if(NOT LIBUNIBREAK_VERSION)
  message(FATAL_ERROR "LIBUNIBREAK_VERSION is required")
endif()

set(libunibreak_srcs
  src/linebreak.c
  src/linebreakdata.c
  src/linebreakdef.c
  src/wordbreak.c
  src/wordbreakdata.c
  src/graphemebreak.c
  src/graphemebreakdata.c
  src/emojidef.c
  src/eastasianwidthdef.c
  src/eastasianwidthdata.c
  src/unibreakbase.c
  src/unibreakdef.c
)

include_directories(src)

add_library(unibreak ${libunibreak_srcs})

install(
  TARGETS unibreak
  RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}"
  LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}"
  ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
)

if(NOT DISABLE_INSTALL_HEADERS)
  install(
    FILES
    src/emojidef.h
    src/eastasianwidthdef.h
    src/unibreakbase.h
    src/unibreakdef.h
    src/graphemebreak.h
    src/graphemebreakdef.h
    src/linebreak.h
    src/linebreakdef.h
    src/test_skips.h
    src/wordbreak.h
    src/wordbreakdef.h
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
  )
endif()

set(prefix "${CMAKE_INSTALL_PREFIX}")
set(exec_prefix "${CMAKE_INSTALL_PREFIX}")
set(libdir "${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_LIBDIR}")
set(includedir "${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_INCLUDEDIR}")
set(PACKAGE_VERSION "${LIBUNIBREAK_VERSION}")
configure_file(libunibreak.pc.in libunibreak.pc @ONLY)
install(
  FILES "${CMAKE_CURRENT_BINARY_DIR}/libunibreak.pc"
  DESTINATION "${CMAKE_INSTALL_LIBDIR}/pkgconfig"
)
