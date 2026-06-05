import ArgumentParser
import Foundation
import Testing
@testable import fx_upscale

private struct TestFixtureError: Error, CustomStringConvertible {
  let description: String
  init(_ message: String) { self.description = message }
}

@Suite("fx-upscale CLI")
struct FXUpscaleCLITests {
  @Test("--help succeeds")
  func helpSucceeds() throws {
    let result = try runCLI(["--help"])
    #expect(result.exitCode == 0)
    #expect(result.output.contains("USAGE:"))
    #expect(result.output.contains("fx-upscale"))
  }

  @Test("Existing output is rejected without --force before opening the asset")
  func existingOutputRejectedWithoutForce() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fx-upscale-cli-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = directory.appendingPathComponent("sample.mp4")
    let output = directory.appendingPathComponent("sample Upscaled.mp4")
    FileManager.default.createFile(atPath: input.path, contents: Data())
    FileManager.default.createFile(atPath: output.path, contents: Data())

    let result = try runCLI([input.path])
    #expect(result.exitCode != 0)
    #expect(result.output.contains("Output file already exists"))
  }

  @Test(
    "Validation failures are reported before asset loading",
    arguments: [
      CLIValidationCase(arguments: ["--scale", "1"], message: "--scale must be an integer ≥ 2"),
      CLIValidationCase(arguments: ["--width", "0"], message: "--width must be a positive integer"),
      CLIValidationCase(arguments: ["--height", "0"], message: "--height must be a positive integer"),
      CLIValidationCase(arguments: ["--quality", "200"], message: "Quality must be between 1 and 100"),
      CLIValidationCase(arguments: ["--keyframe-interval", "nan"], message: "--keyframe-interval must be a non-negative, finite number"),
      CLIValidationCase(arguments: ["--fps", "nan"], message: "--fps must be a positive, finite number"),
      CLIValidationCase(arguments: ["--scaler", "super-resolution"], message: "no scaling was requested"),
    ]
  )
  func validationFailuresAreClear(testCase: CLIValidationCase) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fx-upscale-cli-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = directory.appendingPathComponent("sample.mp4")
    FileManager.default.createFile(atPath: input.path, contents: Data())

    let result = try runCLI([input.path] + testCase.arguments)
    #expect(result.exitCode == ExitCode.validationFailure.rawValue)
    #expect(result.output.contains(testCase.message))
  }

  @Test("Validation errors are written to stderr, not stdout")
  func validationErrorsGoToStderr() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fx-upscale-cli-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = directory.appendingPathComponent("sample.mp4")
    FileManager.default.createFile(atPath: input.path, contents: Data())

    let result = try runCLI([input.path, "--scale", "1"])
    #expect(result.exitCode == ExitCode.validationFailure.rawValue)
    // ArgumentParser routes validation diagnostics to stderr; nothing should leak to stdout.
    #expect(result.stderr.contains("--scale must be an integer ≥ 2"))
    #expect(!result.stdout.contains("--scale must be an integer ≥ 2"))
  }

  @Test("Progress renderer degrades cleanly in narrow terminals")
  func progressRendererDegradesInNarrowTerminals() {
    let lines = ProgressBar.renderLines(terminalWidth: 8, fraction: 0.5, snapshot: nil)
    #expect(lines.count == 1)
    #expect(visibleText(lines[0]) == " 50.00%")
  }

  @Test("Progress renderer keeps the partial glyph in the final cell")
  func progressRendererKeepsPartialGlyphInFinalCell() {
    // Width 20 leaves a 10-column bar. At 95%, nine columns are complete and the final
    // column should carry the partial glyph before the closing bracket.
    let lines = ProgressBar.renderLines(terminalWidth: 20, fraction: 0.95, snapshot: nil)
    #expect(lines.count == 1)
    #expect(visibleText(lines[0]).contains("[█████████▌]"))
  }

  @Test("Progress renderer fills every cell at 100%")
  func progressRendererFullBarAtCompletion() {
    // fraction 1.0 → completed == barCols (10); no partial glyph, no trailing pad.
    let lines = ProgressBar.renderLines(terminalWidth: 20, fraction: 1.0, snapshot: nil)
    #expect(lines.count == 1)
    #expect(visibleText(lines[0]).contains("[██████████]"))
  }

  @Test("Progress renderer shows an empty bar at 0%")
  func progressRendererEmptyBarAtStart() {
    // fraction 0.0 → ten empty cells between the brackets.
    let lines = ProgressBar.renderLines(terminalWidth: 20, fraction: 0.0, snapshot: nil)
    #expect(lines.count == 1)
    #expect(visibleText(lines[0]).contains("[          ]"))
  }

  @Test("--force does not remove a directory at the output path")
  func forceDoesNotRemoveOutputDirectory() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fx-upscale-cli-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = directory.appendingPathComponent("sample.mov")
    let outputDirectory = directory.appendingPathComponent("sample Upscaled.mov", isDirectory: true)
    try FileManager.default.copyItem(at: try sampleVideoURL(), to: input)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    let result = try runCLI([input.path, "--force"])
    #expect(result.exitCode != 0)
    #expect(result.output.contains("Output path is a directory"))
    #expect(FileManager.default.fileExists(atPath: outputDirectory.path))
  }
}

struct CLIValidationCase: Sendable, CustomTestStringConvertible {
  var arguments: [String]
  var message: String

  var testDescription: String { arguments.joined(separator: " ") }
}

private struct CLIResult {
  var exitCode: Int32
  var stdout: String
  var stderr: String
  /// Combined stream view for assertions that don't care about routing.
  var output: String { stdout + stderr }
}

private func visibleText(_ string: String) -> String {
  string.replacing(/\u{1B}\[[0-9;]*m/, with: "")
}

private func runCLI(_ arguments: [String]) throws -> CLIResult {
  let process = Process()
  process.executableURL = try fxUpscaleExecutableURL()
  process.arguments = arguments

  // Route stdout/stderr to separate temp files rather than pipes: a file sink can't fill a
  // 64KB pipe buffer, so the child never blocks on write while we wait — no drain deadlock,
  // and the two streams stay distinguishable for routing assertions.
  let ioDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("fx-upscale-cli-io-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: ioDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: ioDirectory) }
  let outURL = ioDirectory.appendingPathComponent("stdout")
  let errURL = ioDirectory.appendingPathComponent("stderr")
  FileManager.default.createFile(atPath: outURL.path, contents: nil)
  FileManager.default.createFile(atPath: errURL.path, contents: nil)
  let outHandle = try FileHandle(forWritingTo: outURL)
  let errHandle = try FileHandle(forWritingTo: errURL)
  process.standardOutput = outHandle
  process.standardError = errHandle

  try process.run()
  process.waitUntilExit()
  try? outHandle.close()
  try? errHandle.close()

  let outData = (try? Data(contentsOf: outURL)) ?? Data()
  let errData = (try? Data(contentsOf: errURL)) ?? Data()
  return CLIResult(
    exitCode: process.terminationStatus,
    stdout: String(decoding: outData, as: UTF8.self),
    stderr: String(decoding: errData, as: UTF8.self))
}

private func fxUpscaleExecutableURL() throws -> URL {
  if let override = ProcessInfo.processInfo.environment["FX_UPSCALE_EXECUTABLE"],
    FileManager.default.isExecutableFile(atPath: override)
  {
    return URL(fileURLWithPath: override)
  }
  // Honor whichever build configuration produced the binary so `swift test` and
  // `swift test -c release` both resolve it.
  let buildDir = packageRootURL().appendingPathComponent(".build")
  for configuration in ["debug", "release"] {
    let candidate =
      buildDir
      .appendingPathComponent(configuration)
      .appendingPathComponent("fx-upscale")
    if FileManager.default.isExecutableFile(atPath: candidate.path) {
      return candidate
    }
  }
  throw TestFixtureError(
    "fx-upscale executable was not built under \(buildDir.path) (debug/ or release/)")
}

private func sampleVideoURL() throws -> URL {
  let url = packageRootURL()
    .appendingPathComponent("Tests")
    .appendingPathComponent("UpscalingTests")
    .appendingPathComponent("Resources")
    .appendingPathComponent("gradient_pq_hdr.mov")
  guard FileManager.default.fileExists(atPath: url.path) else {
    throw TestFixtureError("sample video fixture missing at \(url.path)")
  }
  return url
}

private func packageRootURL() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}
