import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import Metal
import Testing
import VideoToolbox

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
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("test_video_\(UUID().uuidString).mov")

    let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mov)

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

    var audioInput: AVAssetWriterInput?
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
      audioInput = input
    }

    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let totalFrames = Int(duration * Double(frameRate))
    let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))

    for frameIndex in 0..<totalFrames {
      while !videoInput.isReadyForMoreMediaData {
        try await Task.sleep(for: .milliseconds(5))
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

    if let audioInput {
      try await writeSilentAudio(
        into: audioInput, duration: duration, sampleRate: 44100, channels: 2)
      audioInput.markAsFinished()
    }

    await writer.finishWriting()

    guard writer.status == .completed else {
      throw TestSkipError("Video writer failed: \(writer.error?.localizedDescription ?? "unknown")")
    }

    return tempURL
  }

  static func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  /// Writes a block of silent PCM audio into the given asset writer input.
  private static func writeSilentAudio(
    into input: AVAssetWriterInput,
    duration: TimeInterval,
    sampleRate: Int,
    channels: Int
  ) async throws {
    let totalFrames = Int(Double(sampleRate) * duration)
    let framesPerChunk = 1024

    var asbd = AudioStreamBasicDescription(
      mSampleRate: Float64(sampleRate),
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: UInt32(channels * 2),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(channels * 2),
      mChannelsPerFrame: UInt32(channels),
      mBitsPerChannel: 16,
      mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &asbd,
      layoutSize: 0, layout: nil,
      magicCookieSize: 0, magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &formatDescription
    )
    guard let formatDescription else { return }

    var framesWritten = 0
    while framesWritten < totalFrames {
      let frames = min(framesPerChunk, totalFrames - framesWritten)
      let byteCount = frames * channels * 2
      let silence = [UInt8](repeating: 0, count: byteCount)

      var blockBuffer: CMBlockBuffer?
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: byteCount,
        blockAllocator: nil,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: byteCount,
        flags: 0,
        blockBufferOut: &blockBuffer)
      guard let blockBuffer else { return }
      _ = silence.withUnsafeBytes { bytes in
        CMBlockBufferReplaceDataBytes(
          with: bytes.baseAddress!,
          blockBuffer: blockBuffer,
          offsetIntoDestination: 0,
          dataLength: byteCount)
      }

      var sampleBuffer: CMSampleBuffer?
      var sampleTiming = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
        presentationTimeStamp: CMTime(
          value: Int64(framesWritten), timescale: CMTimeScale(sampleRate)),
        decodeTimeStamp: .invalid
      )
      var sampleSize = channels * 2
      CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDescription,
        sampleCount: CMItemCount(frames),
        sampleTimingEntryCount: 1,
        sampleTimingArray: &sampleTiming,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
      )
      if let sampleBuffer {
        while !input.isReadyForMoreMediaData {
          try await Task.sleep(for: .milliseconds(5))
        }
        input.append(sampleBuffer)
      }
      framesWritten += frames
    }
  }
}

// MARK: - Extension Tests

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
  private func loadLadybird() throws -> CIImage {
    let url = try #require(Bundle.module.url(forResource: "ladybird", withExtension: "jpg"))
    return try #require(CIImage(contentsOf: url))
  }

  @Test("Filter produces correct output size")
  func filterOutputSize() throws {
    let inputImage = try loadLadybird()
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
  func filterThreadSafety() throws {
    let inputImage = try loadLadybird()
    let outputSize = CGSize(
      width: inputImage.extent.width * 2,
      height: inputImage.extent.height * 2
    )

    let filter = UpscalingFilter()
    filter.inputImage = inputImage
    filter.outputSize = outputSize

    for _ in 0..<10 {
      let result = filter.outputImage
      #expect(result != nil)
      #expect(result?.extent.size == outputSize)
    }
  }

  @Test("Filter handles changing output sizes")
  func filterOutputSizeChange() throws {
    let inputImage = try loadLadybird()

    let filter = UpscalingFilter()
    filter.inputImage = inputImage

    let size1 = CGSize(width: inputImage.extent.width * 2, height: inputImage.extent.height * 2)
    filter.outputSize = size1
    let output1 = filter.outputImage
    #expect(output1 != nil)
    #expect(output1?.extent.size == size1)

    let size2 = CGSize(width: inputImage.extent.width * 4, height: inputImage.extent.height * 4)
    filter.outputSize = size2
    let output2 = filter.outputImage
    #expect(output2 != nil)
    #expect(output2?.extent.size == size2)
  }

  @Test("Filter returns nil for invalid inputs")
  func filterInvalidInputs() throws {
    let filter = UpscalingFilter()

    filter.outputSize = CGSize(width: 100, height: 100)
    #expect(filter.outputImage == nil)

    let inputImage = try loadLadybird()
    filter.inputImage = inputImage
    filter.outputSize = nil
    #expect(filter.outputImage == nil)
  }
}

// MARK: - Upscaler Tests

@Suite("Upscaler Tests")
struct UpscalerTests {
  @Test("Upscaler async API produces correct output size")
  func upscalerAsyncAPI() async throws {
    let inputSize = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)

    guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
      throw TestSkipError("Metal device not available")
    }

    let inputBuffer = try makeTestPixelBuffer(size: inputSize)
    let outputBuffer = try await upscaler.processSingle(inputBuffer)

    #expect(CVPixelBufferGetWidth(outputBuffer) == Int(outputSize.width))
    #expect(CVPixelBufferGetHeight(outputBuffer) == Int(outputSize.height))
  }

  @Test("Upscaler handles non-square dimensions")
  func upscalerNonSquare() async throws {
    let inputSize = CGSize(width: 1920, height: 800)
    let outputSize = CGSize(width: 3840, height: 1600)

    guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
      throw TestSkipError("Metal device not available")
    }

    let inputBuffer = try makeTestPixelBuffer(size: inputSize)
    let outputBuffer = try await upscaler.processSingle(inputBuffer)

    #expect(CVPixelBufferGetWidth(outputBuffer) == Int(outputSize.width))
    #expect(CVPixelBufferGetHeight(outputBuffer) == Int(outputSize.height))
  }

  @Test("Upscaler rejects mismatched input size")
  func upscalerRejectsMismatchedInputSize() async throws {
    let upscalerSize = CGSize(width: 640, height: 480)
    guard
      let upscaler = Upscaler(
        inputSize: upscalerSize, outputSize: CGSize(width: 1280, height: 960))
    else {
      throw TestSkipError("Metal device not available")
    }
    let wrongBuffer = try makeTestPixelBuffer(size: CGSize(width: 320, height: 240))
    // `CVPixelBuffer` is a CF type that isn't Sendable, and `processSingle` takes a `sending`
    // parameter. Rebinding via `nonisolated(unsafe)` releases the value from the test's
    // isolation domain so the compiler accepts the send.
    nonisolated(unsafe) let captured = wrongBuffer
    await #expect(throws: PixelBufferIOError.inputSizeMismatch) {
      _ = try await upscaler.processSingle(captured)
    }
  }

}

// Shared test helper: allocates a BGRA, Metal-compatible `CVPixelBuffer` at the given size.
// Hoisted to file scope so both `UpscalerTests` and `FrameProcessorChainTests` can use it.
private func makeTestPixelBuffer(size: CGSize) throws -> CVPixelBuffer {
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

// MARK: - Frame Processor Chain Tests

@Suite("Frame Processor Chain Tests")
struct FrameProcessorChainTests {
  @Test("Empty chain rejects construction")
  func emptyChainRejected() throws {
    #expect(throws: FrameProcessorChain.Error.self) {
      _ = try FrameProcessorChain(stages: [])
    }
  }

  @Test("Chain rejects adjacent size mismatch")
  func mismatchedStageSizes() async throws {
    guard
      let a = Upscaler(
        inputSize: CGSize(width: 320, height: 240),
        outputSize: CGSize(width: 640, height: 480)),
      let b = Upscaler(
        inputSize: CGSize(width: 800, height: 600),  // deliberately wrong for chain
        outputSize: CGSize(width: 1600, height: 1200))
    else {
      throw TestSkipError("Metal device not available")
    }
    #expect(throws: FrameProcessorChain.Error.self) {
      _ = try FrameProcessorChain(stages: [a, b])
    }
  }

  @Test("Single-stage chain behaves like the backend")
  func singleStagePassthrough() async throws {
    let inputSize = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)
    guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
      throw TestSkipError("Metal device not available")
    }
    let chain = try FrameProcessorChain(stages: [upscaler])
    #expect(chain.inputSize == inputSize)
    #expect(chain.outputSize == outputSize)
    #expect(chain.requiresInstancePerStream == false)

    let buffer = try makeTestPixelBuffer(size: inputSize)
    nonisolated(unsafe) let captured = buffer
    let pts = CMTime(value: 42, timescale: 30)
    let outputs = try await chain.process(
      captured, presentationTimeStamp: pts, outputPool: nil)
    try #require(outputs.count == 1)
    #expect(CVPixelBufferGetWidth(outputs[0].pixelBuffer) == Int(outputSize.width))
    #expect(CVPixelBufferGetHeight(outputs[0].pixelBuffer) == Int(outputSize.height))
    // 1:1 stages pass the source PTS through verbatim.
    #expect(outputs[0].presentationTimeStamp == pts)
  }

  @Test("Chain aggregates requiresInstancePerStream across stages")
  func aggregatesTemporalFlag() throws {
    // Without touching hardware: construct a test double that advertises
    // `requiresInstancePerStream = true` and verify the chain propagates it.
    let size = CGSize(width: 100, height: 100)
    let stateless = StatelessTestBackend(inputSize: size, outputSize: size)
    let temporal = TemporalTestBackend(inputSize: size, outputSize: size)

    let statelessChain = try FrameProcessorChain(stages: [stateless])
    #expect(statelessChain.requiresInstancePerStream == false)

    let mixedChain = try FrameProcessorChain(stages: [stateless, temporal])
    #expect(mixedChain.requiresInstancePerStream == true)
  }
}

// Test doubles for size-only / flag-propagation checks. These never get their `process`
// method called, so the body is a precondition failure — if a future test accidentally
// wires one into a live pipeline, it trips loudly.
private struct StatelessTestBackend: FrameProcessorBackend {
  let inputSize: CGSize
  let outputSize: CGSize
  var requiresInstancePerStream: Bool { false }
  func process(
    _ pixelBuffer: sending CVPixelBuffer,
    presentationTimeStamp: CMTime,
    outputPool: sending CVPixelBufferPool?
  ) async throws -> [FrameProcessorOutput] {
    preconditionFailure("StatelessTestBackend.process should not be called")
  }
}

private struct TemporalTestBackend: FrameProcessorBackend {
  let inputSize: CGSize
  let outputSize: CGSize
  var requiresInstancePerStream: Bool { true }
  func process(
    _ pixelBuffer: sending CVPixelBuffer,
    presentationTimeStamp: CMTime,
    outputPool: sending CVPixelBufferPool?
  ) async throws -> [FrameProcessorOutput] {
    preconditionFailure("TemporalTestBackend.process should not be called")
  }
}

// MARK: - Motion Blur Processor Tests

@Suite(
  "Motion Blur Processor Tests",
  .enabled(
    if: VTMotionBlurConfiguration.isSupported,
    "VTMotionBlurConfiguration not supported on this device")
)
struct MotionBlurProcessorTests {
  @Test("Preflight rejects strength below 1")
  func rejectsStrengthBelowMinimum() throws {
#expect(throws: VTMotionBlurProcessor.Error.self) {
      try VTMotionBlurProcessor.preflight(
        frameSize: CGSize(width: 640, height: 480), strength: 0)
    }
  }

  @Test("Preflight rejects strength above 100")
  func rejectsStrengthAboveMaximum() throws {
#expect(throws: VTMotionBlurProcessor.Error.self) {
      try VTMotionBlurProcessor.preflight(
        frameSize: CGSize(width: 640, height: 480), strength: 101)
    }
  }

  @Test("Preflight rejects oversized frames on macOS")
  func rejectsOversizedFrames() throws {
#expect(throws: VTMotionBlurProcessor.Error.self) {
      // Beyond the macOS 8192×4320 limit.
      try VTMotionBlurProcessor.preflight(
        frameSize: CGSize(width: 16384, height: 8640), strength: 50)
    }
  }

  @Test("Preflight accepts valid config")
  func preflightAcceptsValidConfig() throws {
try VTMotionBlurProcessor.preflight(
      frameSize: CGSize(width: 640, height: 480), strength: 50)
  }

  @Test("Processes two frames at output size")
  func processesTwoFrames() async throws {
let size = CGSize(width: 640, height: 480)
    let processor = try await VTMotionBlurProcessor(frameSize: size, strength: 50)

    #expect(processor.inputSize == size)
    #expect(processor.outputSize == size)
    #expect(processor.requiresInstancePerStream == true)

    // First call: no previous frame yet, so the input passes through.
    let first = try makeTestPixelBuffer(size: size)
    nonisolated(unsafe) let firstCaptured = first
    let firstPts = CMTime(value: 0, timescale: 30)
    let firstOutputs = try await processor.process(
      firstCaptured, presentationTimeStamp: firstPts, outputPool: nil)
    try #require(firstOutputs.count == 1)
    #expect(firstOutputs[0].presentationTimeStamp == firstPts)

    // Second call: previousSourceFrame is populated, so VT runs and produces a blurred frame.
    let second = try makeTestPixelBuffer(size: size)
    nonisolated(unsafe) let secondCaptured = second
    let secondPts = CMTime(value: 1, timescale: 30)
    let secondOutputs = try await processor.process(
      secondCaptured, presentationTimeStamp: secondPts, outputPool: nil)
    try #require(secondOutputs.count == 1)
    #expect(CVPixelBufferGetWidth(secondOutputs[0].pixelBuffer) == Int(size.width))
    #expect(CVPixelBufferGetHeight(secondOutputs[0].pixelBuffer) == Int(size.height))
    #expect(secondOutputs[0].presentationTimeStamp == secondPts)
  }

  @Test("Composes after a spatial upscaler in a chain")
  func composesAfterSpatialUpscaler() async throws {
let inputSize = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)

    guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
      throw TestSkipError("Metal device not available")
    }
    let blur = try await VTMotionBlurProcessor(frameSize: outputSize, strength: 50)
    let chain = try FrameProcessorChain(stages: [upscaler, blur])

    #expect(chain.inputSize == inputSize)
    #expect(chain.outputSize == outputSize)
    // Motion blur is temporal — chain must inherit the per-stream-instance requirement.
    #expect(chain.requiresInstancePerStream == true)

    // Drive two frames through the chain so the motion-blur stage exercises its VT path on
    // the second call (first is a passthrough — see VTMotionBlurProcessor.process).
    for frameIdx in 0..<2 {
      let buffer = try makeTestPixelBuffer(size: inputSize)
      nonisolated(unsafe) let captured = buffer
      let pts = CMTime(value: Int64(frameIdx), timescale: 30)
      let outputs = try await chain.process(
        captured, presentationTimeStamp: pts, outputPool: nil)
      try #require(outputs.count == 1)
      #expect(CVPixelBufferGetWidth(outputs[0].pixelBuffer) == Int(outputSize.width))
      #expect(CVPixelBufferGetHeight(outputs[0].pixelBuffer) == Int(outputSize.height))
      #expect(outputs[0].presentationTimeStamp == pts)
    }
  }
}

// MARK: - Temporal Noise Processor Tests

@Suite(
  "Temporal Noise Processor Tests",
  .enabled(
    if: VTTemporalNoiseFilterConfiguration.isSupported,
    "VTTemporalNoiseFilterConfiguration not supported on this device")
)
struct TemporalNoiseProcessorTests {
  @Test("Preflight rejects strength below 1")
  func rejectsStrengthBelowMinimum() throws {
    #expect(throws: VTTemporalNoiseProcessor.Error.self) {
      try VTTemporalNoiseProcessor.preflight(
        frameSize: CGSize(width: 640, height: 480), strength: 0)
    }
  }

  @Test("Preflight rejects strength above 100")
  func rejectsStrengthAboveMaximum() throws {
    #expect(throws: VTTemporalNoiseProcessor.Error.self) {
      try VTTemporalNoiseProcessor.preflight(
        frameSize: CGSize(width: 640, height: 480), strength: 101)
    }
  }

  @Test("Preflight accepts valid config")
  func preflightAcceptsValidConfig() throws {
    try VTTemporalNoiseProcessor.preflight(
      frameSize: CGSize(width: 640, height: 480), strength: 50)
  }

  @Test("Processes two frames at input size")
  func processesTwoFrames() async throws {
    let size = CGSize(width: 640, height: 480)
    let processor = try await VTTemporalNoiseProcessor(frameSize: size, strength: 50)

    #expect(processor.inputSize == size)
    #expect(processor.outputSize == size)

    // First call: no previous frame yet, so the input passes through.
    let first = try makeTestPixelBuffer(size: size)
    nonisolated(unsafe) let firstCaptured = first
    let firstPts = CMTime(value: 0, timescale: 30)
    let firstOutputs = try await processor.process(
      firstCaptured, presentationTimeStamp: firstPts, outputPool: nil)
    try #require(firstOutputs.count == 1)
    #expect(firstOutputs[0].presentationTimeStamp == firstPts)

    // Second call: previousSourceFrame is populated, so VT runs and produces a denoised frame.
    let second = try makeTestPixelBuffer(size: size)
    nonisolated(unsafe) let secondCaptured = second
    let secondPts = CMTime(value: 1, timescale: 30)
    let secondOutputs = try await processor.process(
      secondCaptured, presentationTimeStamp: secondPts, outputPool: nil)
    try #require(secondOutputs.count == 1)
    #expect(CVPixelBufferGetWidth(secondOutputs[0].pixelBuffer) == Int(size.width))
    #expect(CVPixelBufferGetHeight(secondOutputs[0].pixelBuffer) == Int(size.height))
    #expect(secondOutputs[0].presentationTimeStamp == secondPts)
  }

  @Test("Composes before a spatial upscaler in a chain")
  func composesBeforeSpatialUpscaler() async throws {
    let inputSize = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)

    let denoise = try await VTTemporalNoiseProcessor(frameSize: inputSize, strength: 50)
    guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
      throw TestSkipError("Metal device not available")
    }
    let chain = try FrameProcessorChain(stages: [denoise, upscaler])

    #expect(chain.inputSize == inputSize)
    #expect(chain.outputSize == outputSize)
    // Denoise is temporal — chain must inherit the per-stream-instance requirement.
    #expect(chain.requiresInstancePerStream == true)

    // Drive two frames so the denoise stage exercises its VT path on the second call (first
    // is a passthrough — see VTTemporalNoiseProcessor.process).
    for frameIdx in 0..<2 {
      let buffer = try makeTestPixelBuffer(size: inputSize)
      nonisolated(unsafe) let captured = buffer
      let pts = CMTime(value: Int64(frameIdx), timescale: 30)
      let outputs = try await chain.process(
        captured, presentationTimeStamp: pts, outputPool: nil)
      try #require(outputs.count == 1)
      #expect(CVPixelBufferGetWidth(outputs[0].pixelBuffer) == Int(outputSize.width))
      #expect(CVPixelBufferGetHeight(outputs[0].pixelBuffer) == Int(outputSize.height))
      #expect(outputs[0].presentationTimeStamp == pts)
    }
  }
}

// MARK: - Frame Rate Converter Tests

@Suite(
  "Frame Rate Converter Tests",
  .enabled(
    if: VTFrameRateConversionConfiguration.isSupported,
    "VTFrameRateConversionConfiguration not supported on this device")
)
struct FrameRateConverterTests {
  @Test("Preflight rejects non-positive frame rate")
  func rejectsNonPositiveRate() throws {
    #expect(throws: VTFrameRateConverter.Error.self) {
      try VTFrameRateConverter.preflight(
        frameSize: CGSize(width: 640, height: 480), targetFrameRate: 0)
    }
    #expect(throws: VTFrameRateConverter.Error.self) {
      try VTFrameRateConverter.preflight(
        frameSize: CGSize(width: 640, height: 480), targetFrameRate: -30)
    }
  }

  @Test("Preflight rejects non-finite frame rate")
  func rejectsNonFiniteRate() throws {
    #expect(throws: VTFrameRateConverter.Error.self) {
      try VTFrameRateConverter.preflight(
        frameSize: CGSize(width: 640, height: 480), targetFrameRate: .infinity)
    }
    #expect(throws: VTFrameRateConverter.Error.self) {
      try VTFrameRateConverter.preflight(
        frameSize: CGSize(width: 640, height: 480), targetFrameRate: .nan)
    }
  }

  @Test("Preflight accepts valid config")
  func preflightAcceptsValidConfig() throws {
    try VTFrameRateConverter.preflight(
      frameSize: CGSize(width: 640, height: 480), targetFrameRate: 60)
  }

  @Test("First frame buffers, next emits source + interpolated at 2x")
  func firstFrameBuffers() async throws {
    let size = CGSize(width: 640, height: 480)
    let converter = try await VTFrameRateConverter(frameSize: size, targetFrameRate: 60)

    #expect(converter.inputSize == size)
    #expect(converter.outputSize == size)

    // Source at 30 fps (period = 1/30s). First call buffers; no output.
    let first = try makeTestPixelBuffer(size: size)
    nonisolated(unsafe) let firstCaptured = first
    let firstPts = CMTime(value: 0, timescale: 30)
    let firstOutputs = try await converter.process(
      firstCaptured, presentationTimeStamp: firstPts, outputPool: nil)
    #expect(firstOutputs.isEmpty)

    // Second call at 1/30s provides the (prev, next) pair. Target period = 1/60s so the
    // output schedule inside [0, 1/30) has PTS 0 (phase 0, pass-through) and 1/60 (phase 0.5,
    // interpolated). Expect 2 outputs.
    let second = try makeTestPixelBuffer(size: size)
    nonisolated(unsafe) let secondCaptured = second
    let secondPts = CMTime(value: 1, timescale: 30)
    let secondOutputs = try await converter.process(
      secondCaptured, presentationTimeStamp: secondPts, outputPool: nil)
    try #require(secondOutputs.count == 2)
    #expect(secondOutputs[0].presentationTimeStamp == firstPts)
    #expect(secondOutputs[0].presentationTimeStamp < secondOutputs[1].presentationTimeStamp)
    #expect(secondOutputs[1].presentationTimeStamp < secondPts)
    for output in secondOutputs {
      #expect(CVPixelBufferGetWidth(output.pixelBuffer) == Int(size.width))
      #expect(CVPixelBufferGetHeight(output.pixelBuffer) == Int(size.height))
    }
  }

  @Test("Finish flushes the final buffered source frame")
  func finishFlushesFinalFrame() async throws {
    let size = CGSize(width: 640, height: 480)
    let converter = try await VTFrameRateConverter(frameSize: size, targetFrameRate: 60)

    // Two process() calls — the second's buffered frame still needs flushing.
    let first = try makeTestPixelBuffer(size: size)
    nonisolated(unsafe) let firstCaptured = first
    _ = try await converter.process(
      firstCaptured, presentationTimeStamp: CMTime(value: 0, timescale: 30), outputPool: nil)

    let second = try makeTestPixelBuffer(size: size)
    nonisolated(unsafe) let secondCaptured = second
    _ = try await converter.process(
      secondCaptured, presentationTimeStamp: CMTime(value: 1, timescale: 30), outputPool: nil)

    let flushed = try await converter.finish(outputPool: nil)
    try #require(flushed.count == 1)
    #expect(flushed[0].presentationTimeStamp == CMTime(value: 1, timescale: 30))

    // Calling finish again after flushing produces nothing.
    let secondFlush = try await converter.finish(outputPool: nil)
    #expect(secondFlush.isEmpty)
  }

  @Test("Chain composes after a spatial upscaler")
  func composesAfterSpatialUpscaler() async throws {
    let inputSize = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)

    guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
      throw TestSkipError("Metal device not available")
    }
    let converter = try await VTFrameRateConverter(frameSize: outputSize, targetFrameRate: 60)
    let chain = try FrameProcessorChain(stages: [upscaler, converter])

    #expect(chain.inputSize == inputSize)
    #expect(chain.outputSize == outputSize)
    // FRC is stateful — chain must inherit the per-stream-instance requirement.
    #expect(chain.requiresInstancePerStream == true)

    // Drive two source frames at 30fps, then flush. Expect the first call to buffer (no
    // output), the second to emit 2 outputs spanning [0, 1/30), and finish() to emit the
    // last buffered frame at 1/30.
    let pts0 = CMTime(value: 0, timescale: 30)
    let pts1 = CMTime(value: 1, timescale: 30)

    let buffer0 = try makeTestPixelBuffer(size: inputSize)
    nonisolated(unsafe) let captured0 = buffer0
    let firstOutputs = try await chain.process(
      captured0, presentationTimeStamp: pts0, outputPool: nil)
    #expect(firstOutputs.isEmpty)

    let buffer1 = try makeTestPixelBuffer(size: inputSize)
    nonisolated(unsafe) let captured1 = buffer1
    let secondOutputs = try await chain.process(
      captured1, presentationTimeStamp: pts1, outputPool: nil)
    try #require(secondOutputs.count == 2)
    for output in secondOutputs {
      #expect(CVPixelBufferGetWidth(output.pixelBuffer) == Int(outputSize.width))
      #expect(CVPixelBufferGetHeight(output.pixelBuffer) == Int(outputSize.height))
    }

    let flushed = try await chain.finish(outputPool: nil)
    try #require(flushed.count == 1)
    #expect(CVPixelBufferGetWidth(flushed[0].pixelBuffer) == Int(outputSize.width))
    #expect(flushed[0].presentationTimeStamp == pts1)
  }

  @Test("Output count scales with target/source fps ratio")
  func outputCountMatchesRatio() async throws {
    let size = CGSize(width: 320, height: 240)
    // 30 fps source → 90 fps target: 3× ratio.
    let converter = try await VTFrameRateConverter(frameSize: size, targetFrameRate: 90)

    let sourceFrameCount = 10
    var totalOutputs = 0
    for frameIdx in 0..<sourceFrameCount {
      let buffer = try makeTestPixelBuffer(size: size)
      nonisolated(unsafe) let captured = buffer
      let pts = CMTime(value: Int64(frameIdx), timescale: 30)
      let outputs = try await converter.process(
        captured, presentationTimeStamp: pts, outputPool: nil)
      totalOutputs += outputs.count
    }
    totalOutputs += try await converter.finish(outputPool: nil).count

    // Exact count: 3 target frames per source interval × (N - 1) source intervals + 1 flushed.
    // For 10 source frames: 3 × 9 + 1 = 28.
    #expect(totalOutputs == 28)
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

  @Test(
    "Export session preserves input extension",
    arguments: ["mov", "m4v", "mp4"]
  )
  func extensionPreserved(ext: String) throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.\(ext)")
    let asset = AVURLAsset(url: url)

    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .h264,
      preferredOutputURL: url,
      outputSize: CGSize(width: 640, height: 480)
    )

    #expect(session.outputURL.pathExtension == ext)
  }

  @Test("Export session progress is configured")
  func progressConfiguration() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.mov")
    let asset = AVURLAsset(url: url)

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

    let asset = AVURLAsset(url: inputURL)
    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .h264,
      preferredOutputURL: outputURL,
      outputSize: outputSize
    )

    try await session.export()

    #expect(FileManager.default.fileExists(atPath: outputURL.path))

    let outputAsset = AVURLAsset(url: outputURL)
    let videoTrack = try await outputAsset.loadTracks(withMediaType: .video).first
    let trackSize = try await videoTrack?.load(.naturalSize)

    #expect(trackSize?.width == outputSize.width)
    #expect(trackSize?.height == outputSize.height)
  }

  /// https://github.com/finnvoor/fx-upscale/issues/8
  @Test("Transformed video preserves transform")
  func upscaleTransformedVideo() async throws {
    try requireMetal()

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

    let asset = AVURLAsset(url: inputURL)
    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .h264,
      preferredOutputURL: outputURL,
      outputSize: outputSize
    )

    try await session.export()

    #expect(FileManager.default.fileExists(atPath: outputURL.path))

    let outputAsset = AVURLAsset(url: outputURL)
    let videoTrack = try await outputAsset.loadTracks(withMediaType: .video).first
    let outTrack = try #require(videoTrack)
    let outTransform = try await outTrack.load(.preferredTransform)
    let epsilon: CGFloat = 1e-6
    #expect(abs(outTransform.a - rotationTransform.a) < epsilon)
    #expect(abs(outTransform.b - rotationTransform.b) < epsilon)
    #expect(abs(outTransform.c - rotationTransform.c) < epsilon)
    #expect(abs(outTransform.d - rotationTransform.d) < epsilon)
    #expect(abs(outTransform.tx - rotationTransform.tx) < epsilon)
    #expect(abs(outTransform.ty - rotationTransform.ty) < epsilon)
  }

  /// https://github.com/finnvoor/fx-upscale/commit/e6666afdb9a5ce1eda38437bec25b0743b740360
  @Test("Missing color info doesn't crash")
  func upscaleMissingColorInfo() async throws {
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
      .appendingPathComponent("no_color_\(UUID().uuidString).mov")
    defer { TestVideoGenerator.cleanup(outputURL) }

    let asset = AVURLAsset(url: inputURL)
    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .h264,
      preferredOutputURL: outputURL,
      outputSize: outputSize
    )

    try await session.export()

    #expect(FileManager.default.fileExists(atPath: outputURL.path))
  }

  /// https://github.com/finnvoor/fx-upscale/issues/7
  @Test("Audio track is preserved")
  func audioFormatMaintained() async throws {
    try requireMetal()

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

    let asset = AVURLAsset(url: inputURL)
    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .h264,
      preferredOutputURL: outputURL,
      outputSize: outputSize
    )

    try await session.export()

    let inputAudioTracks = try await asset.loadTracks(withMediaType: .audio)
    let outputAsset = AVURLAsset(url: outputURL)
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

    let asset = AVURLAsset(url: inputURL)
    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .h264,
      preferredOutputURL: outputURL,
      outputSize: outputSize,
      creator: "TestCreator"
    )

    try await session.export()

    #expect(FileManager.default.fileExists(atPath: outputURL.path))
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

    let asset = AVURLAsset(url: inputURL)
    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .h264,
      preferredOutputURL: outputURL,
      outputSize: outputSize
    )

    #expect(session.progress.fileURL == outputURL)

    try await session.export()

    #expect(FileManager.default.fileExists(atPath: outputURL.path))
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

    FileManager.default.createFile(atPath: outputURL.path, contents: Data(), attributes: nil)
    defer { TestVideoGenerator.cleanup(outputURL) }

    let asset = AVURLAsset(url: inputURL)
    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .h264,
      preferredOutputURL: outputURL,
      outputSize: outputSize
    )

    await #expect(throws: UpscalingExportSession.Error.self) {
      try await session.export()
    }
  }

  @Test("Cancelling mid-export cleans up the partial output")
  func cancelRemovesPartialOutput() async throws {
    try requireMetal()

    // A longer video so we have time to observe the cancellation mid-pump.
    let inputSize = CGSize(width: 640, height: 480)
    let outputSize = CGSize(width: 1280, height: 960)
    let inputURL = try await TestVideoGenerator.createTestVideo(
      duration: 2.0,
      frameRate: 30,
      size: inputSize
    )
    defer { TestVideoGenerator.cleanup(inputURL) }

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("cancel_\(UUID().uuidString).mov")
    defer { TestVideoGenerator.cleanup(outputURL) }

    let asset = AVURLAsset(url: inputURL)
    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .h264,
      preferredOutputURL: outputURL,
      outputSize: outputSize
    )

    let task = Task {
      try await session.export()
    }

    // Give the pump a chance to start before cancelling.
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()

    // The cancellation surfaces as either CancellationError or an AVFoundation error, depending
    // on exactly where the pump was suspended — either is acceptable. What matters is that the
    // partial output file was removed.
    _ = try? await task.value
    #expect(!FileManager.default.fileExists(atPath: outputURL.path))
  }
}

// MARK: - UpscalerKind Preflight Tests

@Suite("UpscalerKind Preflight")
struct UpscalerKindPreflightTests {
  /// Skips the enclosing test if `VTSuperResolutionScaler` isn't available on this device.
  private func requireVTSuperResolution() throws {
    guard VTSuperResolutionScalerConfiguration.isSupported else {
      throw TestSkipError("VTSuperResolutionScaler not supported on this device")
    }
  }

  @Test("Spatial preflight always succeeds for valid sizes")
  func spatialPreflightSucceeds() throws {
    try UpscalerKind.spatial.preflight(
      inputSize: CGSize(width: 1920, height: 1080),
      outputSize: CGSize(width: 3840, height: 2160))

    try UpscalerKind.spatial.preflight(
      inputSize: CGSize(width: 1001, height: 563),
      outputSize: CGSize(width: 2002, height: 1126))
  }

  @Test("Super-resolution preflight rejects non-integer scale factor")
  func superResolutionRejectsNonIntegerRatio() throws {
    try requireVTSuperResolution()
    #expect(throws: VTSuperResolutionUpscaler.Error.self) {
      // 1.5× is fractional — not in supportedScaleFactors.
      try UpscalerKind.superResolution.preflight(
        inputSize: CGSize(width: 1280, height: 720),
        outputSize: CGSize(width: 1920, height: 1080))
    }
  }

  @Test("Super-resolution preflight rejects anisotropic scaling")
  func superResolutionRejectsAnisotropic() throws {
    try requireVTSuperResolution()
    #expect(throws: VTSuperResolutionUpscaler.Error.self) {
      // 2× width, 3× height.
      try UpscalerKind.superResolution.preflight(
        inputSize: CGSize(width: 640, height: 240),
        outputSize: CGSize(width: 1280, height: 720))
    }
  }

  @Test("Super-resolution preflight rejects inputs above 1920x1080 on macOS")
  func superResolutionRejectsOversizedInput() throws {
    try requireVTSuperResolution()
    #expect(throws: VTSuperResolutionUpscaler.Error.self) {
      try UpscalerKind.superResolution.preflight(
        inputSize: CGSize(width: 3840, height: 2160),
        outputSize: CGSize(width: 7680, height: 4320))
    }
  }

  @Test("Super-resolution preflight accepts the device's supported scale factors")
  func superResolutionAcceptsSupportedFactor() throws {
    try requireVTSuperResolution()
    // Pick the smallest supported factor so the resulting output fits under the 1920×1080
    // input cap with room to spare. Devices in the wild currently advertise factors like
    // [4], so don't hard-code 2×.
    let supported = VTSuperResolutionScalerConfiguration.supportedScaleFactors.sorted()
    let factor = try #require(supported.first)
    // Keep the input small so `factor * 360 ≤ 1080` even for larger factors.
    let inputSize = CGSize(width: 320, height: 180)
    let outputSize = CGSize(
      width: inputSize.width * CGFloat(factor),
      height: inputSize.height * CGFloat(factor))
    try UpscalerKind.superResolution.preflight(
      inputSize: inputSize, outputSize: outputSize)
  }
}

// MARK: - Test Skip Error

struct TestSkipError: Error, CustomStringConvertible {
  let description: String
  init(_ message: String) { self.description = message }
}

// MARK: - Dimension Calculation Tests

@Suite("Dimension Calculation")
struct DimensionCalculationTests {
  @Test("Defaults to 2x when no dimensions requested")
  func defaultDoubles() {
    let out = calculateOutputDimensions(
      inputSize: CGSize(width: 640, height: 480),
      requestedWidth: nil, requestedHeight: nil)
    #expect(out == CGSize(width: 1280, height: 960))
  }

  @Test("Width-only preserves aspect ratio")
  func widthOnly() {
    let out = calculateOutputDimensions(
      inputSize: CGSize(width: 1920, height: 1080),
      requestedWidth: 3840, requestedHeight: nil)
    #expect(out == CGSize(width: 3840, height: 2160))
  }

  @Test("Height-only preserves aspect ratio")
  func heightOnly() {
    let out = calculateOutputDimensions(
      inputSize: CGSize(width: 1920, height: 1080),
      requestedWidth: nil, requestedHeight: 2160)
    #expect(out == CGSize(width: 3840, height: 2160))
  }

  @Test("Both width and height honored")
  func bothProvided() {
    let out = calculateOutputDimensions(
      inputSize: CGSize(width: 1920, height: 1080),
      requestedWidth: 1000, requestedHeight: 800)
    #expect(out == CGSize(width: 1000, height: 800))
  }

  @Test("Odd widths are rounded up to even")
  func oddDimensionsAreEvened() {
    let out = calculateOutputDimensions(
      inputSize: CGSize(width: 1001, height: 563),
      requestedWidth: 2001, requestedHeight: nil)
    #expect(Int(out.width) % 2 == 0)
    #expect(Int(out.height) % 2 == 0)
  }

  @Test("Non-integer aspect ratios produce even dimensions")
  func nonIntegerRatio() {
    // 720x405 → request width 1000 → height 562.5 → rounded 563 → evened to 564
    let out = calculateOutputDimensions(
      inputSize: CGSize(width: 720, height: 405),
      requestedWidth: 1000, requestedHeight: nil)
    #expect(Int(out.width) == 1000)
    #expect(Int(out.height) % 2 == 0)
  }

  @Test("Single-pixel input survives even-rounding")
  func onePixelInput() {
    let out = calculateOutputDimensions(
      inputSize: CGSize(width: 1, height: 1),
      requestedWidth: nil, requestedHeight: nil)
    #expect(out == CGSize(width: 2, height: 2))
  }
}
