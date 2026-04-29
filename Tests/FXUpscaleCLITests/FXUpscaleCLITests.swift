import Foundation
import Testing

private struct TestSkipError: Error, CustomStringConvertible {
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

private struct CLIResult {
  var exitCode: Int32
  var output: String
}

private func runCLI(_ arguments: [String]) throws -> CLIResult {
  let process = Process()
  process.executableURL = try fxUpscaleExecutableURL()
  process.arguments = arguments

  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe

  try process.run()
  process.waitUntilExit()

  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  return CLIResult(
    exitCode: process.terminationStatus,
    output: String(decoding: data, as: UTF8.self))
}

private func fxUpscaleExecutableURL() throws -> URL {
  let executable = packageRootURL()
    .appendingPathComponent(".build")
    .appendingPathComponent("debug")
    .appendingPathComponent("fx-upscale")
  guard FileManager.default.isExecutableFile(atPath: executable.path) else {
    throw TestSkipError("fx-upscale executable was not built at \(executable.path)")
  }
  return executable
}

private func sampleVideoURL() throws -> URL {
  let url = packageRootURL()
    .appendingPathComponent("Tests")
    .appendingPathComponent("UpscalingTests")
    .appendingPathComponent("Resources")
    .appendingPathComponent("gradient_pq_hdr.mov")
  guard FileManager.default.fileExists(atPath: url.path) else {
    throw TestSkipError("sample video fixture missing at \(url.path)")
  }
  return url
}

private func packageRootURL() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}
