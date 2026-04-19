# AGENTS.md

Guidelines for AI agents working on fx-upscale, a Metal-powered video upscaling tool.

## Project Overview

Swift 6.2 package with two targets:

- **fx-upscale**: CLI executable using ArgumentParser with a small in-tree terminal UI helper
- **Upscaling**: Core library for MetalFX-based video upscaling

Platforms: macOS 26+ (Tahoe). iOS is not supported.

## Code Quality: Simple, Not Easy

The top code-quality goal is **simplicity in the Rich Hickey sense** — code
that is *not complected*. Simple ≠ easy. "Easy" is familiar, close at hand;
"simple" is one concept, one role, not braided together with others.
Prioritise the former.

Concretely, when you're about to write or change code:

- **Separate concerns that don't belong together.** If one function/type is
  juggling two independent axes of variation (e.g. "what transforms the
  pixels" vs. "what the encoder does"), pull them apart. Mixing them is
  complecting.
- **Avoid sentinel values and ceremony that exist only to satisfy a
  fabricated invariant.** If a constraint (e.g. "this collection must be
  non-empty") forces callers to synthesise dummy members to route around it,
  the constraint itself is probably the complecting element — lift it
  rather than codifying the workaround.
- **Prefer data over types for ordering / configuration.** Keeping a
  pipeline's order in an array beats encoding it in the type system, because
  callers can reorder without touching the types.
- **Don't add a concept to speed something up unless you've measured the
  cost.** Optimisations that introduce special cases ("detect the trivial
  path and bypass it") *add* complecting. If the simple version is fast
  enough, leave it simple.
- **Breaking changes are fine.** This is not a public library; favour the
  simpler design over backward compatibility. Don't keep vestigial
  parameters, sentinel stages, or compatibility shims.
- **Decomplect, then optimise** — in that order. A decomplected design
  usually exposes where the real hot paths are, and optimisations applied
  to a simple core are themselves simpler.

When evaluating a proposed change, ask: *does this add a concept, or remove
one?* Changes that collapse two concepts into one are simplifications;
changes that fork a single concept into two paths (a fast one and a general
one) are usually complecting in disguise.

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
swift test --filter "Upscaler Tests/Upscaler sync API produces correct output size"

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

## Future Work

### Expand the `--scaler super-resolution` path to non-sRGB color

Today both backends (`MTLFXSpatialScaler` and `VTFrameProcessor` super resolution) are
gated by the same 8-bit BGRA sRGB input check (`formatDescription.isUnsupportedForSRGBPath`
in `Sources/Upscaling/UpscalingExportSession.swift`). This is a real constraint for the
MetalFX path (we use `bgra8Perceptual`, which clips / shifts wide-gamut or HDR values),
but it's an *artificial* constraint on the VT path — `VTSuperResolutionScalerConfiguration`
exposes `frameSupportedPixelFormats`, `sourcePixelBufferAttributes`, and
`destinationPixelBufferAttributes` that cover a wider set of formats (including 10-bit
and some YUV layouts).

To lift it, the whole pipeline needs to become format-aware end-to-end:

1. Reader output settings (`videoAssetReaderOutput`) — today hard-coded to BGRA.
2. `CVPixelBufferPool` attributes — today use `PixelBufferAttributes.bgra(size:)`.
3. Asset writer input + compression properties — color primaries / transfer function /
   YCbCr matrix must round-trip correctly (HDR10, HLG, Rec. 2020).
4. `VTFrameProcessorFrame` wrap — any buffer change must remain IOSurface-backed.

Suggested split: do this in its own commit / PR, gated by `--scaler super-resolution`
so the MetalFX path keeps its current strict behavior. Verify HDR metadata round-trips
with real PQ / HLG sources before relaxing the reject in `UpscalingExportSession.swift`.

## CI/CD

- CI runs on macOS (latest) for the macOS platform only
- Release builds create universal binaries (arm64 + x86_64)
- Releases are tagged with semantic versioning and published to GitHub + Homebrew
