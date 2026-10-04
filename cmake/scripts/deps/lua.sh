#!/usr/bin/env bash

strip_lto_flags() {
  local flag
  local -a kept=()

  for flag in "$@"; do
    case "$flag" in
      -flto|-flto=*) ;;
      *) kept+=("$flag") ;;
    esac
  done

  printf '%s' "${kept[*]}"
}

assert_luajit_protected_require_works() {
  luajit -e '
local ok, err = pcall(error, "plain-error")
assert(ok == false and err == "plain-error")

local loaded, require_err = pcall(require, "definitely-missing-mpv-macbuild-smoke-module")
assert(loaded == false, "missing module unexpectedly loaded")
assert(type(require_err) == "string", "missing module error is not a string")
assert(require_err:match("module .- not found"), require_err)
'
}

build_luajit() {
  # LuaJIT's VM/error unwinding is not safe under the global ThinLTO flags:
  # pcall(require, "missing") can bypass the protected frame and panic.
  local luajit_cflags
  local luajit_ldflags
  local -a luajit_make_args

  luajit_cflags="$(strip_lto_flags $CFLAGS)"
  luajit_ldflags="$(strip_lto_flags $LDFLAGS)"
  luajit_make_args=(
    PREFIX="$SOURCE_PREFIX"
    CC="$CC"
    CFLAGS="$luajit_cflags"
    LDFLAGS="$luajit_ldflags"
    TARGET_AR="$AR rcus"
    # LuaSocket modules use Darwin dynamic_lookup; keep Lua C API globals
    # exported from the luajit host used for runtime validation.
    TARGET_LDFLAGS="-Wl,-export_dynamic"
    TARGET_STRIP="$STRIP"
    STATIC_CC="$CC"
    DYNAMIC_CC="$CC -fPIC"
  )

  clone_or_update https://github.com/LuaJIT/LuaJIT.git "$SOURCE_ROOT/luajit"
  make -C "$SOURCE_ROOT/luajit" clean
  make -C "$SOURCE_ROOT/luajit" -j"$(ci_jobs)" amalg \
    "${luajit_make_args[@]}"
  make -C "$SOURCE_ROOT/luajit" install \
    "${luajit_make_args[@]}"
  remove_dynamic_artifacts
  pkg-config --exists luajit
  assert_luajit_protected_require_works
}

build_luasocket() {
  echo "Installing LuaSocket from source with LuaRocks variables: CC=$CC LD=$CC CFLAGS=$CFLAGS LDFLAGS=$LDFLAGS"
  luarocks --tree "$SOURCE_PREFIX/luarocks" --lua-version=5.1 --lua-dir="$SOURCE_PREFIX" install luasocket \
    CC="$CC" \
    LD="$CC" \
    CFLAGS="$CFLAGS -I$SOURCE_PREFIX/include/luajit-2.1" \
    LDFLAGS="$LDFLAGS"
  eval "$(luarocks --tree "$SOURCE_PREFIX/luarocks" --lua-version=5.1 path --bin)"
  luajit -e 'require("socket")'
}
