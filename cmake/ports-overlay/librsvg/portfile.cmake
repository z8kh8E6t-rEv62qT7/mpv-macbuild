vcpkg_download_distfile(
    ARCHIVE
    URLS "https://download.gnome.org/sources/librsvg/2.62/librsvg-2.62.3.tar.xz"
    FILENAME "librsvg-2.62.3.tar.xz"
    SHA512 c2c0f28268e47ec78f98d86cd2536be3e0c3706039b04ac2286d87a6ac7ee0dfb75a4adc4f8bd9c3b6b1f5c94fecafc6d84dfe67f7e4ebfad59f7227e509300d
)

vcpkg_extract_source_archive(
    SOURCE_PATH
    ARCHIVE "${ARCHIVE}"
)

vcpkg_configure_meson(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        -Davif=enabled
        -Ddocs=disabled
        -Dintrospection=disabled
        -Dpixbuf=disabled
        -Dpixbuf-loader=disabled
        -Drsvg-convert=disabled
        -Dtests=false
        -Dvala=disabled
    ADDITIONAL_BINARIES
        glib-mkenums='${CURRENT_HOST_INSTALLED_DIR}/tools/glib/glib-mkenums'
)

vcpkg_install_meson()
vcpkg_fixup_pkgconfig()
vcpkg_copy_pdbs()

file(REMOVE_RECURSE
    "${CURRENT_PACKAGES_DIR}/debug/include"
    "${CURRENT_PACKAGES_DIR}/debug/share"
)

vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/COPYING.LIB")
