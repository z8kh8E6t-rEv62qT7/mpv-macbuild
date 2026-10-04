"""Non-compiling regression tests for image fixtures, audits and the GPL smoke boundary."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("image_smoke", ROOT / "scripts/smoke/smoke-lgpl-images.py")
IMAGES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IMAGES)


class ImageContractTests(unittest.TestCase):
    def test_fixture_integrity_and_coverage(self):
        fixtures = ROOT / "scripts/smoke/fixtures/images"
        cases = json.loads((fixtures / "manifest.json").read_text())
        self.assertEqual(len({case["file"] for case in cases}), len(cases))
        self.assertEqual({case["file"] for case in cases}, {
            "red.jpg", "red.png", "red.bmp", "red.tiff", "red-lzma.tiff", "red.exr",
            "red.webp", "red.avif", "red.heic", "alpha.png", "alpha.webp",
            "animated.png", "animated.gif", "animated.webp",
        })
        for case in cases:
            with self.subTest(file=case["file"]):
                data = (fixtures / case["file"]).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(), case["sha256"])
                self.assertEqual(case["frames"], 2 if case["file"].startswith("animated") else 1)
                for pixel in case["pixels"]:
                    self.assertLess(pixel["frame"], case["frames"])
                    self.assertLess(pixel["x"], case["width"])
                    self.assertLess(pixel["y"], case["height"])

    def test_rgba_checker_rejects_first_frame_only_and_wrong_alpha(self):
        case = {"width": 1, "height": 1, "frames": 2, "tolerance": 0,
                "pixels": [{"frame": 1, "x": 0, "y": 0, "rgba": [1, 2, 3, 64]}]}
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "image.rgba"
            output.write_bytes(bytes([1, 2, 3, 64]))
            with self.assertRaisesRegex(ValueError, "RGBA size"):
                IMAGES.verify_rgba(output, case)
            output.write_bytes(bytes([1, 2, 3, 64, 1, 2, 3, 255]))
            with self.assertRaisesRegex(ValueError, "pixel"):
                IMAGES.verify_rgba(output, case)
            output.write_bytes(bytes([1, 2, 3, 64]) * 2)
            IMAGES.verify_rgba(output, case)

    def test_layout_rejects_extra_libraries_and_escaping_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "artifact"
            (root / "lib/pkgconfig").mkdir(parents=True)
            (root / "include").mkdir()
            for library in ("avcodec", "avfilter", "avformat", "avutil", "swscale"):
                (root / "include" / f"lib{library}").mkdir()
                (root / "lib/pkgconfig" / f"lib{library}.pc").touch()
                (root / "lib" / f"lib{library}.dylib").touch()
            command = [sys.executable, str(ROOT / "scripts/audit/audit-lgpl-layout.py"), str(root)]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            extra = root / "lib/libswresample.dylib"
            extra.touch()
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            extra.unlink()
            link = root / "lib/libavcodec.dylib"
            link.unlink()
            link.symlink_to(ROOT / "README.md")
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)

    def test_config_audit_rejects_missing_animation_and_scope_expansion(self):
        decoders = "apng,bmp,exr,gif,hevc,libdav1d,mjpeg,png,tiff,webp,webp_anim"
        parsers = "av1,bmp,gif,hevc,mjpeg,png,webp"
        demuxers = "apng,gif,image2,image2pipe,image_bmp_pipe,image_exr_pipe,image_jpeg_pipe,image_png_pipe,image_tiff_pipe,image_webp_pipe,mov,webp_anim"
        values = {}
        for kind, names in {
            "DECODER": decoders + ",vp8", "PARSER": parsers, "DEMUXER": demuxers,
            "ENCODER": "rawvideo", "MUXER": "rawvideo", "PROTOCOL": "file",
            "FILTER": "aformat,anull,atrim,crop,format,hflip,null,rotate,transpose,trim,vflip,scale",
        }.items():
            values.update({name.upper() + "_" + kind: "1" for name in names.split(",")})
        for name in "AVCODEC AVFORMAT AVUTIL SWSCALE AVFILTER FFMPEG ZLIB LZMA LIBDAV1D".split():
            values[name] = "1"
        for name in "GPL VERSION3 NONFREE NETWORK AVDEVICE SWRESAMPLE FFPROBE FFPLAY LIBJXL LIBRSVG LIBAOM LIBWEBP BZLIB ICONV VIDEOTOOLBOX AUDIOTOOLBOX".split():
            values[name] = "0"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "config_components.h").touch()
            command = [sys.executable, str(ROOT / "scripts/audit/audit-lgpl-config.py"),
                       str(root), decoders, parsers, demuxers]

            def audit(configuration):
                (root / "config.h").write_text("".join(
                    f"#define CONFIG_{key} {value}\n" for key, value in configuration.items()))
                return subprocess.run(command, capture_output=True, text=True).returncode

            self.assertEqual(audit(values), 0)
            for name, value in (("WEBP_ANIM_DECODER", "0"), ("WEBP_ANIM_DEMUXER", "0"),
                                ("LIBDAV1D", "0"), ("GPL", "1"), ("LIBJXL", "1"),
                                ("AAC_DECODER", "1"), ("PNG_ENCODER", "1"),
                                ("HTTP_PROTOCOL", "1"), ("HEVC_VIDEOTOOLBOX_HWACCEL", "1")):
                with self.subTest(component=name):
                    self.assertNotEqual(audit(dict(values, **{name: value})), 0)

    def test_package_profiles_keep_gpl_contract(self):
        command = ['bash', '-c', 'source "$1"; ffmpeg_package_profile "$2"; '
                   'printf "%s\\n" "${ffmpeg_libraries[*]}" "${ffmpeg_tools[*]}"',
                   'bash', str(ROOT / 'scripts/lib/ffmpeg-package-common.sh')]
        for profile, expected in (
            ('gpl', ['avcodec avdevice avfilter avformat avutil swresample swscale', 'ffmpeg ffprobe ffplay']),
            ('lgpl', ['avcodec avfilter avformat avutil swscale', 'ffmpeg']),
        ):
            result = subprocess.run(command + [profile], capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.splitlines(), expected)

    def test_gpl_multimedia_cases_are_guarded(self):
        script = (ROOT / 'scripts/smoke/smoke-ffmpeg-artifact.sh').read_text()
        general = script.split('if [[ "$profile" == "gpl" ]]; then\n', 1)[1].split('\nelse\n', 1)[0]
        self.assertIn('run_case "jxl-encode"', general)
        self.assertIn('run_case "svg-librsvg-decode-null"', general)
        self.assertIn('run_case "lavfi-sine-flac"', general)
        self.assertIn('run_case "lavfi-testsrc-mkv"', general)
        self.assertIn('run_case "x264-default-null"', script)


if __name__ == "__main__":
    unittest.main()
