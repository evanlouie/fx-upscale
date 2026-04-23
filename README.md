# ↕️ fx-upscale

Metal-powered video upscaling.

## Usage

```txt
USAGE: fx-upscale <url> [--width <width>] [--height <height>] [--scale <scale>]
                        [--codec <codec>] [--quality <quality>]
                        [--keyframe-interval <keyframe-interval>] [--force]
                        [--scaler <scaler>] [--denoise <denoise>]
                        [--motion-blur <motion-blur>] [--fps <fps>]

ARGUMENTS:
  <url>                   The video file to upscale

OPTIONS:
  -w, --width <width>     Final encoded width
  -H, --height <height>   Final encoded height
  -x, --scale <scale>     Uniform integer scale factor for the scaler stage
                          (e.g. 2 for 2×). Independent of --width / --height.
  -c, --codec <codec>     Output codec: h264 | hevc (default: preserve source codec)
  -q, --quality <quality> Encoder quality 1-100 (default: encoder default)
  -k, --keyframe-interval <s>
                          Max seconds between keyframes (default: 1.0)
  -f, --force             Overwrite the output file if it exists
  -s, --scaler <scaler>   Upscaling algorithm: spatial | super-resolution
                          (default: spatial; only meaningful with --scale)
  -d, --denoise <n>       Temporal noise-filter strength, 1-100
  -m, --motion-blur <n>   Motion-blur strength, 1-100 (50 ≈ 180° shutter)
  --fps <rate>            Target output frame rate (upsample only)
```

### Sizing

`--scale` and `--width` / `--height` are independent:

- `--scale N` controls the scaler stage (how much MetalFX / VT super-resolution
  magnifies).
- `--width` / `--height` control the final encoded resolution.

Combine them for **supersampled downscaling**: the pipeline upscales with the
chosen scaler, then Lanczos-downsamples to the final size. Detail retained at
the final size exceeds what a direct encode of the source would preserve.

```bash
# Pure upscale (2× via MetalFX spatial).
fx-upscale in.mp4 --scale 2

# Pure downsample (Lanczos only, no scaler).
fx-upscale in_1080p.mp4 --height 720

# Supersampled downscale: upscale 2× to 2160p, then Lanczos to 1080p.
fx-upscale in_1080p.mp4 --scale 2 --height 1080

# Identity re-encode — codec / quality only.
fx-upscale in.mp4 --codec hevc
```

Rules:

- `--width` / `--height` larger than the source require `--scale` — they
  cannot upscale on their own.
- `--scaler X` requires `--scale` — it names a scaling algorithm but nothing
  uses it without `--scale`.
- If only one of `--width` / `--height` is supplied, the other is derived from
  the scaler output's aspect ratio.
- Dimensions are rounded up to the nearest even integer (required by H.264 /
  HEVC).
- With none of `--scale`, `--width`, `--height`: identity re-encode — the
  source resolution is preserved and only the requested effects (and codec)
  are applied.

> **Behavior note:** `--width` / `--height` no longer imply upscaling on their
> own — add `--scale N` to enable the scaler stage.

### Scalers

- `spatial` (default) — `MTLFXSpatialScaler`. Fast, arbitrary ratios.
- `super-resolution` — `VTFrameProcessor` ML-based super resolution. Higher
  quality on recorded video, but integer scale factor only, input capped at
  1920×1080 on macOS, and a one-time model download on first use.

### Effects

Each effect is applied only when its flag is passed:

- `--denoise N` — ML-based temporal noise filter, applied **before** scaling so
  the scaler isn't amplifying source noise.
- `--motion-blur N` — ML-based motion-blur synthesis on the scaled output.
- `--fps R` — ML-based frame-rate upconversion (upsample only; R must exceed
  the source rate).

### Encoder notes

- `--quality` sets the VideoToolbox constant-quality knob (1 = lowest,
  100 = highest).
- `--keyframe-interval 0` lets the encoder decide. HEVC can emit a single
  keyframe in that case, which breaks arrow-key seeking in some players
  (e.g. IINA). The default of 1.0s is a safe middle ground.
- HDR (PQ / HLG) and Rec. 2020 wide-gamut inputs are rejected — the 8-bit
  BGRA path would silently clip or shift those values.

## Installation

### Homebrew

```bash
brew install finnvoor/tools/fx-upscale
```

### Mint

```bash
mint install finnvoor/fx-upscale
```

### Manual

Download the latest release from [releases](https://github.com/Finnvoor/MetalFXUpscale/releases).
