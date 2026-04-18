# ↕️ fx-upscale

Metal-powered video upscaling

## Usage

```txt
USAGE: fx-upscale <url> [--width <width>] [--height <height>] [--codec <codec>] [--quality <quality>]

ARGUMENTS:
  <url>                   The video file to upscale

OPTIONS:
  -w, --width <width>     The output file width
  -H, --height <height>   The output file height
  -c, --codec <codec>     Output codec: 'hevc' or 'h264' (default: h264)
  -q, --quality <quality> Output quality: 1-100 (default: encoder default)
  -h, --help              Show help information.
```

- If width and height are specified, they will be used for the output dimensions
- If only 1 of width or height is specified, the other will be inferred proportionally
- If neither width nor height is specified, the video will be upscaled by 2x
- Output dimensions are rounded up to the nearest even number (required by H.264 / HEVC)
- Quality controls the VideoToolbox encoder constant quality (1 = lowest, 100 = highest). If not specified, the encoder default is used.
- HDR video (PQ / HLG transfer functions) is not supported and will be rejected — the 8-bit BGRA MetalFX path would silently clip HDR pixels.

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
