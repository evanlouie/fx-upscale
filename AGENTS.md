# AGENTS.md

Guidelines for AI agents working on fx-upscale, a Metal-powered video upscaling tool.

## Project Overview

Swift 6.0 package with two targets:
- **fx-upscale**: CLI executable using ArgumentParser and SwiftTUI
- **Upscaling**: Core library for MetalFX-based video upscaling

Platforms: macOS 13+, iOS 16+

## Build Commands

```bash
# Build (debug)
swift build

# Build (release, universal binary)
swift build -c release --arch arm64 --arch x86_64 --product fx-upscale

# Build with Xcode (CI-style)
xcodebuild build -scheme Upscaling -destination "platform=macOS"
xcodebuild build -scheme Upscaling -destination "generic/platform=iOS"

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
swift test --filter UpscalingTests.UpscalerTests/upscalerSyncAPI

# Run an entire test suite
swift test --filter UpscalingTests.ExportSessionTests

# Run tests matching a pattern
swift test --filter "URLExtension"
```

Test naming format: `<Module>.<Suite>/<testFunction>`

## Code Style Guidelines

### File Organization

1. **Imports**: Alphabetically sorted, framework imports first
2. **Conditional imports**: Use `#if canImport(...)` for platform-specific frameworks
3. **MARK comments**: Structure code sections consistently:
   ```swift
   // MARK: - TypeName
   // MARK: Lifecycle
   // MARK: Public
   // MARK: Private
   ```

### Imports Example

```swift
import AVFoundation
import CoreImage
import Foundation

#if canImport(MetalFX)
  import MetalFX
#endif
```

### Naming Conventions

- **Types**: PascalCase (`UpscalingExportSession`, `Upscaler`)
- **Functions/Properties**: camelCase (`upscale`, `outputSize`)
- **Constants**: camelCase (`maxOutputSize`)
- **File names**: Match primary type (`Upscaler.swift`)
- **Extensions**: `TypeName+Extensions.swift` (e.g., `URL+Extensions.swift`)

### Type Design

- Prefer `final class` for reference types unless inheritance is needed
- Use `@unchecked Sendable` when manual synchronization is provided
- Use `public` access for library APIs, internal/private otherwise
- Define nested `Error` enums as extensions:

```swift
extension MyType {
  enum Error: Swift.Error {
    case someError
    case anotherError(SomeType)
  }
}
```

### Control Flow

- Use `guard` for early validation and unwrapping
- Prefer `switch` expressions for mapping values:

```swift
let outputFileType: AVFileType =
  switch url.pathExtension.lowercased() {
  case "mov": .mov
  case "m4v": .m4v
  default: .mp4
  }
```

### Properties

- Computed properties for simple derivations:
  ```swift
  var width: Int { CVPixelBufferGetWidth(self) }
  ```
- Stored properties with explicit types when not obvious

### Extensions

- Place extensions in `Sources/<Target>/Extensions/` directory
- One type extension per file
- Keep extensions focused and minimal

### Async/Concurrency

- Use `async`/`await` for async APIs
- Provide sync, async, and callback variants for flexibility
- Use `nonisolated(unsafe)` when bridging to completion handlers
- Use `DispatchQueue` for thread synchronization when needed:
  ```swift
  private let synchronizationQueue = DispatchQueue(label: "com.upscaling.Upscaler")
  ```

### Error Handling

- Throw descriptive errors from enums
- Use `try?` when failures should return nil/fallback
- Clean up resources in error paths:
  ```swift
  } catch {
    try? FileManager.default.removeItem(at: outputURL)
    throw error
  }
  ```

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
- [SwiftTUI](https://github.com/Finnvoor/SwiftTUI) - Terminal UI (progress bar)
- [swift-testing](https://github.com/apple/swift-testing) - Testing framework

## CI/CD

- CI runs on macOS 15 for both iOS and macOS platforms
- Release builds create universal binaries (arm64 + x86_64)
- Releases are tagged with semantic versioning and published to GitHub + Homebrew
