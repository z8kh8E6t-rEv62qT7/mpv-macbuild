#!/usr/bin/env python3
"""Generate the package retention audit for the macOS CI build."""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from glob import glob

import ci_matrix


def run(args: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(args, cwd=cwd, text=True, capture_output=True, check=False)
    except FileNotFoundError as exc:
        return subprocess.CompletedProcess(args, 127, "", f"{exc}\n")


def run_shell(script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["bash", "-lc", script], text=True, capture_output=True, check=False)


def combined_output(result: subprocess.CompletedProcess[str]) -> str:
    return f"{result.stdout}{result.stderr}"


def first_line(args: list[str]) -> str:
    result = run(args)
    return combined_output(result).splitlines()[0] if combined_output(result).splitlines() else ""


def read_feature_line(mpv_dir: Path) -> str:
    log = mpv_dir / "build/meson-logs/meson-log.txt"
    if not log.exists():
        return ""
    feature_line = ""
    for line in log.read_text(errors="replace").splitlines():
        marker = "List of enabled features: "
        if marker in line:
            feature_line = line.split(marker, 1)[1]
    return feature_line


def read_meson_build_options(mpv_dir: Path) -> dict[str, str]:
    options_path = mpv_dir / "build/meson-info/intro-buildoptions.json"
    if not options_path.exists():
        return {}

    options = json.loads(options_path.read_text(encoding="utf-8", errors="replace"))
    return {
        str(option.get("name", "")): str(option.get("value", ""))
        for option in options
        if isinstance(option, dict)
    }


class Audit:
    def __init__(self) -> None:
        self.lines: list[str] = []
        self.failures = 0

    def add(self, text: str = "") -> None:
        self.lines.append(text)

    def row(self, name: str, status: str, detail: str) -> None:
        self.add(f"| {name} | {status} | {detail} |")

    def fail(self, name: str, detail: str) -> None:
        self.row(name, "FAIL", detail)
        self.failures += 1


def read_archive_symbols(nm: str, archive: Path, selection: str) -> tuple[set[str], str]:
    result = run(
        [
            nm,
            selection,
            "--extern-only",
            "--format=just-symbols",
            str(archive),
        ]
    )
    if result.returncode != 0:
        return set(), combined_output(result).strip()
    return set(result.stdout.splitlines()), ""


def audit_libbluray_helper_symbols(audit: Audit, nm: str, archive: Path) -> None:
    check_name = "libbluray helper symbol isolation"
    if not archive.is_file():
        audit.fail(check_name, f"archive is missing: {archive}")
        return

    defined_symbols, error = read_archive_symbols(nm, archive, "--defined-only")
    if error:
        audit.fail(check_name, f"defined-symbol inspection failed: {error}")
        return
    undefined_symbols, error = read_archive_symbols(nm, archive, "--undefined-only")
    if error:
        audit.fail(check_name, f"undefined-symbol inspection failed: {error}")
        return

    generic_symbols = {"_dir_open_default", "_file_open_default"}
    renamed_symbols = {
        "_libbluray_dir_open_default",
        "_libbluray_file_open_default",
    }
    leaked_symbols = sorted(generic_symbols & (defined_symbols | undefined_symbols))
    missing_symbols = sorted(renamed_symbols - defined_symbols)
    if leaked_symbols:
        audit.fail(check_name, f"generic symbols remain: {', '.join(leaked_symbols)}")
    elif missing_symbols:
        audit.fail(check_name, f"renamed symbols are missing: {', '.join(missing_symbols)}")
    else:
        audit.row(
            check_name,
            "OK",
            "dir_open_default and file_open_default use libbluray-prefixed symbols",
        )


def pkg_config_exists(package: str) -> bool:
    return run(["pkg-config", "--exists", package]).returncode == 0


def pkg_config_value(package: str, variable: str) -> str:
    result = run(["pkg-config", f"--variable={variable}", package])
    return result.stdout.strip()


def pkg_config_modversion(package: str) -> str:
    result = run(["pkg-config", "--modversion", package])
    return result.stdout.strip()


def pkg_config_static_libs(package: str) -> str:
    result = run(["pkg-config", "--libs", "--static", package])
    return result.stdout.strip()


def matching_paths(patterns: list[str], env: dict[str, str]) -> list[str]:
    matches: list[str] = []
    for pattern in patterns:
        matches.extend(sorted(glob(pattern.format(**env))))
    return matches


def main() -> int:
    env = os.environ
    builder_dir = Path(env["BUILDER_DIR"])
    mpv_dir = Path(env["MPV_DIR"])
    audit_dir = Path(env["AUDIT_DIR"])
    source_root = Path(env["SOURCE_ROOT"])
    source_prefix = env["SOURCE_PREFIX"]
    ffmpeg_prefix = env["FFMPEG_PREFIX"]
    vcpkg_target_prefix = env["VCPKG_TARGET_PREFIX"]
    github_summary = Path(env["GITHUB_STEP_SUMMARY"])
    nuget_cleanup_report = audit_dir / "nuget-cleanup.json"
    libbluray_archive = Path(vcpkg_target_prefix) / "lib" / "libbluray.a"

    audit_dir.mkdir(parents=True, exist_ok=True)
    report = audit_dir / "package-audit.md"
    vulkan_headers_config = Path(ci_matrix.VULKAN_HEADERS_CONFIG_PATH.format(**env))
    vulkan_headers_config_version = Path(ci_matrix.VULKAN_HEADERS_CONFIG_VERSION_PATH.format(**env))
    vulkan_registry_xml = Path(ci_matrix.VULKAN_HEADERS_REGISTRY_XML_PATH.format(**env))

    ffmpeg_bin = Path(ffmpeg_prefix) / "bin/ffmpeg"
    ffprobe_bin = Path(ffmpeg_prefix) / "bin/ffprobe"
    ffplay_bin = Path(ffmpeg_prefix) / "bin/ffplay"
    feature_line = read_feature_line(mpv_dir)
    mpv_build_options = read_meson_build_options(mpv_dir)
    ffmpeg_buildconf = combined_output(run([str(ffmpeg_bin), "-hide_banner", "-buildconf"]))

    audit = Audit()
    audit.add("# Static Source Package Retention Audit")
    audit.add()
    audit.add(f"- mpv ref: {env.get('RESOLVED_MPV_REF', 'unknown')}")
    audit.add(f"- FFmpeg ref: {env.get('RESOLVED_FFMPEG_REF', 'unknown')}")
    audit.add("- runner: macos-15 arm64")
    audit.add(f"- compiler: {first_line([env['CC'], '--version'])}")
    audit.add(f"- linker: {first_line([env['LD64_LLD'], '--version'])}")
    audit.add("- optimization: M4 thin-LTO LLVM bundle for source-built C/C++ components")
    audit.add(f"- source prefix: {source_prefix}")
    audit.add(f"- FFmpeg prefix: {ffmpeg_prefix}")
    audit.add(f"- vcpkg static prefix: {vcpkg_target_prefix}")
    audit.add(f"- vcpkg binary cache: {env.get('VCPKG_BINARY_CACHE', '')}")
    audit.add(f"- vcpkg binary sources: `{env.get('VCPKG_BINARY_SOURCES', '')}`")
    audit.add(f"- NuGet cache mode: `{env.get('NUGET_CACHE_MODE', '')}`")
    audit.add(f"- NuGet cache reason: {env.get('NUGET_CACHE_REASON', '')}")
    audit.add(f"- NuGet feed: `{env.get('NUGET_FEED_URL', '')}`")
    audit.add(f"- macOS deployment target: `{env['MACOSX_DEPLOYMENT_TARGET']}`")
    audit.add(f"- LLVM resource dir: {env['LLVM_RES']}")
    audit.add(f"- LLVM ranlib: `{env.get('LLVM_RANLIB', env.get('RANLIB', ''))}`")
    audit.add(f"- vcpkg target ranlib: `{env.get('VCPKG_TARGET_RANLIB', '')}`")
    audit.add(f"- LLVM C++ runtime dir: `{env.get('LLVM_CXX_RUNTIME_DIR', '')}`")
    audit.add(f"- LLVM unwind runtime dir: `{env.get('LLVM_UNWIND_RUNTIME_DIR', '')}`")
    audit.add(f"- LLVM libc++ dylib: `{env.get('LLVM_LIBCXX_DYLIB', '')}`")
    audit.add(f"- LLVM libc++abi dylib: `{env.get('LLVM_LIBCXXABI_DYLIB', '')}`")
    audit.add(f"- LLVM libunwind dylib: `{env.get('LLVM_LIBUNWIND_DYLIB', '')}`")
    audit.add(f"- CPU flags: `{env['CPU_FLAGS']}`")
    audit.add(f"- optimizations: `{env['OPTIMIZATIONS']}`")
    audit.add(f"- LLVM bundle: `{env['LLVM_BUNDLE']}`")
    audit.add(f"- LLVM resource flag: `{env.get('LLVM_RESOURCE_FLAG', '')}`")
    audit.add(f"- LLVM C compile bundle: `{env.get('LLVM_C_BUNDLE', '')}`")
    audit.add(f"- LLVM C++ compile bundle: `{env.get('LLVM_CXX_BUNDLE', '')}`")
    audit.add(f"- LLVM link bundle: `{env.get('LLVM_LINK_BUNDLE', '')}`")
    audit.add(f"- LLVM runtime link flags: `{env.get('LLVM_RUNTIME_LINK_FLAGS', '')}`")
    audit.add(f"- link path: `{env['LINK_PATH']}`")
    audit.add(f"- include path: `{env['INCLUDE_PATH']}`")
    audit.add(f"- mpv/FFmpeg C++ disable flags: `{env['MPV_FFMPEG_CXX_DISABLE']}`")
    audit.add(f"- Cargo target linker: `{env.get('CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER', '')}`")
    audit.add(f"- Cargo target Rust flags: `{env.get('CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS', '')}`")
    audit.add(f"- Cargo Rust flags: `{env.get('RUSTFLAGS', '')}`")
    if nuget_cleanup_report.exists():
        cleanup_data = json.loads(nuget_cleanup_report.read_text(encoding="utf-8"))
        audit.add(f"- NuGet cleanup managed packages: {cleanup_data.get('managed_packages', 0)}")
        audit.add(f"- NuGet cleanup deleted stale versions: {cleanup_data.get('deleted_version_count', 0)}")
    audit.add()
    audit.add("## vcpkg static triplet flags")
    audit.add()
    audit.add("| Item | Value |")
    audit.add("| --- | --- |")
    audit.add("| VCPKG_LIBRARY_LINKAGE | static |")
    audit.add("| VCPKG_CHAINLOAD_TOOLCHAIN_FILE | cmake/toolchains/brew-llvm.cmake |")
    audit.add(f"| VCPKG_TARGET_CC | `{env.get('VCPKG_TARGET_CC', env['CC'])}` |")
    audit.add(f"| VCPKG_TARGET_CXX | `{env.get('VCPKG_TARGET_CXX', env['CXX'])}` |")
    audit.add(f"| VCPKG_TARGET_AR | `{env.get('VCPKG_TARGET_AR', env['AR'])}` |")
    audit.add(f"| VCPKG_TARGET_RANLIB | `{env.get('VCPKG_TARGET_RANLIB', env['RANLIB'])}` |")
    audit.add(f"| VCPKG_C_FLAGS | `{env['OPTIMIZATIONS']} {env.get('LLVM_C_BUNDLE', '')} {env['INCLUDE_PATH']}` |")
    audit.add(f"| VCPKG_CXX_FLAGS | `{env['OPTIMIZATIONS']} {env.get('LLVM_CXX_BUNDLE', '')} {env['INCLUDE_PATH']}` |")
    audit.add(
        f"| VCPKG_LINKER_FLAGS | `{env['OPTIMIZATIONS']} -fuse-ld={env['LD64_LLD']} "
        f"{env.get('LLVM_LINK_BUNDLE', '')} {env['LINK_PATH']} -L{ffmpeg_prefix}/lib -L{source_prefix}/lib "
        f"-L{vcpkg_target_prefix}/lib` |"
    )
    audit.add()
    audit.add("## Source revisions")
    audit.add()
    audit.add("| Component | Ref | Commit |")
    audit.add("| --- | --- | --- |")
    for item in ci_matrix.SOURCE_REVISION_ITEMS:
        repo = source_root / item
        if (repo / ".git").is_dir():
            ref = run(["git", "-C", str(repo), "rev-parse", "--abbrev-ref", "HEAD"]).stdout.strip()
            commit = run(["git", "-C", str(repo), "rev-parse", "HEAD"]).stdout.strip()
            audit.row(item, ref, commit)
    audit.add()
    audit.add("## Applied source patches")
    audit.add()
    audit.add("| Patch | SHA256 |")
    audit.add("| --- | --- |")
    missing_patches = []
    for patch_rel in ci_matrix.APPLIED_PATCHES:
        patch = builder_dir / patch_rel
        if patch.exists():
            digest = hashlib.sha256(patch.read_bytes()).hexdigest()
        else:
            digest = "missing"
            missing_patches.append(patch.name)
        audit.add(f"| {patch.name} | {digest} |")
    audit.add()
    audit.add("## Enabled mpv features")
    audit.add()
    audit.add(f"`{feature_line}`")
    audit.add()
    audit.add("## Required checks")
    audit.add()
    audit.add("| Item | Status | Detail |")
    audit.add("| --- | --- | --- |")

    for patch_name in missing_patches:
        audit.fail(f"source patch: {patch_name}", "patch file is missing")

    if not feature_line:
        audit.fail("mpv enabled feature list", "Meson log did not contain 'List of enabled features'")
    feature_words = set(feature_line.split())
    for feature in ci_matrix.MPV_FEATURES:
        if feature in feature_words:
            audit.row(f"mpv feature: {feature}", "OK", "enabled by Meson")
        else:
            audit.fail(f"mpv feature: {feature}", "missing from Meson's enabled feature list")

    for option, expected_value in ci_matrix.MPV_BUILD_OPTIONS:
        actual_value = mpv_build_options.get(option)
        if actual_value == expected_value:
            audit.row(f"mpv option: {option}", "OK", f"{option}={actual_value}")
        elif actual_value is None:
            audit.fail(f"mpv option: {option}", "missing from Meson build options")
        else:
            audit.fail(f"mpv option: {option}", f"expected {expected_value}, got {actual_value}")

    for formula in ci_matrix.HOMEBREW_BUILD_TOOLS:
        if run(["brew", "list", "--formula", formula]).returncode == 0:
            audit.row(f"Homebrew build tool: {formula}", "OK", "installed")
        else:
            audit.fail(f"Homebrew build tool: {formula}", "formula is not installed")

    for formula in ci_matrix.FORBIDDEN_HOMEBREW_RUNTIME_FORMULAS:
        if run(["brew", "list", "--formula", formula]).returncode == 0:
            audit.row(
                f"Homebrew runtime formula ignored: {formula}",
                "OK",
                "installed on runner but excluded from PKG_CONFIG_LIBDIR/CMAKE_PREFIX_PATH",
            )

    for package in ci_matrix.PKG_CONFIG_PACKAGES:
        if pkg_config_exists(package):
            audit.row(f"pkg-config: {package}", "OK", pkg_config_modversion(package))
        else:
            audit.fail(f"pkg-config: {package}", "not visible through source PKG_CONFIG_LIBDIR")

    for package in ci_matrix.SOURCE_PREFIX_PACKAGES:
        value = pkg_config_value(package, "prefix")
        if value.startswith(source_prefix):
            audit.row(f"source-built pkg-config: {package}", "OK", f"prefix={value}")
        else:
            audit.fail(f"source-built pkg-config: {package}", f"prefix resolved outside source prefix: {value}")

    for package in ci_matrix.VCPKG_PREFIX_PACKAGES:
        value = pkg_config_value(package, "prefix")
        if value.startswith(vcpkg_target_prefix):
            audit.row(f"vcpkg pkg-config: {package}", "OK", f"prefix={value}")
        else:
            audit.fail(f"vcpkg pkg-config: {package}", f"prefix resolved outside vcpkg prefix: {value}")

    audit_libbluray_helper_symbols(audit, env["NM"], libbluray_archive)

    if vulkan_headers_config.is_file():
        audit.row("source-built Vulkan headers config", "OK", str(vulkan_headers_config))
    else:
        audit.fail("source-built Vulkan headers config", f"missing: {vulkan_headers_config}")

    if vulkan_registry_xml.is_file():
        audit.row("source-built Vulkan registry", "OK", str(vulkan_registry_xml))
    else:
        audit.fail("source-built Vulkan registry", f"missing: {vulkan_registry_xml}")

    if vulkan_headers_config_version.is_file():
        config_version_text = vulkan_headers_config_version.read_text(encoding="utf-8", errors="replace")
        if ci_matrix.VULKAN_SDK_VERSION in config_version_text:
            audit.row(
                "source-built Vulkan headers version",
                "OK",
                f"matches {ci_matrix.VULKAN_SDK_TAG}",
            )
        else:
            audit.fail(
                "source-built Vulkan headers version",
                f"{vulkan_headers_config_version} does not contain {ci_matrix.VULKAN_SDK_VERSION}",
            )
    else:
        audit.fail("source-built Vulkan headers version", f"missing: {vulkan_headers_config_version}")

    for package in ci_matrix.FFMPEG_PREFIX_PACKAGES:
        value = pkg_config_value(package, "prefix")
        if value.startswith(ffmpeg_prefix):
            audit.row(f"FFmpeg pkg-config: {package}", "OK", f"prefix={value}")
        else:
            audit.fail(f"FFmpeg pkg-config: {package}", f"prefix resolved outside FFmpeg prefix: {value}")

    for package in ci_matrix.STATIC_PKG_CONFIG_PACKAGES:
        libs = pkg_config_static_libs(package)
        if "/opt/homebrew" in libs:
            audit.fail(f"static pkg-config: {package}", f"static link flags reference Homebrew: {libs}")
        elif ".dylib" in libs:
            audit.fail(f"static pkg-config: {package}", f"static link flags reference dylib: {libs}")
        else:
            audit.row(f"static pkg-config: {package}", "OK", libs)

    for binary, label in [
        (ffmpeg_bin, "ffmpeg"),
        (ffprobe_bin, "ffprobe"),
        (ffplay_bin, "ffplay"),
    ]:
        if binary.is_file() and os.access(binary, os.X_OK):
            audit.row(f"FFmpeg binary: {label}", "OK", str(binary))
        else:
            audit.fail(f"FFmpeg binary: {label}", "source-built binary missing from FFmpeg prefix")

    for name, flag in ci_matrix.FFMPEG_FLAGS:
        if flag in ffmpeg_buildconf:
            audit.row(f"FFmpeg component: {name}", "OK", flag)
        else:
            audit.fail(f"FFmpeg component: {name}", f"{flag} missing from ffmpeg -buildconf")

    for option, name, pattern in ci_matrix.FFMPEG_RUNTIME_CHECKS:
        output = combined_output(run([str(ffmpeg_bin), "-hide_banner", option]))
        if re.search(pattern, output):
            audit.row(name, "OK", f"listed by ffmpeg {option}")
        else:
            audit.fail(name, f"missing from ffmpeg {option}")

    hwaccels = combined_output(run([str(ffmpeg_bin), "-hide_banner", "-hwaccels"]))
    if "videotoolbox" in hwaccels:
        audit.row("FFmpeg hwaccel: videotoolbox", "OK", "listed by ffmpeg -hwaccels")
    else:
        audit.fail("FFmpeg hwaccel: videotoolbox", "missing from ffmpeg -hwaccels")

    source_vulkan_runtime = matching_paths(ci_matrix.VULKAN_RUNTIME_SOURCE_GLOBS, env)
    if source_vulkan_runtime:
        audit.row(
            "Vulkan runtime exception: source prefix",
            "OK",
            ", ".join(Path(path).name for path in source_vulkan_runtime),
        )
    else:
        audit.fail("Vulkan runtime exception: source prefix", "missing source-built Vulkan runtime files")

    ffmpeg_vulkan_runtime = matching_paths(ci_matrix.VULKAN_RUNTIME_FFMPEG_GLOBS, env)
    if ffmpeg_vulkan_runtime:
        audit.row(
            "Vulkan runtime exception: FFmpeg prefix",
            "OK",
            ", ".join(Path(path).name for path in ffmpeg_vulkan_runtime),
        )
    else:
        audit.fail("Vulkan runtime exception: FFmpeg prefix", "missing bundled Vulkan runtime files")

    lua_script = (
        f'eval "$(luarocks --tree "{source_prefix}/luarocks" --lua-version=5.1 path --bin)" '
        "&& luajit -e 'require(\"socket\")'"
    )
    lua_result = run_shell(lua_script)
    if lua_result.returncode == 0:
        audit.row("source-built plugin exception: luasocket", "OK", "luajit can require socket")
    else:
        audit.fail(
            "source-built plugin exception: luasocket",
            f"luajit cannot require socket: {combined_output(lua_result).strip()}",
        )

    luajit_pcall_script = (
        'luajit -e \''
        'local ok, err = pcall(error, "plain-error"); '
        'assert(ok == false and err == "plain-error"); '
        'local loaded, require_err = pcall(require, "definitely-missing-mpv-macbuild-smoke-module"); '
        'assert(loaded == false, "missing module unexpectedly loaded"); '
        'assert(type(require_err) == "string", "missing module error is not a string"); '
        'assert(require_err:match("module .- not found"), require_err)'
        '\''
    )
    luajit_pcall_result = run_shell(luajit_pcall_script)
    if luajit_pcall_result.returncode == 0:
        audit.row("source-built LuaJIT protected require", "OK", "missing require is caught by pcall")
    else:
        audit.fail(
            "source-built LuaJIT protected require",
            f"pcall(require missing) failed: {combined_output(luajit_pcall_result).strip()}",
        )

    audit.add()
    audit.add("## Mapped, plugin-exception, or not-applicable package decisions")
    audit.add()
    audit.add("| Item | Status | Detail |")
    audit.add("| --- | --- | --- |")
    for item, status, detail in ci_matrix.MAPPED_DECISIONS:
        audit.row(item, status, detail.format(**env))

    report.write_text("\n".join(audit.lines) + "\n", encoding="utf-8")
    with github_summary.open("a", encoding="utf-8") as summary:
        summary.write(report.read_text(encoding="utf-8"))

    if audit.failures:
        print(f"Package retention audit failed with {audit.failures} missing required item(s).", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
