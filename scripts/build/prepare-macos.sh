#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

require_github_file GITHUB_ENV
require_github_file GITHUB_PATH

if [[ -d /usr/local/bin ]]; then
  find /usr/local/bin -lname '*/Library/Frameworks/Python.framework/*' -delete -print
fi

if brew list python &> /dev/null; then
  brew unlink python || true
  brew link --overwrite python
fi

brew_prefix="$(brew config | awk '/^HOMEBREW_PREFIX:/ {print $2}')"
if [[ -d "$brew_prefix/bin" ]]; then
  find "$brew_prefix/bin" -lname '*/pkg-config@0*/*' -print -exec brew unlink pkg-config@0.29.2 \; -quit || true
fi

brew update
if brew list ffmpeg &> /dev/null; then
  brew unlink ffmpeg
fi

brew_formulae=(
  autoconf
  autoconf-archive
  automake
  bison
  cargo-c
  cmake
  curl
  flex
  gawk
  gettext
  git
  libtool
  lld
  llvm
  luarocks
  meson
  mono
  molten-vk
  nasm
  ninja
  pkgconf
  python
  rust
)

brew install -q "${brew_formulae[@]}"

moltenvk_icd_json="$brew_prefix/etc/vulkan/icd.d/MoltenVK_icd.json"
moltenvk_dylib="$brew_prefix/lib/libMoltenVK.dylib"
[[ -f "$moltenvk_icd_json" ]] || die "Homebrew molten-vk did not install $moltenvk_icd_json"
[[ -f "$moltenvk_dylib" ]] || die "Homebrew molten-vk did not install $moltenvk_dylib"

source_prefix="${RUNNER_TEMP}/source-prefix"
ffmpeg_prefix="${RUNNER_TEMP}/ffmpeg-prefix"
ffmpeg_lgpl_prefix="${RUNNER_TEMP}/ffmpeg-lgpl-prefix"
source_root="${RUNNER_TEMP}/sources"
build_root="${RUNNER_TEMP}/build"
python_venv="${RUNNER_TEMP}/python-venv"
tool_root="${RUNNER_TEMP}/ci-tools"
vcpkg_binary_cache="${RUNNER_TEMP}/vcpkg-binary-cache"
vcpkg_installed_dir="$source_prefix/vcpkg-installed"
vcpkg_target_prefix="$vcpkg_installed_dir/arm64-osx-static"
nuget_cache_mode="${NUGET_CACHE_MODE:-read}"
nuget_cache_reason="${NUGET_CACHE_REASON:-default read-only push mode}"
nuget_feed_url="${NUGET_FEED_URL:-https://nuget.pkg.github.com/${GITHUB_REPOSITORY_OWNER:-}/index.json}"
nuget_source_name="${NUGET_SOURCE_NAME:-github}"
nuget_config_path="${RUNNER_TEMP}/nuget.config"
llvm_prefix="$(brew --prefix llvm)"
lld_prefix="$(brew --prefix lld)"
rust_prefix="$(brew --prefix rust)"
ld64_lld="${lld_prefix}/bin/ld64.lld"
macosx_deployment_target="15.0"

mkdir -p \
  "$source_prefix" \
  "$ffmpeg_prefix" \
  "$ffmpeg_lgpl_prefix" \
  "$source_root" \
  "$build_root" \
  "$source_prefix/lib/pkgconfig" \
  "$ffmpeg_prefix/lib/pkgconfig" \
  "$ffmpeg_lgpl_prefix/lib/pkgconfig" \
  "$vcpkg_binary_cache"

mkdir -p "$tool_root"

python3 -m venv "$python_venv"
"$python_venv/bin/python" -m pip install --upgrade pip cython setuptools wheel

pkg_paths=(
  "$ffmpeg_prefix/lib/pkgconfig"
  "$ffmpeg_prefix/share/pkgconfig"
  "$source_prefix/lib/pkgconfig"
  "$source_prefix/share/pkgconfig"
  "$vcpkg_target_prefix/lib/pkgconfig"
  "$vcpkg_target_prefix/share/pkgconfig"
)
lib_paths=("$ffmpeg_prefix/lib" "$source_prefix/lib" "$vcpkg_target_prefix/lib")
include_paths=("$ffmpeg_prefix/include" "$source_prefix/include" "$vcpkg_target_prefix/include")
cmake_paths=("$ffmpeg_prefix" "$source_prefix" "$vcpkg_target_prefix")
bin_paths=(
  "$python_venv/bin"
  "$ffmpeg_prefix/bin"
  "$source_prefix/bin"
  "$llvm_prefix/bin"
  "$lld_prefix/bin"
  "$(brew --prefix mono)/bin"
  "$(brew --prefix bison)/bin"
  "$(brew --prefix flex)/bin"
  "$(brew --prefix gettext)/bin"
)

pkg_config_path="$(join_by_colon "${pkg_paths[@]}")"
library_path="$(join_by_colon "${lib_paths[@]}")"
cpath="$(join_by_colon "${include_paths[@]}")"
cmake_prefix_path="$(join_by_colon "${cmake_paths[@]}")"
dyld_library_path="$ffmpeg_prefix/lib:$source_prefix/lib"
if [[ -n "${DYLD_LIBRARY_PATH:-}" ]]; then
  dyld_library_path="$dyld_library_path:$DYLD_LIBRARY_PATH"
fi

export SOURCE_PREFIX="$source_prefix"
export FFMPEG_PREFIX="$ffmpeg_prefix"
export FFMPEG_LGPL_PREFIX="$ffmpeg_lgpl_prefix"
export SOURCE_ROOT="$source_root"
export BUILD_ROOT="$build_root"
export PYTHON_VENV="$python_venv"
export VCPKG_INSTALLED_DIR="$vcpkg_installed_dir"
export VCPKG_TARGET_PREFIX="$vcpkg_target_prefix"
export VCPKG_BINARY_CACHE="$vcpkg_binary_cache"
export NUGET_CACHE_MODE="$nuget_cache_mode"
export NUGET_CACHE_REASON="$nuget_cache_reason"
export NUGET_FEED_URL="$nuget_feed_url"
export NUGET_SOURCE_NAME="$nuget_source_name"
export NUGET_CONFIG_PATH="$nuget_config_path"
export VCPKG_BINARY_SOURCES="clear;files,$vcpkg_binary_cache,readwrite;nugetconfig,$nuget_config_path,$nuget_cache_mode"
export MACOSX_DEPLOYMENT_TARGET="$macosx_deployment_target"
export CMAKE_OSX_DEPLOYMENT_TARGET="$macosx_deployment_target"
export LLVM_PREFIX="$llvm_prefix"
export LLD_PREFIX="$lld_prefix"
export LD64_LLD="$ld64_lld"
export RUSTC="$rust_prefix/bin/rustc"
export CC="$llvm_prefix/bin/clang"
export CXX="$llvm_prefix/bin/clang++"
export OBJC="$llvm_prefix/bin/clang"
export OBJCXX="$llvm_prefix/bin/clang++"
export AR="$llvm_prefix/bin/llvm-ar"
export STRIP="$llvm_prefix/bin/llvm-strip"
export NM="$llvm_prefix/bin/llvm-nm"
export LLVM_RANLIB="$llvm_prefix/bin/llvm-ranlib"
export LLVM_CXX_RUNTIME_DIR="$llvm_prefix/lib/c++"
export LLVM_UNWIND_RUNTIME_DIR="$llvm_prefix/lib/unwind"
export LLVM_LIBCXX_DYLIB="$LLVM_CXX_RUNTIME_DIR/libc++.1.dylib"
export LLVM_LIBCXXABI_DYLIB="$LLVM_CXX_RUNTIME_DIR/libc++abi.1.dylib"
export LLVM_LIBUNWIND_DYLIB="$LLVM_UNWIND_RUNTIME_DIR/libunwind.1.dylib"
require_llvm_runtime_dylibs
vcpkg_ranlib="$tool_root/llvm-ranlib-compatible"
cat > "$vcpkg_ranlib" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

real_ranlib="${LLVM_RANLIB:?LLVM_RANLIB is not set}"
args=()
for arg in "$@"; do
  # Meson uses Darwin ranlib -c when building static libraries. llvm-ranlib
  # does not accept that Apple-specific switch, so keep LLVM ranlib but drop it.
  [[ "$arg" == "-c" ]] && continue
  args+=("$arg")
done

exec "$real_ranlib" "${args[@]}"
EOF
chmod +x "$vcpkg_ranlib"
export RANLIB="$vcpkg_ranlib"
export VCPKG_TARGET_CC="$CC"
export VCPKG_TARGET_CXX="$CXX"
export VCPKG_TARGET_OBJC="$OBJC"
export VCPKG_TARGET_OBJCXX="$OBJCXX"
export VCPKG_TARGET_AR="$AR"
export VCPKG_TARGET_RANLIB="$vcpkg_ranlib"
export VCPKG_TARGET_STRIP="$STRIP"
export VCPKG_TARGET_NM="$NM"
export LLVM_RES="$("$CC" -print-resource-dir)"
export LLVM_RESOURCE_FLAG="-resource-dir=$LLVM_RES"
export LLVM_C_BUNDLE="-rtlib=compiler-rt $LLVM_RESOURCE_FLAG"
export LLVM_CXX_BUNDLE="-rtlib=compiler-rt -stdlib=libc++ $LLVM_RESOURCE_FLAG"
export LLVM_LINK_BUNDLE="-rtlib=compiler-rt --unwindlib=libunwind -stdlib=libc++"
export LLVM_BUNDLE="$LLVM_LINK_BUNDLE $LLVM_RESOURCE_FLAG"
export LLVM_RUNTIME_LINK_FLAGS="$(llvm_runtime_link_flags)"
export CPU_FLAGS="-march=armv8.7-a -mcpu=apple-m4 -mtune=apple-m4"
export OPTIMIZATIONS="-flto=thin -O3 -pipe -fPIC $CPU_FLAGS -fno-math-errno -falign-functions=32 -fstrict-aliasing -ffunction-sections -fdata-sections -fveclib=Accelerate -mllvm -inline-threshold=800 -mllvm -import-instr-limit=500"
export MPV_FFMPEG_CXX_DISABLE="-fno-exceptions -fno-rtti"
export LINK_PATH="-Wl,-dead_strip -lclang_rt.osx -L$LLVM_RES/lib/darwin -L$LLVM_UNWIND_RUNTIME_DIR -L$LLVM_CXX_RUNTIME_DIR $LLVM_RUNTIME_LINK_FLAGS -framework Accelerate"
export INCLUDE_PATH=""
linker_flags="$OPTIMIZATIONS -fuse-ld=${ld64_lld} $LLVM_LINK_BUNDLE $LINK_PATH -L${ffmpeg_prefix}/lib -L${source_prefix}/lib -L${vcpkg_target_prefix}/lib"
export CFLAGS="$OPTIMIZATIONS $LLVM_C_BUNDLE $INCLUDE_PATH"
export CXXFLAGS="$OPTIMIZATIONS $LLVM_CXX_BUNDLE $INCLUDE_PATH"
export OBJCFLAGS="$OPTIMIZATIONS $LLVM_C_BUNDLE $INCLUDE_PATH"
export OBJCXXFLAGS="$OPTIMIZATIONS $LLVM_CXX_BUNDLE $INCLUDE_PATH"
export LDFLAGS="$linker_flags"
export SOURCE_LDFLAGS="$linker_flags"
export PKG_CONFIG_PATH="$pkg_config_path"
export PKG_CONFIG_LIBDIR="$pkg_config_path"
export LIBRARY_PATH="$library_path"
export DYLD_LIBRARY_PATH="$dyld_library_path"
export CPATH="$cpath"
export CMAKE_PREFIX_PATH="$cmake_prefix_path"
export CARGO_PROFILE_RELEASE_OPT_LEVEL=3
export CARGO_PROFILE_RELEASE_LTO=thin
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
rust_codegen_flags="-C opt-level=3 -C codegen-units=1 -C target-cpu=apple-m4 -C relocation-model=pic -C llvm-args=-inline-threshold=800 -C llvm-args=-import-instr-limit=500"
rust_link_flags="-C link-arg=-fuse-ld=$ld64_lld -C link-arg=-Wl,-dead_strip -C link-arg=-lclang_rt.osx -C link-arg=-L$LLVM_RES/lib/darwin -C link-arg=-L$LLVM_UNWIND_RUNTIME_DIR -C link-arg=-L$LLVM_CXX_RUNTIME_DIR -C link-arg=-nostdlib++ -C link-arg=-Wl,-rpath,$LLVM_CXX_RUNTIME_DIR -C link-arg=-Wl,-rpath,$LLVM_UNWIND_RUNTIME_DIR -C link-arg=-Wl,-needed_library,$LLVM_LIBCXX_DYLIB -C link-arg=-Wl,-needed_library,$LLVM_LIBCXXABI_DYLIB -C link-arg=-Wl,-needed_library,$LLVM_LIBUNWIND_DYLIB -C link-arg=-framework -C link-arg=Accelerate -C link-arg=-L${ffmpeg_prefix}/lib -C link-arg=-L${source_prefix}/lib -C link-arg=-L${vcpkg_target_prefix}/lib"
export CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER="$CC"
export CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS="$rust_codegen_flags $rust_link_flags"
export RUSTFLAGS="$CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS"

{
  echo "SOURCE_PREFIX=$SOURCE_PREFIX"
  echo "FFMPEG_PREFIX=$FFMPEG_PREFIX"
  echo "FFMPEG_LGPL_PREFIX=$FFMPEG_LGPL_PREFIX"
  echo "SOURCE_ROOT=$SOURCE_ROOT"
  echo "BUILD_ROOT=$BUILD_ROOT"
  echo "PYTHON_VENV=$PYTHON_VENV"
  echo "VCPKG_INSTALLED_DIR=$VCPKG_INSTALLED_DIR"
  echo "VCPKG_TARGET_PREFIX=$VCPKG_TARGET_PREFIX"
  echo "VCPKG_BINARY_CACHE=$VCPKG_BINARY_CACHE"
  echo "VCPKG_BINARY_SOURCES=$VCPKG_BINARY_SOURCES"
  echo "NUGET_CACHE_MODE=$NUGET_CACHE_MODE"
  echo "NUGET_CACHE_REASON=$NUGET_CACHE_REASON"
  echo "NUGET_FEED_URL=$NUGET_FEED_URL"
  echo "NUGET_SOURCE_NAME=$NUGET_SOURCE_NAME"
  echo "NUGET_CONFIG_PATH=$NUGET_CONFIG_PATH"
  echo "MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
  echo "CMAKE_OSX_DEPLOYMENT_TARGET=$CMAKE_OSX_DEPLOYMENT_TARGET"
  echo "LLVM_PREFIX=$LLVM_PREFIX"
  echo "LLD_PREFIX=$LLD_PREFIX"
  echo "LD64_LLD=$LD64_LLD"
  echo "RUSTC=$RUSTC"
  echo "CC=$CC"
  echo "CXX=$CXX"
  echo "OBJC=$OBJC"
  echo "OBJCXX=$OBJCXX"
  echo "AR=$AR"
  echo "RANLIB=$RANLIB"
  echo "STRIP=$STRIP"
  echo "NM=$NM"
  echo "LLVM_RANLIB=$LLVM_RANLIB"
  echo "LLVM_CXX_RUNTIME_DIR=$LLVM_CXX_RUNTIME_DIR"
  echo "LLVM_UNWIND_RUNTIME_DIR=$LLVM_UNWIND_RUNTIME_DIR"
  echo "LLVM_LIBCXX_DYLIB=$LLVM_LIBCXX_DYLIB"
  echo "LLVM_LIBCXXABI_DYLIB=$LLVM_LIBCXXABI_DYLIB"
  echo "LLVM_LIBUNWIND_DYLIB=$LLVM_LIBUNWIND_DYLIB"
  echo "VCPKG_TARGET_CC=$VCPKG_TARGET_CC"
  echo "VCPKG_TARGET_CXX=$VCPKG_TARGET_CXX"
  echo "VCPKG_TARGET_OBJC=$VCPKG_TARGET_OBJC"
  echo "VCPKG_TARGET_OBJCXX=$VCPKG_TARGET_OBJCXX"
  echo "VCPKG_TARGET_AR=$VCPKG_TARGET_AR"
  echo "VCPKG_TARGET_RANLIB=$VCPKG_TARGET_RANLIB"
  echo "VCPKG_TARGET_STRIP=$VCPKG_TARGET_STRIP"
  echo "VCPKG_TARGET_NM=$VCPKG_TARGET_NM"
  echo "LLVM_RES=$LLVM_RES"
  echo "LLVM_RESOURCE_FLAG=$LLVM_RESOURCE_FLAG"
  echo "LLVM_C_BUNDLE=$LLVM_C_BUNDLE"
  echo "LLVM_CXX_BUNDLE=$LLVM_CXX_BUNDLE"
  echo "LLVM_LINK_BUNDLE=$LLVM_LINK_BUNDLE"
  echo "LLVM_BUNDLE=$LLVM_BUNDLE"
  echo "LLVM_RUNTIME_LINK_FLAGS=$LLVM_RUNTIME_LINK_FLAGS"
  echo "CPU_FLAGS=$CPU_FLAGS"
  echo "OPTIMIZATIONS=$OPTIMIZATIONS"
  echo "MPV_FFMPEG_CXX_DISABLE=$MPV_FFMPEG_CXX_DISABLE"
  echo "LINK_PATH=$LINK_PATH"
  echo "INCLUDE_PATH=$INCLUDE_PATH"
  echo "CFLAGS=$CFLAGS"
  echo "CXXFLAGS=$CXXFLAGS"
  echo "OBJCFLAGS=$OBJCFLAGS"
  echo "OBJCXXFLAGS=$OBJCXXFLAGS"
  echo "LDFLAGS=$LDFLAGS"
  echo "SOURCE_LDFLAGS=$SOURCE_LDFLAGS"
  echo "PKG_CONFIG_PATH=$PKG_CONFIG_PATH"
  echo "PKG_CONFIG_LIBDIR=$PKG_CONFIG_LIBDIR"
  echo "LIBRARY_PATH=$LIBRARY_PATH"
  echo "DYLD_LIBRARY_PATH=$DYLD_LIBRARY_PATH"
  echo "CPATH=$CPATH"
  echo "CMAKE_PREFIX_PATH=$CMAKE_PREFIX_PATH"
  echo "CARGO_PROFILE_RELEASE_OPT_LEVEL=$CARGO_PROFILE_RELEASE_OPT_LEVEL"
  echo "CARGO_PROFILE_RELEASE_LTO=$CARGO_PROFILE_RELEASE_LTO"
  echo "CARGO_PROFILE_RELEASE_CODEGEN_UNITS=$CARGO_PROFILE_RELEASE_CODEGEN_UNITS"
  echo "CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER=$CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER"
  echo "CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS=$CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS"
  echo "RUSTFLAGS=$RUSTFLAGS"
} >> "$GITHUB_ENV"

for bin_path in "${bin_paths[@]}"; do
  echo "$bin_path" >> "$GITHUB_PATH"
done
echo "$tool_root" >> "$GITHUB_PATH"

for tool in "$CC" "$CXX" "$AR" "$RANLIB" "$VCPKG_TARGET_RANLIB" "$STRIP" "$LD64_LLD"; do
  test -x "$tool"
  "$tool" --version | head -n1
done

[[ -x "$RUSTC" ]] || die "Homebrew Rust compiler is not executable: $RUSTC"
"$RUSTC" --version --verbose
"$RUSTC" --print cfg --target aarch64-apple-darwin

tmpdir="$(mktemp -d)"
printf 'int main(void){return 0;}\n' > "$tmpdir/probe.c"
"$CC" $CFLAGS -fuse-ld="$LD64_LLD" $LLVM_LINK_BUNDLE -Wl,-dead_strip "$tmpdir/probe.c" -o "$tmpdir/probe"
"$tmpdir/probe"
