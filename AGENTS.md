# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

## General

- MUST use conventional commit git messages.
- SHOULD proactively update existing documentation.
- MUST NOT create new documentation unless instructed to.
- SHOULD utilize LSP tools heavily.
- MUST prioritize LSP tools for semantic code retrieval and editing whenever they are available.  

## Build Commands

```bash
# Build
swift build

# Build for release
swift build -c release

# Run tests
swift test

# Build with xcodebuild (as CI does)
xcodebuild build -scheme Upscaling -destination "platform=macOS"
xcodebuild build -scheme Upscaling -destination "generic/platform=iOS"

# Format code (uses .swiftformat config)
swiftformat .
```

## Architecture

This is a Metal-powered video upscaling tool using Apple's MetalFX framework. It consists of two products:

1. **fx-upscale** (executable) - CLI tool using ArgumentParser for video upscaling
2. **Upscaling** (library) - Reusable upscaling library that can be embedded in other apps

### Core Components

- **Upscaler** (`Sources/Upscaling/Upscaler.swift`) - Wraps `MTLFXSpatialScaler` for GPU-accelerated upscaling of `CVPixelBuffer`s. Provides sync, async, and callback-based APIs.

- **UpscalingExportSession** (`Sources/Upscaling/UpscalingExportSession.swift`) - Manages full video export pipeline using `AVAssetReader`/`AVAssetWriter`. Handles audio passthrough, video track upscaling, and spatial video (MV-HEVC) support for Vision Pro content.

- **UpscalingFilter** (`Sources/Upscaling/CoreImage/UpscalingFilter.swift`) - `CIFilter` subclass for using MetalFX upscaling in CoreImage pipelines.

### Platform Support

- macOS 13+ / iOS 16+
- Uses `#if canImport(MetalFX)` guards throughout - code compiles and runs (with passthrough behavior) on platforms without MetalFX

### Video Format Handling

- Outputs >14.5K resolution force-convert to ProRes422 (encoder limitation)
- Preserves color properties (primaries, transfer function, YCbCr matrix) from source
- Audio tracks are passed through without re-encoding

## Documentation

- After completing a task, automatically update any affected existing documentation (README.md, etc.)
- Do not create new documentation files unless explicitly requested by the user
