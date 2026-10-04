# Image preview fixtures

All images are original synthetic 64 × 64 pixel images created for this repository.
The image data is dedicated to the public domain under CC0-1.0:
https://creativecommons.org/publicdomain/zero/1.0/
There are no downloaded photographs or third-party image assets.

`manifest.json` records SHA-256, dimensions, frame counts, representative pixel
values and per-channel tolerances. Expected colors come from the input pixels,
not from output produced by the implementation under test. Solid red is
RGB (240, 32, 16); the second animation frame is RGB (16, 32, 240).
The lower half of the alpha fixtures is blue with alpha 64; the top is opaque red.

Generation provenance (not required by CI):

- Pillow 12.3.0: PNG, BMP, JPEG (quality 95, no chroma subsampling), TIFF
  (`tiff_deflate`), LZMA TIFF (`lzma`, verified compression tag 34925),
  lossless WebP, AVIF (quality 100, 4:4:4).
- Pillow 12.3.0: two-frame GIF/APNG/lossless WebP, 100 ms per frame;
  full-frame red followed by blue. APNG uses source blending and no disposal.
- macOS `sips -s format heic red.png --out red.heic`: single-image HEVC HEIF.
- Existing FFmpeg 239f2c7: synthetic RGB PPM to EXR using
  `ffmpeg -i red.ppm -frames:v 1 -c:v exr -compression zip16 red.exr`.

Reproduction source for Pillow: create RGB images with `Image.new("RGB", (64, 64),
color)`, then save with the settings above. For animation use `save_all=True`,
`append_images=[blue]`, `duration=100`, and `loop=1`. Alpha images use RGBA and
`paste((16, 32, 240, 64), (0, 32, 64, 64))` on an opaque red image.

Fixtures are committed binary inputs. Image generators, Pillow, sips and the
existing FFmpeg binary are not dependencies of the build or smoke job. Regenerating
fixtures requires reviewing and updating hashes; smoke never rewrites baselines.
