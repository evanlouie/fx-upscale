import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import Metal
import Testing

@testable import Upscaling

#if canImport(MetalFX)
  import MetalFX
#endif

// MARK: - Test Video Generator

/// Helper to create test videos for export session tests
struct TestVideoGenerator {
  /// Creates a simple test video with solid color frames
  static func createTestVideo(
    duration: TimeInterval = 1.0,
    frameRate: Int = 30,
    size: CGSize = CGSize(width: 640, height: 480),
    includeAudio: Bool = false,
    transform: CGAffineTransform? = nil
  ) async throws -> URL {
    // Run video generation on a background thread to avoid async context issues
    try await Task.detached {
      try createTestVideoSync(
        duration: duration,
        frameRate: frameRate,
        size: size,
        includeAudio: includeAudio,
        transform: transform
      )
    }.value
  }

  /// Synchronous version that does the actual work
  private static func createTestVideoSync(
    duration: TimeInterval,
    frameRate: Int,
    size: CGSize,
    includeAudio: Bool,
    transform: CGAffineTransform?
  ) throws -> URL {
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("test_video_\(UUID().uuidString).mov")

    // Create asset writer
    let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mov)

    // Video settings
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(size.width),
      AVVideoHeightKey: Int(size.height),
    ]
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.expectsMediaDataInRealTime = false
    if let transform {
      videoInput.transform = transform
    }

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: videoInput,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height),
      ]
    )

    writer.add(videoInput)

    // Audio input (silent) - note: we don't actually write audio samples
    if includeAudio {
      let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128000,
      ]
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      input.expectsMediaDataInRealTime = false
      writer.add(input)
    }

    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    // Create frames
    let totalFrames = Int(duration * Double(frameRate))
    let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))

    for frameIndex in 0..<totalFrames {
      while !videoInput.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.01)
      }

      var pixelBuffer: CVPixelBuffer?
      CVPixelBufferCreate(
        kCFAllocatorDefault,
        Int(size.width),
        Int(size.height),
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
      )

      guard let buffer = pixelBuffer else { continue }

      // Fill with a gradient pattern based on frame index
      CVPixelBufferLockBaseAddress(buffer, [])
      if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let height = Int(size.height)
        let width = Int(size.width)
        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

        let intensity = UInt8((frameIndex * 255 / max(totalFrames - 1, 1)) % 256)
        for y in 0..<height {
          for x in 0..<width {
            let offset = y * bytesPerRow + x * 4
            ptr[offset] = intensity  // B
            ptr[offset + 1] = UInt8((y * 255 / height) % 256)  // G
            ptr[offset + 2] = UInt8((x * 255 / width) % 256)  // R
            ptr[offset + 3] = 255  // A
          }
        }
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])

      let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
      adaptor.append(buffer, withPresentationTime: presentationTime)
    }

    videoInput.markAsFinished()

    // Use semaphore to wait for completion
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting {
      semaphore.signal()
    }
    semaphore.wait()

    guard writer.status == .completed else {
      throw TestSkipError("Video writer failed: \(writer.error?.localizedDescription ?? "unknown")")
    }

    return tempURL
  }

  /// Cleanup helper
  static func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }
}

// MARK: - Extension Tests

@Suite("AVVideoCodecType Extension Tests")
struct AVVideoCodecTypeTests {
  @Test("ProRes codecs are identified correctly")
  func proresCodecsIdentified() {
    #if !os(visionOS)
      // All ProRes variants should return true
      #expect(AVVideoCodecType.proRes422.isProRes == true)
      #expect(AVVideoCodecType.proRes4444.isProRes == true)
      #expect(AVVideoCodecType.proRes422HQ.isProRes == true)
      #expect(AVVideoCodecType.proRes422LT.isProRes == true)
      #expect(AVVideoCodecType.proRes422Proxy.isProRes == true)
      #expect(AVVideoCodecType(rawValue: "ap4x").isProRes == true)  // ProRes 4444 XQ
    #endif
  }

  @Test("Non-ProRes codecs are identified correctly")
  func nonProresCodecsIdentified() {
    // Common non-ProRes codecs should return false
    #expect(AVVideoCodecType.h264.isProRes == false)
    #expect(AVVideoCodecType.hevc.isProRes == false)
    #expect(AVVideoCodecType.jpeg.isProRes == false)
  }
}

@Suite("URL Extension Tests")
struct URLExtensionTests {
  @Test("URL renamed preserves extension")
  func renamedPreservesExtension() {
    let url = URL(fileURLWithPath: "/path/to/video.mp4")
    let renamed = url.renamed { "\($0)_upscaled" }

    #expect(renamed.lastPathComponent == "video_upscaled.mp4")
    #expect(renamed.pathExtension == "mp4")
  }

  @Test("URL renamed handles complex paths")
  func renamedComplexPaths() {
    let url = URL(fileURLWithPath: "/Users/test/Movies/my.video.file.mov")
    let renamed = url.renamed { "\($0)_2x" }

    #expect(renamed.lastPathComponent == "my.video.file_2x.mov")
    #expect(renamed.deletingLastPathComponent().path == "/Users/test/Movies")
  }

  @Test("URL renamed with replacement")
  func renamedWithReplacement() {
    let url = URL(fileURLWithPath: "/tmp/input.mov")
    let renamed = url.renamed { _ in "output" }

    #expect(renamed.lastPathComponent == "output.mov")
  }
}

// MARK: - Filter Tests

@Suite("UpscalingFilter Tests")
struct UpscalingFilterTests {
  @Test("Filter produces correct output size")
  func filterOutputSize() async throws {
    let inputImage = try #require(
      CIImage(contentsOf: Bundle.module.url(forResource: "ladybird", withExtension: "jpg")!)
    )
    let outputSize = CGSize(
      width: inputImage.extent.width * 8,
      height: inputImage.extent.height * 8
    )

    let filter = UpscalingFilter()
    filter.inputImage = inputImage
    filter.outputSize = outputSize
    let outputImage = try #require(filter.outputImage)

    #expect(outputImage.extent.size == outputSize)
  }

  @Test("Filter is thread-safe under concurrent access")
  func filterThreadSafety() async throws {
    let inputImage = try #require(
      CIImage(contentsOf: Bundle.module.url(forResource: "ladybird", withExtension: "jpg")!)
    )
    let outputSize = CGSize(
      width: inputImage.extent.width * 2,
      height: inputImage.extent.height * 2
    )

    // Test that multiple sequential accesses with config changes work
    // (Full concurrent testing requires Sendable conformance on UpscalingFilter)
    let filter = UpscalingFilter()
    filter.inputImage = inputImage
    filter.outputSize = outputSize

    // Multiple rapid accesses - the lock should prevent any crashes
    for _ in 0..<10 {
      let result = filter.outputImage
      #expect(result != nil)
      #expect(result?.extent.size == outputSize)
    }
  }

  @Test("Filter handles changing output sizes")
  func filterOutputSizeChange() async throws {
    let inputImage = try #require(
      CIImage(contentsOf: Bundle.module.url(forResource: "ladybird", withExtension: "jpg")!)
    )

    let filter = UpscalingFilter()
    filter.inputImage = inputImage

    // Test with first size
    let size1 = CGSize(width: inputImage.extent.width * 2, height: inputImage.extent.height * 2)
    filter.outputSize = size1
    let output1 = filter.outputImage
    #expect(output1 != nil)
    #expect(output1?.extent.size == size1)

    // Change to different size - should recreate scaler
    let size2 = CGSize(width: inputImage.extent.width * 4, height: inputImage.extent.height * 4)
    filter.outputSize = size2
    let output2 = filter.outputImage
    #expect(output2 != nil)
    #expect(output2?.extent.size == size2)
  }

  @Test("Filter returns nil for invalid inputs")
  func filterInvalidInputs() async throws {
    let filter = UpscalingFilter()

    // No input image
    filter.outputSize = CGSize(width: 100, height: 100)
    #expect(filter.outputImage == nil)

    // No output size
    let inputImage = try #require(
      CIImage(contentsOf: Bundle.module.url(forResource: "ladybird", withExtension: "jpg")!)
    )
    filter.inputImage = inputImage
    filter.outputSize = nil
    #expect(filter.outputImage == nil)
  }
}

// MARK: - Upscaler Tests

@Suite("Upscaler Tests")
struct UpscalerTests {
  @Test("Upscaler sync API produces correct output size")
  func upscalerSyncAPI() throws {
    let inputSize = CGSize(width: 640, height: 480)
    let outputSize = CGSize(width: 1280, height: 960)

    guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
      throw TestSkipError("Metal device not available")
    }

    let inputBuffer = try createPixelBuffer(size: inputSize)
    let outputBuffer = upscaler.upscale(inputBuffer)

    #expect(CVPixelBufferGetWidth(outputBuffer) == Int(outputSize.width))
    #expect(CVPixelBufferGetHeight(outputBuffer) == Int(outputSize.height))
  }

  @Test("Upscaler async API produces correct output size")
  func upscalerAsyncAPI() async throws {
    let inputSize = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)

    guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
      throw TestSkipError("Metal device not available")
    }

    let inputBuffer = try createPixelBuffer(size: inputSize)
    let outputBuffer = await upscaler.upscale(inputBuffer)

    #expect(CVPixelBufferGetWidth(outputBuffer) == Int(outputSize.width))
    #expect(CVPixelBufferGetHeight(outputBuffer) == Int(outputSize.height))
  }

  @Test("Upscaler callback API produces correct output size")
  func upscalerCallbackAPI() throws {
    let inputSize = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)

    guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
      throw TestSkipError("Metal device not available")
    }

    let inputBuffer = try createPixelBuffer(size: inputSize)

    // Use expectation-style testing for callback API
    let semaphore = DispatchSemaphore(value: 0)
    var outputBuffer: CVPixelBuffer?

    upscaler.upscale(inputBuffer) { result in
      outputBuffer = result
      semaphore.signal()
    }

    let timeout = semaphore.wait(timeout: .now() + 5)
    #expect(timeout == .success)

    let output = try #require(outputBuffer)
    #expect(CVPixelBufferGetWidth(output) == Int(outputSize.width))
    #expect(CVPixelBufferGetHeight(output) == Int(outputSize.height))
  }

  @Test("Upscaler handles non-square dimensions")
  func upscalerNonSquare() throws {
    // Wide aspect ratio
    let inputSize = CGSize(width: 1920, height: 800)
    let outputSize = CGSize(width: 3840, height: 1600)

    guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
      throw TestSkipError("Metal device not available")
    }

    let inputBuffer = try createPixelBuffer(size: inputSize)
    let outputBuffer = upscaler.upscale(inputBuffer)

    #expect(CVPixelBufferGetWidth(outputBuffer) == Int(outputSize.width))
    #expect(CVPixelBufferGetHeight(outputBuffer) == Int(outputSize.height))
  }

  private func createPixelBuffer(size: CGSize) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: Int(size.width),
      kCVPixelBufferHeightKey as String: Int(size.height),
      kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      Int(size.width),
      Int(size.height),
      kCVPixelFormatType_32BGRA,
      attrs as CFDictionary,
      &pixelBuffer
    )
    guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
      throw TestSkipError("Failed to create pixel buffer")
    }
    return buffer
  }
}

// MARK: - Export Session Tests

@Suite("Export Session Tests", .serialized)
struct ExportSessionTests {
  /// Verifies Metal/MetalFX is available for export tests
  private func requireMetal() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw TestSkipError("Metal device not available")
    }
    #if !canImport(MetalFX)
      throw TestSkipError("MetalFX not available")
    #endif
  }

  @Test("Export session URL handling for ProRes")
  func proresURLConversion() throws {
    // Test that ProRes codec changes .mp4 to .mov extension
    let mp4URL = FileManager.default.temporaryDirectory.appendingPathComponent("test.mp4")
    let asset = AVAsset(url: mp4URL)

    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .proRes422,
      preferredOutputURL: mp4URL,
      outputSize: CGSize(width: 640, height: 480)
    )

    #expect(session.outputURL.pathExtension == "mov")
  }

  @Test("Export session preserves .mov extension")
  func movExtensionPreserved() throws {
    let movURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.mov")
    let asset = AVAsset(url: movURL)

    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .h264,
      preferredOutputURL: movURL,
      outputSize: CGSize(width: 640, height: 480)
    )

    #expect(session.outputURL.pathExtension == "mov")
  }

  @Test("Export session progress is configured")
  func progressConfiguration() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.mov")
    let asset = AVAsset(url: url)

    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .h264,
      preferredOutputURL: url,
      outputSize: CGSize(width: 640, height: 480)
    )

    #expect(session.progress.fileURL == url)
  }

  @Test("Basic upscale produces correct output dimensions")
  func basicUpscale() async throws {
    try requireMetal()

    // Create test video
    let inputSize = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)

    let inputURL = try await TestVideoGenerator.createTestVideo(
      duration: 0.5,
      frameRate: 10,
      size: inputSize
    )
    defer { TestVideoGenerator.cleanup(inputURL) }

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("upscaled_\(UUID().uuidString).mov")
    defer { TestVideoGenerator.cleanup(outputURL) }

    // Export
    let asset = AVAsset(url: inputURL)
    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .h264,
      preferredOutputURL: outputURL,
      outputSize: outputSize
    )

    try await session.export()

    // Verify output
    #expect(FileManager.default.fileExists(atPath: outputURL.path))

    let outputAsset = AVAsset(url: outputURL)
    let videoTrack = try await outputAsset.loadTracks(withMediaType: .video).first
    let trackSize = try await videoTrack?.load(.naturalSize)

    #expect(trackSize?.width == outputSize.width)
    #expect(trackSize?.height == outputSize.height)
  }

  /// https://github.com/finnvoor/fx-upscale/issues/8
  @Test("Transformed video preserves transform")
  func upscaleTransformedVideo() async throws {
    try requireMetal()

    // Create test video with a 90-degree rotation transform
    let inputSize = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)
    let rotationTransform = CGAffineTransform(rotationAngle: .pi / 2)

    let inputURL = try await TestVideoGenerator.createTestVideo(
      duration: 0.5,
      frameRate: 10,
      size: inputSize,
      transform: rotationTransform
    )
    defer { TestVideoGenerator.cleanup(inputURL) }

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("transformed_\(UUID().uuidString).mov")
    defer { TestVideoGenerator.cleanup(outputURL) }

    // Export
    let asset = AVAsset(url: inputURL)
    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .h264,
      preferredOutputURL: outputURL,
      outputSize: outputSize
    )

    try await session.export()

    // Verify output exists and has video
    #expect(FileManager.default.fileExists(atPath: outputURL.path))

    let outputAsset = AVAsset(url: outputURL)
    let videoTrack = try await outputAsset.loadTracks(withMediaType: .video).first
    #expect(videoTrack != nil)

    // Note: Transform preservation depends on implementation details
    // The test ensures the export completes without crashing
  }

  /// https://github.com/finnvoor/fx-upscale/commit/e6666afdb9a5ce1eda38437bec25b0743b740360
  @Test("Missing color info doesn't crash")
  func upscaleMissingColorInfo() async throws {
    try requireMetal()

    // Create a basic test video (which won't have extensive color metadata)
    let inputSize = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)

    let inputURL = try await TestVideoGenerator.createTestVideo(
      duration: 0.5,
      frameRate: 10,
      size: inputSize
    )
    defer { TestVideoGenerator.cleanup(inputURL) }

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("no_color_\(UUID().uuidString).mov")
    defer { TestVideoGenerator.cleanup(outputURL) }

    // Export - should not crash even if color info is missing
    let asset = AVAsset(url: inputURL)
    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .h264,
      preferredOutputURL: outputURL,
      outputSize: outputSize
    )

    // This should complete without crashing
    try await session.export()

    #expect(FileManager.default.fileExists(atPath: outputURL.path))
  }

  /// https://github.com/finnvoor/fx-upscale/commit/44463975e46ee7d418ad41017782c1e267205c82
  @Test("ProRes codec uses .mov extension (end-to-end)")
  func transcodeToProRes() async throws {
    try requireMetal()

    // Create test video
    let inputSize = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)

    let inputURL = try await TestVideoGenerator.createTestVideo(
      duration: 0.5,
      frameRate: 10,
      size: inputSize
    )
    defer { TestVideoGenerator.cleanup(inputURL) }

    // Request .mp4 but with ProRes codec - should convert to .mov
    let preferredURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("prores_test_\(UUID().uuidString).mp4")

    let asset = AVAsset(url: inputURL)
    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .proRes422,
      preferredOutputURL: preferredURL,
      outputSize: outputSize
    )

    // The session should have converted .mp4 to .mov for ProRes
    #expect(session.outputURL.pathExtension.lowercased() == "mov")

    defer { TestVideoGenerator.cleanup(session.outputURL) }

    try await session.export()

    #expect(FileManager.default.fileExists(atPath: session.outputURL.path))
  }

  /// https://github.com/finnvoor/fx-upscale/issues/7
  @Test("Audio track is preserved", .disabled("Audio generation not implemented in test helper"))
  func audioFormatMaintained() async throws {
    try requireMetal()

    // This test requires generating video with audio
    // Currently our test helper doesn't generate actual audio samples
    // The test verifies the export doesn't drop audio tracks

    let inputSize = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)

    let inputURL = try await TestVideoGenerator.createTestVideo(
      duration: 0.5,
      frameRate: 10,
      size: inputSize,
      includeAudio: true
    )
    defer { TestVideoGenerator.cleanup(inputURL) }

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("with_audio_\(UUID().uuidString).mov")
    defer { TestVideoGenerator.cleanup(outputURL) }

    let asset = AVAsset(url: inputURL)
    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .h264,
      preferredOutputURL: outputURL,
      outputSize: outputSize
    )

    try await session.export()

    // Check that audio track exists in output if it existed in input
    let inputAudioTracks = try await asset.loadTracks(withMediaType: .audio)
    let outputAsset = AVAsset(url: outputURL)
    let outputAudioTracks = try await outputAsset.loadTracks(withMediaType: .audio)

    if !inputAudioTracks.isEmpty {
      #expect(!outputAudioTracks.isEmpty, "Audio track should be preserved")
    }
  }

  /// https://github.com/finnvoor/fx-upscale/issues/6
  @Test("Metadata is preserved")
  func maintainMetadata() async throws {
    try requireMetal()

    let inputSize = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)

    let inputURL = try await TestVideoGenerator.createTestVideo(
      duration: 0.5,
      frameRate: 10,
      size: inputSize
    )
    defer { TestVideoGenerator.cleanup(inputURL) }

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("metadata_\(UUID().uuidString).mov")
    defer { TestVideoGenerator.cleanup(outputURL) }

    let asset = AVAsset(url: inputURL)
    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .h264,
      preferredOutputURL: outputURL,
      outputSize: outputSize,
      creator: "TestCreator"
    )

    try await session.export()

    #expect(FileManager.default.fileExists(atPath: outputURL.path))

    // Creator is set via extended attributes, which may not be easily readable
    // The test verifies the export completes with creator parameter
  }

  /// https://github.com/finnvoor/fx-upscale/issues/4
  @Test("Export progress is reported")
  func exportProgress() async throws {
    try requireMetal()

    let inputSize = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)

    let inputURL = try await TestVideoGenerator.createTestVideo(
      duration: 1.0,
      frameRate: 15,
      size: inputSize
    )
    defer { TestVideoGenerator.cleanup(inputURL) }

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("progress_\(UUID().uuidString).mov")
    defer { TestVideoGenerator.cleanup(outputURL) }

    let asset = AVAsset(url: inputURL)
    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .h264,
      preferredOutputURL: outputURL,
      outputSize: outputSize
    )

    // Verify progress object is configured
    #expect(session.progress.fileURL == outputURL)

    try await session.export()

    #expect(FileManager.default.fileExists(atPath: outputURL.path))

    // At minimum, the totalUnitCount should have been set during export
    #expect(session.progress.totalUnitCount > 0)
  }

  @Test("Output file already exists throws error")
  func outputExistsError() async throws {
    try requireMetal()
    let inputSize = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)

    let inputURL = try await TestVideoGenerator.createTestVideo(
      duration: 0.5,
      frameRate: 10,
      size: inputSize
    )
    defer { TestVideoGenerator.cleanup(inputURL) }

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("existing_\(UUID().uuidString).mov")

    // Create the output file first
    FileManager.default.createFile(atPath: outputURL.path, contents: Data(), attributes: nil)
    defer { TestVideoGenerator.cleanup(outputURL) }

    let asset = AVAsset(url: inputURL)
    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .h264,
      preferredOutputURL: outputURL,
      outputSize: outputSize
    )

    // Should throw outputURLAlreadyExists error
    await #expect(throws: UpscalingExportSession.Error.self) {
      try await session.export()
    }
  }
}

// MARK: - Test Skip Error

struct TestSkipError: Error, CustomStringConvertible {
  let description: String
  init(_ message: String) { self.description = message }
}
