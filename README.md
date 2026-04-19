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
  -w, --width <width>     Output width
  -H, --height <height>   Output height
  -x, --scale <scale>     Uniform integer scale factor (e.g. 2 for 2×).
                          Mutually exclusive with --width / --height.
  -c, --codec <codec>     Output codec: h264 | hevc (default: h264)
  -q, --quality <quality> Encoder quality 1-100 (default: encoder default)
  -k, --keyframe-interval <s>
                          Max seconds between keyframes (default: 1.0)
  -f, --force             Overwrite the output file if it exists
  -s, --scaler <scaler>   Upscaling algorithm: spatial | super-resolution
                          (default: spatial)
  -d, --denoise <n>       Temporal noise-filter strength, 1-100
  -m, --motion-blur <n>   Motion-blur strength, 1-100 (50 ≈ 180° shutter)
  --fps <rate>            Target output frame rate (upsample only)
```

### Sizing

- `--scale N` applies a uniform integer factor on both axes.
- `--width` and/or `--height` give explicit dimensions; if only one is supplied,
  the other is computed from the source aspect ratio.
- `--scale` cannot be combined with `--width` or `--height`.
- Output dimensions are rounded up to the nearest even integer (required by
  H.264 / HEVC).
- **Scaling is opt-in.** With no sizing flag, the source resolution is
  preserved and only the requested effects (and codec) are applied — so
  `fx-upscale in.mp4 --codec hevc` is a pure re-encode.

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
