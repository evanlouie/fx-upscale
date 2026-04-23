# AGENTS.md

Guidelines for AI agents working on fx-upscale, a Metal-powered video upscaling tool.

## Project Overview

Swift 6.2 package with two targets:

- **fx-upscale**: CLI executable using ArgumentParser with a small in-tree terminal UI helper
- **Upscaling**: Core library for MetalFX-based video upscaling

Platforms: macOS 26+ (Tahoe). iOS is not supported.

## Build Commands

```bash
# Build (debug)
swift build

# Build (release, universal binary)
swift build -c release --arch arm64 --arch x86_64 --product fx-upscale

# Build with Xcode (CI-style)
xcodebuild build -scheme Upscaling -destination "platform=macOS"

# Run the CLI
swift run fx-upscale <video-file> [options]
```

Before declaring any code-change task complete, run `swift build -c release`
and `swift test`. A debug build is not sufficient: release WMO has surfaced
Swift compiler bugs (e.g. an `ActorIsolationRequest` cycle on
`isolated deinit`) that debug builds silently accept. Release is a strict
superset of debug's checks, so it's the only build required at the
"declare complete" gate — debug builds remain fine for fast iteration
during development.

## Test Commands

```bash
# Run all tests
swift test

# List available tests
swift test list

# Run a single test by name
swift test --filter "Upscaler Tests/Upscaler async API produces correct output size"

# Run an entire test suite
swift test --filter "Export Session Tests"

# Run tests matching a pattern
swift test --filter "URL Extension"
```

Test naming format: `<Suite name>/<test description>` (swift-testing uses the human-readable
`@Suite` / `@Test` strings, not the Swift symbol names).

## Testing Guidelines

Uses **swift-testing** framework (not XCTest).

### Test Structure

```swift
import Testing
@testable import Upscaling

@Suite("Suite Description")
struct MyTests {
  @Test("Test description")
  func testSomething() throws {
    #expect(value == expected)
  }

  @Test("Async test")
  func asyncTest() async throws {
    let result = try await someAsyncOperation()
    #expect(result != nil)
  }
}
```

### Key Testing Patterns

- Use `@Suite` with descriptive names and optional traits (`.serialized`)
- Use `#expect()` for assertions, `#require()` for unwrapping
- Use `throw TestSkipError("reason")` to skip tests conditionally
- Test helper structs for setup (e.g., `TestVideoGenerator`)
- Clean up with `defer { cleanup() }` pattern
- Disable tests with `.disabled("reason")` trait

### Test Resources

Place test resources in `Tests/<TestTarget>/Resources/` and access via:

```swift
Bundle.module.url(forResource: "filename", withExtension: "ext")
```

## Dependencies

- [swift-argument-parser](https://github.com/apple/swift-argument-parser) - CLI parsing

Terminal UI (info/success messages and the progress bar) is implemented in-tree
in `Sources/fx-upscale/TerminalUI.swift` using ANSI escape codes — no external
dependency required.

Testing uses the `Testing` framework bundled with the Swift 6 toolchain (no external dependency).

## Commit Message Conventions

Use [Conventional Commits](https://www.conventionalcommits.org/): `<type>(<scope>)<!>: <summary>`, followed by a blank line and a body.

- Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`
- Summary: imperative, lowercase, no trailing period, ≤ 72 chars
- Body: required; explain _what_ changed and _why_ (not _how_), wrap at ~72 chars
- Use `!` + `BREAKING CHANGE:` footer for breaking changes
- One logical change per commit

Example:

```
feat(platform)!: target macOS 26 only, drop iOS support

Bump swift-tools-version to 6.2 and set platforms to .macOS(.v26) so we
can use APIs only available on Tahoe. iOS support is removed since the
MetalFX pipeline is only exercised on macOS.

BREAKING CHANGE: iOS is no longer a supported platform.
```

## Known Playback Issues

### IINA: arrow-key seeks jump to start on HEVC output

Symptom: in IINA, pressing `→` on an fx-upscale HEVC output jumps to `t=0`
instead of seeking forward. Plain `mpv`, VLC, and QuickTime all scrub
correctly on the same file.

Root cause: an FFmpeg bug in `libavformat/mov.c` (`mov_seek_stream`) where
the keyframe-index lookup returns sample 0 for certain HEVC MOV files.
Fixed upstream in [FFmpeg `d1b96c3`](https://github.com/FFmpeg/FFmpeg/commit/d1b96c380826c505a8c7e655b5ad4fdb0c2de167),
but IINA bundles its own FFmpeg inside the `.app` and lags behind.
Tracked in [iina/iina#4502](https://github.com/iina/iina/issues/4502).

This is not fixable on the encoder side — the 1s keyframe cap from
`UpscalingExportSession` (`kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration`)
is still worthwhile for compliant players, but cannot work around a
downstream index bug.

Workaround for IINA users: Settings → Advanced → Additional mpv options →
add `hr-seek` = `yes`. This forces precise (decode-forward) seeks, which
bypass the broken keyframe lookup.

## Color pipeline

### HDR round-trip on single-stage `--scaler super-resolution`

The pipeline is format-aware end-to-end when the user's chain is a single-stage
`--scaler super-resolution` with no sRGB-only sibling stages (no `--denoise`,
`--motion-blur`, `--fps`, or terminal Lanczos downsample). In that configuration an HDR
(PQ / HLG) or 10-bit source is read as `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`,
processed through `VTSuperResolutionUpscaler` without an 8-bit detour, and written out
with the source's color primaries, transfer function, YCbCr matrix, ST 2086 mastering
display, and CTA-861.3 content-light-level side-data preserved.

Mechanism:

- Each `FrameProcessorBackend` declares `supportedInputFormats` / `producedOutputFormat`
  (`Sources/Upscaling/FrameProcessorBackend.swift`). Defaults are BGRA so any backend not
  opted in keeps the historical contract. `VTSuperResolutionUpscaler` exposes a
  `pixelFormat:` init parameter so callers pick the round-trip format explicitly.
- `FrameProcessorChain.init` validates format adjacency between stages and throws
  `.formatMismatch(expected:actual:at:)` when adjacent stages disagree — turning a silent
  mid-pipeline `CVMetalTextureCacheCreateTextureFromImage` failure into a clear
  construction-time error that names both stages.
- `UpscalingExportSession` takes a synchronous `ChainCapabilitiesPreview` closure and a
  `srgbRejectingStageName` resolver. It consults both *before* opening any reader/writer,
  picks the pipeline pixel format matching the source precision (BGRA vs. 10-bit 420),
  and routes HDR static metadata through the writer's `compressionProperties`
  (`kVTCompressionPropertyKey_MasteringDisplayColorVolume`,
  `kVTCompressionPropertyKey_ContentLightLevelInfo`,
  `kVTCompressionPropertyKey_HDRMetadataInsertionMode = .auto`).
- `Error.unsupportedColorSpace(stageName:)` now names the offending sRGB-only stage so
  users see "Lanczos downsample requires Rec. 709 / sRGB SDR input" instead of a generic
  rejection.
- `isUnsupportedForSRGBPath` now also flags 10-bit Rec. 709 sources, which previously
  silently truncated to 8-bit on the spatial path.
- The CLI rejects `--codec h264` on HDR sources up front (H.264 can't carry PQ/HLG
  metadata cleanly) and detect-and-warns on Dolby Vision sources (export continues as
  HDR10; RPU side-data is not preserved).

The MetalFX spatial path is unchanged: it remains 8-bit sRGB-only, and any chain that
mixes an sRGB-only stage with an HDR source still rejects with a stage-named error.

## Future Work

### Extend denoise / motion-blur / FRC to 10-bit

`VTTemporalNoiseProcessor`, `VTMotionBlurProcessor`, and `VTFrameRateConverter` keep the
BGRA-only declaration. Each needs its own `frameSupportedPixelFormats` audit against
10-bit 420 YUV, then the opt-in is a one-liner on construction (the pool generalization
in `VTStatefulBackendCore` is already in place).

### Linear-light Lanczos for supersampled HDR downscale

`CILanczosDownsampler` runs in sRGB working + output space to stay perceptually aligned
with `MTLFXSpatialScaler.bgra8Perceptual`. A separate linear-light path would be needed
to let `--scale N --width M` (supersampled downscale) work on HDR sources without
clipping.

### Full Dolby Vision RPU pass-through

The tool detects Dolby Vision sources and warns that RPU side-data is not preserved —
output is HDR10 only. Full DV support needs RPU NAL extraction, re-muxing, and a
different writer path that AVFoundation does not expose directly.

### Per-sample HDR dynamic metadata

Current pass-through covers static metadata (ST 2086 mastering-display + CTA-861.3
content-light-level). Dynamic metadata (HDR10+, ST 2094) is attached per-sample rather
than on the format description and requires its own extraction / reinjection path.

## CI/CD

- CI runs on macOS (latest) for the macOS platform only
- Release builds create universal binaries (arm64 + x86_64)
- Releases are tagged with semantic versioning and published to GitHub + Homebrew
