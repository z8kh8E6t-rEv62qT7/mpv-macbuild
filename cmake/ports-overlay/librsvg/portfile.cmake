vcpkg_download_distfile(
    ARCHIVE
    URLS "https://download.gnome.org/sources/librsvg/2.63/librsvg-2.63.2.tar.xz"
    FILENAME "librsvg-2.63.2.tar.xz"
    SHA512 2d4d48d3cf8db34ecc8a26ce689bc2662d9d909e796299602e81c907e9b72a14a865cbd82c58d498316e73001e2242b44a56e52e57c0b38bbee74e38c0e314a9
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
