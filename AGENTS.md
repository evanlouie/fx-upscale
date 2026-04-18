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

## CI/CD

- CI runs on macOS (latest) for the macOS platform only
- Release builds create universal binaries (arm64 + x86_64)
- Releases are tagged with semantic versioning and published to GitHub + Homebrew
