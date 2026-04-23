import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import Metal
import Testing
import VideoToolbox
import os

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

      guard let buffer = pixelBuffer else {
        throw Error.pixelBufferCreationFailed
      }

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

  enum Error: Swift.Error {
    case pixelBufferCreationFailed
    case audioFormatDescriptionCreationFailed
    case blockBufferCreationFailed
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
    guard let formatDescription else { throw Error.audioFormatDescriptionCreationFailed }

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
      guard let blockBuffer else { throw Error.blockBufferCreationFailed }
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

  @Test("URL renamed leaves extensionless paths bare")
  func renamedNoExtension() {
    // Documented contract in URL+Extensions.swift: when the URL has no extension,
    // no trailing `.` is appended after the transform.
    let url = URL(fileURLWithPath: "/tmp/input")
    let renamed = url.renamed { "\($0)_upscaled" }

    #expect(renamed.lastPathComponent == "input_upscaled")
    #expect(renamed.pathExtension == "")
    #expect(!renamed.lastPathComponent.hasSuffix("."))
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
  func filterThreadSafety() async throws {
    let inputImage = try loadLadybird()
    let outputSize = CGSize(
      width: inputImage.extent.width * 2,
      height: inputImage.extent.height * 2
    )

    let filter = UpscalingFilter()
    filter.inputImage = inputImage
    filter.outputSize = outputSize

    // Concurrently read `outputImage` from N tasks against a single shared filter to exercise
    // the internal lock + per-call scaler allocation. Return only the Sendable extent size from
    // each task since `CIImage` itself isn't Sendable.
    await withTaskGroup(of: CGSize?.self) { group in
      for _ in 0..<10 {
        group.addTask {
          filter.outputImage?.extent.size
        }
      }
      var count = 0
      for await size in group {
        #expect(size == outputSize)
        count += 1
      }
      #expect(count == 10)
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
  @Test("Empty chain forwards input unchanged as identity")
  func emptyChainIsIdentity() async throws {
    let size = CGSize(width: 320, height: 240)
    let chain = try FrameProcessorChain(inputSize: size, outputSize: size, stages: [])
    #expect(chain.inputSize == size)
    #expect(chain.outputSize == size)

    let buffer = try makeTestPixelBuffer(size: size)
    nonisolated(unsafe) let captured = buffer
    let pts = CMTime(value: 17, timescale: 30)
    let outputs = try await chain.process(
      captured, presentationTimeStamp: pts, outputPool: nil)
    try #require(outputs.count == 1)
    #expect(outputs[0].pixelBuffer === buffer)
    #expect(outputs[0].presentationTimeStamp == pts)
  }

  @Test("Empty chain rejects non-identity sizes")
  func emptyChainRejectsNonIdentity() throws {
    #expect(throws: FrameProcessorChain.Error.self) {
      _ = try FrameProcessorChain(
        inputSize: CGSize(width: 320, height: 240),
        outputSize: CGSize(width: 640, height: 480),
        stages: [])
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
      _ = try FrameProcessorChain(
        inputSize: CGSize(width: 320, height: 240),
        outputSize: CGSize(width: 1600, height: 1200),
        stages: [a, b])
    }
  }

  @Test("Chain rejects pixel-format adjacency mismatch")
  func mismatchedStageFormats() throws {
    struct BGRAOutStage: FrameProcessorBackend {
      let inputSize: CGSize
      let outputSize: CGSize
      let displayName = "Fake BGRA stage"
      var producedOutputFormat: OSType { kCVPixelFormatType_32BGRA }
      var supportedInputFormats: Set<OSType> { [kCVPixelFormatType_32BGRA] }
      func process(
        _ pixelBuffer: sending CVPixelBuffer, presentationTimeStamp: CMTime,
        outputPool: sending CVPixelBufferPool?
      ) async throws -> [FrameProcessorOutput] { [] }
    }
    struct TenBitOnlyStage: FrameProcessorBackend {
      let inputSize: CGSize
      let outputSize: CGSize
      let displayName = "Fake 10-bit stage"
      var producedOutputFormat: OSType { kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange }
      var supportedInputFormats: Set<OSType> {
        [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
      }
      func process(
        _ pixelBuffer: sending CVPixelBuffer, presentationTimeStamp: CMTime,
        outputPool: sending CVPixelBufferPool?
      ) async throws -> [FrameProcessorOutput] { [] }
    }
    let size = CGSize(width: 320, height: 240)
    let bgra = BGRAOutStage(inputSize: size, outputSize: size)
    let tenBit = TenBitOnlyStage(inputSize: size, outputSize: size)
    #expect(throws: FrameProcessorChain.Error.self) {
      _ = try FrameProcessorChain(
        inputSize: size, outputSize: size, stages: [bgra, tenBit])
    }
  }

  @Test("processSingle rejects backends that emit multiple outputs")
  func processSingleRejectsMultipleOutputs() async throws {
    struct MultiOutputStage: FrameProcessorBackend {
      let inputSize: CGSize
      let outputSize: CGSize
      let displayName = "Fake multi-output stage"

      func process(
        _ pixelBuffer: sending CVPixelBuffer,
        presentationTimeStamp: CMTime,
        outputPool: sending CVPixelBufferPool?
      ) async throws -> [FrameProcessorOutput] {
        nonisolated(unsafe) let first = pixelBuffer
        nonisolated(unsafe) let second = pixelBuffer
        return [
          FrameProcessorOutput(pixelBuffer: first, presentationTimeStamp: presentationTimeStamp),
          FrameProcessorOutput(
            pixelBuffer: second,
            presentationTimeStamp: presentationTimeStamp + CMTime(value: 1, timescale: 30)),
        ]
      }
    }

    let size = CGSize(width: 320, height: 240)
    let stage = MultiOutputStage(inputSize: size, outputSize: size)
    let buffer = try makeTestPixelBuffer(size: size)
    nonisolated(unsafe) let captured = buffer

    await #expect(throws: FrameProcessorError.self) {
      _ = try await stage.processSingle(captured)
    }
  }

  @Test("Single-stage chain behaves like the backend")
  func singleStagePassthrough() async throws {
    let inputSize = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)
    guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
      throw TestSkipError("Metal device not available")
    }
    let chain = try FrameProcessorChain(
      inputSize: inputSize, outputSize: outputSize, stages: [upscaler])
    #expect(chain.inputSize == inputSize)
    #expect(chain.outputSize == outputSize)

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

  @Test("First frame rejects mismatched input size")
  func firstFrameRejectsMismatchedInputSize() async throws {
    let size = CGSize(width: 640, height: 480)
    let processor = try await VTMotionBlurProcessor(frameSize: size, strength: 50)
    let wrong = try makeTestPixelBuffer(size: CGSize(width: 320, height: 240))
    nonisolated(unsafe) let captured = wrong

    await #expect(throws: PixelBufferIOError.inputSizeMismatch) {
      _ = try await processor.process(
        captured, presentationTimeStamp: .zero, outputPool: nil)
    }
  }

  @Test("Composes after a spatial upscaler in a chain")
  func composesAfterSpatialUpscaler() async throws {
let inputSize = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)

    guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
      throw TestSkipError("Metal device not available")
    }
    let blur = try await VTMotionBlurProcessor(frameSize: outputSize, strength: 50)
    let chain = try FrameProcessorChain(
      inputSize: inputSize, outputSize: outputSize, stages: [upscaler, blur])

    #expect(chain.inputSize == inputSize)
    #expect(chain.outputSize == outputSize)

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

  @Test("First frame rejects mismatched input size")
  func firstFrameRejectsMismatchedInputSize() async throws {
    let size = CGSize(width: 640, height: 480)
    let processor = try await VTTemporalNoiseProcessor(frameSize: size, strength: 50)
    let wrong = try makeTestPixelBuffer(size: CGSize(width: 320, height: 240))
    nonisolated(unsafe) let captured = wrong

    await #expect(throws: PixelBufferIOError.inputSizeMismatch) {
      _ = try await processor.process(
        captured, presentationTimeStamp: .zero, outputPool: nil)
    }
  }

  @Test("Composes before a spatial upscaler in a chain")
  func composesBeforeSpatialUpscaler() async throws {
    let inputSize = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)

    let denoise = try await VTTemporalNoiseProcessor(frameSize: inputSize, strength: 50)
    guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
      throw TestSkipError("Metal device not available")
    }
    let chain = try FrameProcessorChain(
      inputSize: inputSize, outputSize: outputSize, stages: [denoise, upscaler])

    #expect(chain.inputSize == inputSize)
    #expect(chain.outputSize == outputSize)

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
    let chain = try FrameProcessorChain(
      inputSize: inputSize, outputSize: outputSize, stages: [upscaler, converter])

    #expect(chain.inputSize == inputSize)
    #expect(chain.outputSize == outputSize)

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

// MARK: - Target PTS Arithmetic Tests

/// Pure arithmetic over `computeTargetPTS` — no VT device dependency, so no availability gate.
/// Extracted from `FrameRateConverterTests` so these regression guards keep running on hardware
/// where `VTFrameRateConversionConfiguration` isn't supported.
@Suite("Target PTS Arithmetic")
struct TargetPTSArithmeticTests {
  @Test("targetPTS stays monotonic past old Int32 ceiling")
  func targetPTSMonotonicPastInt32Ceiling() {
    // 59.94 fps, 1 GHz fallback timescale — matches VTFrameRateConverter's non-integer path.
    let period = CMTime(seconds: 1.0 / 59.94, preferredTimescale: 1_000_000_000)
    let anchor = CMTime.zero
    let atCeiling = computeTargetPTS(anchor: anchor, period: period, index: Int64(Int32.max))
    let pastCeiling = computeTargetPTS(
      anchor: anchor, period: period, index: Int64(Int32.max) + 1)
    // Regression guard: the old Int32(clamping:) path collapsed every index past Int32.max
    // onto the same PTS. Post-fix the sequence must keep stepping.
    #expect(pastCeiling > atCeiling)
    #expect(pastCeiling - atCeiling == period)
  }

  @Test("targetPTS is exact for integer rates at large index")
  func targetPTSExactForIntegerRatesAtLargeIndex() {
    // Integer-rate path uses period = (1, rate), so value * index is exact.
    let period = CMTime(value: 1, timescale: 60)
    let index: Int64 = 1_000_000_000
    let pts = computeTargetPTS(anchor: .zero, period: period, index: index)
    #expect(pts == CMTime(value: index, timescale: 60))
  }

  @Test("targetPTS step equals period for representative rates")
  func targetPTSStepEqualsPeriod() {
    for (period, anchor) in [
      (CMTime(value: 1, timescale: 30), CMTime(value: 17, timescale: 30)),
      (CMTime(seconds: 1.0 / 59.94, preferredTimescale: 1_000_000_000), CMTime.zero),
      (CMTime(seconds: 1.0 / 23.976, preferredTimescale: 1_000_000_000), CMTime.zero),
    ] {
      let a = computeTargetPTS(anchor: anchor, period: period, index: 100)
      let b = computeTargetPTS(anchor: anchor, period: period, index: 101)
      #expect(b - a == period)
    }
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

  /// Shared fixture: synthesizes a test video, computes a unique output URL under the temp
  /// directory, registers cleanup for both, and constructs an `UpscalingExportSession`
  /// configured by the arguments. The body receives the session, the output URL, and the
  /// source `AVURLAsset` so tests can introspect the input too.
  ///
  /// Tests that just want the default setup can rely on the defaults; tests that need an
  /// audio track, a source transform, a larger source, or a non-default export parameter
  /// pass the relevant arguments explicitly.
  private func withExportFixture(
    duration: TimeInterval = 0.5,
    frameRate: Int = 10,
    size: CGSize = CGSize(width: 320, height: 240),
    includeAudio: Bool = false,
    transform: CGAffineTransform? = nil,
    outputSize: CGSize = CGSize(width: 640, height: 480),
    outputCodec: AVVideoCodecType? = .h264,
    quality: Double? = nil,
    keyFrameInterval: TimeInterval? = nil,
    creator: String? = nil,
    body: (_ session: UpscalingExportSession, _ outputURL: URL, _ asset: AVURLAsset) async throws -> Void
  ) async throws {
    let inputURL = try await TestVideoGenerator.createTestVideo(
      duration: duration,
      frameRate: frameRate,
      size: size,
      includeAudio: includeAudio,
      transform: transform
    )
    defer { TestVideoGenerator.cleanup(inputURL) }

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("fixture_\(UUID().uuidString).mov")
    defer { TestVideoGenerator.cleanup(outputURL) }

    let asset = AVURLAsset(url: inputURL)
    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: outputCodec,
      preferredOutputURL: outputURL,
      outputSize: outputSize,
      quality: quality,
      keyFrameInterval: keyFrameInterval,
      creator: creator
    )
    try await body(session, outputURL, asset)
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
    let outputSize = CGSize(width: 640, height: 480)
    try await withExportFixture(outputSize: outputSize) { session, outputURL, _ in
      try await session.export()

      #expect(FileManager.default.fileExists(atPath: outputURL.path))

      let outputAsset = AVURLAsset(url: outputURL)
      let videoTrack = try await outputAsset.loadTracks(withMediaType: .video).first
      let trackSize = try await videoTrack?.load(.naturalSize)

      #expect(trackSize?.width == outputSize.width)
      #expect(trackSize?.height == outputSize.height)
    }
  }

  /// https://github.com/finnvoor/fx-upscale/issues/8
  @Test("Transformed video preserves transform")
  func upscaleTransformedVideo() async throws {
    try requireMetal()

    let rotationTransform = CGAffineTransform(rotationAngle: .pi / 2)
    try await withExportFixture(transform: rotationTransform) { session, outputURL, _ in
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
  }

  /// https://github.com/finnvoor/fx-upscale/commit/e6666afdb9a5ce1eda38437bec25b0743b740360
  @Test("Missing color info doesn't crash")
  func upscaleMissingColorInfo() async throws {
    try requireMetal()

    try await withExportFixture { session, outputURL, _ in
      try await session.export()
      #expect(FileManager.default.fileExists(atPath: outputURL.path))
    }
  }

  /// https://github.com/finnvoor/fx-upscale/issues/7
  @Test("Audio track is preserved")
  func audioFormatMaintained() async throws {
    try requireMetal()

    try await withExportFixture(includeAudio: true) { session, outputURL, asset in
      try await session.export()

      let inputAudioTracks = try await asset.loadTracks(withMediaType: .audio)
      let outputAsset = AVURLAsset(url: outputURL)
      let outputAudioTracks = try await outputAsset.loadTracks(withMediaType: .audio)

      try #require(!inputAudioTracks.isEmpty, "Test fixture must contain an input audio track")
      try #require(!outputAudioTracks.isEmpty, "Audio track should be preserved on output")
    }
  }

  /// https://github.com/finnvoor/fx-upscale/issues/6
  @Test("Metadata is preserved")
  func maintainMetadata() async throws {
    try requireMetal()

    try await withExportFixture(creator: "TestCreator") { session, outputURL, _ in
      try await session.export()

      #expect(FileManager.default.fileExists(atPath: outputURL.path))

      #if os(macOS)
        // Creator is stored as the `kMDItemCreator` Spotlight xattr by
        // `UpscalingExportSession` (see `creatorXattrName`). Read it back via getxattr and
        // decode the binary plist.
        let xattrName = "com.apple.metadata:kMDItemCreator"
        let size = outputURL.withUnsafeFileSystemRepresentation { path -> Int in
          getxattr(path, xattrName, nil, 0, 0, 0)
        }
        try #require(size > 0, "creator xattr should exist on output")
        var data = Data(count: size)
        let readSize = data.withUnsafeMutableBytes { bytes -> Int in
          outputURL.withUnsafeFileSystemRepresentation { path in
            getxattr(path, xattrName, bytes.baseAddress, size, 0, 0)
          }
        }
        try #require(readSize == size)
        let plist = try PropertyListSerialization.propertyList(
          from: data, options: [], format: nil)
        #expect(plist as? String == "TestCreator")
      #endif
    }
  }

  /// https://github.com/finnvoor/fx-upscale/issues/4
  @Test("Export progress is reported")
  func exportProgress() async throws {
    try requireMetal()

    try await withExportFixture(duration: 1.0, frameRate: 15) { session, outputURL, _ in
      #expect(session.progress.fileURL == outputURL)

      try await session.export()

      #expect(FileManager.default.fileExists(atPath: outputURL.path))
      #expect(session.progress.totalUnitCount > 0)
    }
  }

  @Test("Output file already exists throws error")
  func outputExistsError() async throws {
    try requireMetal()

    try await withExportFixture { session, outputURL, _ in
      // Create a zero-byte file at the output URL *before* export, so the pre-flight check
      // inside `export()` throws `outputURLAlreadyExists`.
      FileManager.default.createFile(atPath: outputURL.path, contents: Data(), attributes: nil)

      await #expect(throws: UpscalingExportSession.Error.self) {
        try await session.export()
      }
    }
  }

  @Test("keyFrameInterval parameter is honored without error")
  func keyFrameIntervalAccepted() async throws {
    try requireMetal()

    // Introspecting actual IDR intervals from the muxed output is non-trivial (requires
    // parsing raw NALUs or using AVAssetReader with `trackSample`.attachments to find
    // `kCMSampleAttachmentKey_NotSync`). The lighter contract this test pins down is the
    // public surface: a 0.5s keyframeInterval must flow through `export()` without error
    // and produce a valid, playable output file. Regression guard against accidentally
    // dropping the `kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration` wiring in
    // `videoAssetWriterInput(...)`.
    try await withExportFixture(
      duration: 1.0, frameRate: 30, keyFrameInterval: 0.5
    ) { session, outputURL, _ in
      try await session.export()

      #expect(FileManager.default.fileExists(atPath: outputURL.path))

      // File must be readable as a valid AVAsset with a video track at the expected size.
      let outputAsset = AVURLAsset(url: outputURL)
      let videoTrack = try await outputAsset.loadTracks(withMediaType: .video).first
      let outTrack = try #require(videoTrack)
      let size = try await outTrack.load(.naturalSize)
      #expect(size.width == 640)
      #expect(size.height == 480)
    }
  }

  @Test("quality parameter is honored without error")
  func qualityAccepted() async throws {
    try requireMetal()

    // Export the same source at two quality levels and confirm both succeed. We don't assert
    // a strict "low < high" byte-size relationship because VT's quality-to-bitrate mapping is
    // codec- and content-dependent, and on very short clips the size difference can be
    // dominated by mux overhead. The value this test adds is (a) pinning down that the
    // parameter is plumbed through without rejecting valid inputs, and (b) producing two
    // outputs whose sizes we can log for a sanity check.
    var sizes: [Double: Int64] = [:]
    for quality in [0.1, 0.9] {
      try await withExportFixture(
        duration: 0.5, frameRate: 10, quality: quality
      ) { session, outputURL, _ in
        try await session.export()
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        #expect(bytes > 0)
        sizes[quality] = bytes
      }
    }
    #expect(sizes.count == 2)
  }

  @Test("Asset with no tracks throws noMediaTracks")
  func noMediaTracksError() async throws {
    // A fresh, empty `AVMutableComposition` satisfies the public `AVAsset` contract while
    // reporting an empty `tracks` array — hits the `guard !mediaTracks.isEmpty` branch in
    // `UpscalingExportSession.export()` without needing a custom HDR/audio-only fixture.
    let emptyAsset = AVMutableComposition()

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("no_tracks_\(UUID().uuidString).mov")
    defer { TestVideoGenerator.cleanup(outputURL) }

    let session = UpscalingExportSession(
      asset: emptyAsset,
      outputCodec: .h264,
      preferredOutputURL: outputURL,
      outputSize: CGSize(width: 640, height: 480)
    )

    await #expect(throws: UpscalingExportSession.Error.self) {
      do {
        try await session.export()
      } catch let error as UpscalingExportSession.Error {
        guard case .noMediaTracks = error else {
          Issue.record("Expected .noMediaTracks, got \(error)")
          throw error
        }
        throw error
      }
    }
  }

  // HDR tests use ffmpeg-generated fixtures under `Tests/UpscalingTests/Resources/`. The
  // `gradient_pq_hdr.mov` fixture is a 1s 480×270 10-bit PQ/Rec.2020 HEVC clip with mastering
  // display + content light level side-data; `gradient_rec709_10bit.mov` is the Rec.709 10-bit
  // regression fixture for the tightened `isUnsupportedForSRGBPath` check.

  @Test("Spatial path rejects PQ source with .unsupportedColorSpace")
  func spatialRejectsPQSource() async throws {
    let url = try #require(
      Bundle.module.url(forResource: "gradient_pq_hdr", withExtension: "mov"))
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("pq_spatial_\(UUID().uuidString).mov")
    defer { TestVideoGenerator.cleanup(outputURL) }

    let session = UpscalingExportSession(
      asset: AVURLAsset(url: url),
      outputCodec: .hevc,
      preferredOutputURL: outputURL,
      outputSize: CGSize(width: 960, height: 540))

    await #expect(throws: UpscalingExportSession.Error.self) {
      do {
        try await session.export()
      } catch let error as UpscalingExportSession.Error {
        guard case .unsupportedColorSpace = error else {
          Issue.record("Expected .unsupportedColorSpace, got \(error)")
          throw error
        }
        throw error
      }
    }
    #expect(!FileManager.default.fileExists(atPath: outputURL.path))
  }

  @Test("Super-resolution path accepts PQ source and round-trips color metadata")
  func superResolutionRoundTripsPQ() async throws {
    guard VTSuperResolutionScalerConfiguration.isSupported else {
      throw TestSkipError("VTSuperResolutionScaler not supported on this device")
    }
    let supported = VTSuperResolutionScalerConfiguration.supportedScaleFactors.sorted()
    let factor = try #require(supported.first)

    let url = try #require(
      Bundle.module.url(forResource: "gradient_pq_hdr", withExtension: "mov"))
    let inputSize = CGSize(width: 480, height: 270)
    let outputSize = CGSize(
      width: inputSize.width * CGFloat(factor),
      height: inputSize.height * CGFloat(factor))

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("pq_super_\(UUID().uuidString).mov")
    defer { TestVideoGenerator.cleanup(outputURL) }

    // Single-stage super-resolution chain opts into 10-bit 420 video-range round-trip.
    let chainFactory: UpscalingExportSession.ChainFactory = { inputSize in
      let backend: any FrameProcessorBackend
      do {
        backend = try await VTSuperResolutionUpscaler(
          inputSize: inputSize, outputSize: outputSize,
          pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
      } catch {
        throw TestSkipError(
          "VTSuperResolutionUpscaler init failed (likely model unavailable): \(error)")
      }
      return try FrameProcessorChain(
        inputSize: inputSize, outputSize: outputSize, stages: [backend])
    }
    let capabilities = UpscalingExportSession.ChainCapabilities(
      supportedSourceInputFormats: [
        kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
      ],
      producedOutputFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)

    let session = UpscalingExportSession(
      asset: AVURLAsset(url: url),
      outputCodec: .hevc,
      preferredOutputURL: outputURL,
      outputSize: outputSize,
      chainFactory: chainFactory,
      chainCapabilities: capabilities)

    try await session.export()

    // Inspect output format metadata.
    let outAsset = AVURLAsset(url: outputURL)
    let outTrack = try #require(
      try await outAsset.loadTracks(withMediaType: .video).first)
    let outFormat = try #require(try await outTrack.load(.formatDescriptions).first)

    #expect(outFormat.colorPrimaries == AVVideoColorPrimaries_ITU_R_2020)
    #expect(outFormat.colorTransferFunction == AVVideoTransferFunction_SMPTE_ST_2084_PQ)
    #expect(outFormat.colorYCbCrMatrix == AVVideoYCbCrMatrix_ITU_R_2020)
    #expect(outFormat.isHDR)
    #expect(outFormat.masteringDisplayColorVolume != nil)
    #expect(outFormat.contentLightLevelInfo != nil)
  }

  @Test("Spatial path rejects 10-bit Rec. 709 source")
  func spatialRejects10BitRec709() async throws {
    let url = try #require(
      Bundle.module.url(forResource: "gradient_rec709_10bit", withExtension: "mov"))
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let fmt = try #require(try await track.load(.formatDescriptions).first)
    // Sanity-check that the fixture surfaced as 10-bit in the format description. If the OS
    // decoder didn't propagate the `BitsPerComponent` extension, skip rather than fail:
    // this is specifically testing the tightened reject, which relies on that extension.
    guard (fmt.bitsPerComponent ?? 8) >= 10 else {
      throw TestSkipError("10-bit source decoded without BitsPerComponent; skipping")
    }
    #expect(fmt.isUnsupportedForSRGBPath)

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("rec709_10bit_\(UUID().uuidString).mov")
    defer { TestVideoGenerator.cleanup(outputURL) }

    let session = UpscalingExportSession(
      asset: asset,
      outputCodec: .hevc,
      preferredOutputURL: outputURL,
      outputSize: CGSize(width: 960, height: 540))

    await #expect(throws: UpscalingExportSession.Error.self) {
      do {
        try await session.export()
      } catch let error as UpscalingExportSession.Error {
        guard case .unsupportedColorSpace = error else {
          Issue.record("Expected .unsupportedColorSpace, got \(error)")
          throw error
        }
        throw error
      }
    }
  }

  @Test("Chain with Lanczos rejects with a stage-named error")
  func chainLevelSRGBRejectNamesStage() async throws {
    let url = try #require(
      Bundle.module.url(forResource: "gradient_pq_hdr", withExtension: "mov"))
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("pq_chain_reject_\(UUID().uuidString).mov")
    defer { TestVideoGenerator.cleanup(outputURL) }

    let capabilities = UpscalingExportSession.ChainCapabilities(
      supportedSourceInputFormats: [kCVPixelFormatType_32BGRA],
      producedOutputFormat: kCVPixelFormatType_32BGRA,
      srgbRejectingStageName: "Lanczos downsample")
    let session = UpscalingExportSession(
      asset: AVURLAsset(url: url),
      outputCodec: .hevc,
      preferredOutputURL: outputURL,
      outputSize: CGSize(width: 240, height: 135),
      chainCapabilities: capabilities)

    do {
      try await session.export()
      Issue.record("Expected export to throw")
    } catch let error as UpscalingExportSession.Error {
      guard case .unsupportedColorSpace(let name) = error else {
        Issue.record("Expected .unsupportedColorSpace, got \(error)")
        throw error
      }
      #expect(name == "Lanczos downsample")
      #expect(error.errorDescription?.contains("Lanczos downsample") == true)
    }
  }

  @Test("Identity re-encode of PQ source preserves HDR metadata")
  func identityReEncodePreservesHDRMetadata() async throws {
    let url = try #require(
      Bundle.module.url(forResource: "gradient_pq_hdr", withExtension: "mov"))
    let inputSize = CGSize(width: 480, height: 270)
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("pq_identity_\(UUID().uuidString).mov")
    defer { TestVideoGenerator.cleanup(outputURL) }

    // Identity chain — no stages, source size = output size. The capability preview declares
    // 10-bit support so the session reads 10-bit YUV and passes it through to the writer.
    let capabilities = UpscalingExportSession.ChainCapabilities(
      supportedSourceInputFormats: [
        kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
      ],
      producedOutputFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
    let chainFactory: UpscalingExportSession.ChainFactory = { inputSize in
      try FrameProcessorChain(inputSize: inputSize, outputSize: inputSize, stages: [])
    }

    let session = UpscalingExportSession(
      asset: AVURLAsset(url: url),
      outputCodec: .hevc,
      preferredOutputURL: outputURL,
      outputSize: inputSize,
      chainFactory: chainFactory,
      chainCapabilities: capabilities)

    try await session.export()

    let outAsset = AVURLAsset(url: outputURL)
    let outTrack = try #require(try await outAsset.loadTracks(withMediaType: .video).first)
    let outFormat = try #require(try await outTrack.load(.formatDescriptions).first)

    #expect(outFormat.colorPrimaries == AVVideoColorPrimaries_ITU_R_2020)
    #expect(outFormat.colorTransferFunction == AVVideoTransferFunction_SMPTE_ST_2084_PQ)
    #expect(outFormat.colorYCbCrMatrix == AVVideoYCbCrMatrix_ITU_R_2020)
    #expect(outFormat.isHDR)
    #expect(outFormat.masteringDisplayColorVolume != nil)
    #expect(outFormat.contentLightLevelInfo != nil)
  }

  @Test("Per-PTS attachment cache matches exact and latest-before source PTS")
  func perPTSAttachmentCacheLookup() throws {
    let cache = PerPTSAttachmentCache()
    let timescale: CMTimeScale = 600
    let pts0 = CMTime(value: 0, timescale: timescale)
    let pts1 = CMTime(value: 600, timescale: timescale)
    let pts2 = CMTime(value: 1200, timescale: timescale)
    let dict0 = ["k": "source0"] as CFDictionary
    let dict1 = ["k": "source1"] as CFDictionary
    let dict2 = ["k": "source2"] as CFDictionary
    cache.store(pts: pts0, attachments: dict0)
    cache.store(pts: pts1, attachments: dict1)
    cache.store(pts: pts2, attachments: dict2)

    // Exact match pops the matching entry and evicts older ones.
    let exact = cache.popMatching(pts: pts1)
    let exactValue = (exact as? [String: String])?["k"]
    #expect(exactValue == "source1")
    // pts0 and pts1 should both be evicted; pts2 remains.
    #expect(cache.popMatching(pts: pts0) == nil)
    let remaining = cache.popMatching(pts: pts2)
    let remainingValue = (remaining as? [String: String])?["k"]
    #expect(remainingValue == "source2")
    #expect(cache.popMatching(pts: pts2) == nil)
  }

  @Test("Per-PTS attachment cache falls back to latest-before for interpolated PTSs")
  func perPTSAttachmentCacheInterpolatedLookup() throws {
    let cache = PerPTSAttachmentCache()
    let timescale: CMTimeScale = 600
    let pts0 = CMTime(value: 0, timescale: timescale)
    let pts1 = CMTime(value: 600, timescale: timescale)
    let interpolated = CMTime(value: 300, timescale: timescale)
    let dict0 = ["k": "source0"] as CFDictionary
    let dict1 = ["k": "source1"] as CFDictionary
    cache.store(pts: pts0, attachments: dict0)
    cache.store(pts: pts1, attachments: dict1)

    // Output PTS between two source PTSs picks the latest source ≤ output.
    let matched = cache.popMatching(pts: interpolated)
    let matchedValue = (matched as? [String: String])?["k"]
    #expect(matchedValue == "source0")
    // pts0 is evicted; pts1 remains available for the next source frame.
    let next = cache.popMatching(pts: pts1)
    let nextValue = (next as? [String: String])?["k"]
    #expect(nextValue == "source1")
  }

  @Test("Per-PTS attachment cache returns nil when no source is at or before query")
  func perPTSAttachmentCacheNoMatch() throws {
    let cache = PerPTSAttachmentCache()
    let timescale: CMTimeScale = 600
    let pts1 = CMTime(value: 600, timescale: timescale)
    let earlier = CMTime(value: 100, timescale: timescale)
    cache.store(pts: pts1, attachments: ["k": "source1"] as CFDictionary)
    #expect(cache.popMatching(pts: earlier) == nil)
    // Entry is not evicted when nothing matches.
    #expect(cache.popMatching(pts: pts1) != nil)
  }

  @Test("Cancelling mid-export cleans up the partial output")
  func cancelRemovesPartialOutput() async throws {
    try requireMetal()

    // Deterministic approach: inject a `FrameProcessorBackend` via `chainFactory` that
    // signals when the export has reached the first per-frame processing call and then
    // suspends on `Task.sleep` — a cancellation-aware suspension point. The test awaits
    // the signal (guaranteeing the writer has started and a pixel buffer is in flight),
    // then cancels the export task. Cancellation propagates through the task group into
    // `Task.sleep`, which throws, and `UpscalingExportSession.export()` takes its outer
    // catch path that removes the partial output file.
    //
    // No polling, no sleeps in the test itself, no dependency on real-time export speed —
    // the smallest valid fixture (0.5s / 10fps / 320x240 → 640x480, matching other tests)
    // is sufficient.
    let inputURL = try await TestVideoGenerator.createTestVideo(
      duration: 0.5,
      frameRate: 10,
      size: CGSize(width: 320, height: 240),
      includeAudio: false,
      transform: nil
    )
    defer { TestVideoGenerator.cleanup(inputURL) }

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("fixture_\(UUID().uuidString).mov")
    defer { TestVideoGenerator.cleanup(outputURL) }

    let outputSize = CGSize(width: 640, height: 480)
    let (firstFrameStream, firstFrameContinuation) = AsyncStream<Void>.makeStream()

    let session = UpscalingExportSession(
      asset: AVURLAsset(url: inputURL),
      outputCodec: .h264,
      preferredOutputURL: outputURL,
      outputSize: outputSize,
      chainFactory: { inputSize in
        let backend = BlockingBackend(
          inputSize: inputSize,
          outputSize: outputSize,
          onFirstProcess: { firstFrameContinuation.yield(()) }
        )
        return try FrameProcessorChain(
          inputSize: inputSize, outputSize: outputSize, stages: [backend])
      }
    )

    let task = Task { try await session.export() }

    // Deterministic rendezvous: proceed the instant the backend reports its first frame.
    var iterator = firstFrameStream.makeAsyncIterator()
    _ = await iterator.next()

    task.cancel()

    // The cancellation surfaces as either CancellationError or an AVFoundation error,
    // depending on exactly where the pump was suspended — any error is acceptable. What
    // matters is that (a) the task throws, and (b) the partial output file was removed.
    await #expect(throws: (any Error).self) {
      try await task.value
    }
    #expect(!FileManager.default.fileExists(atPath: outputURL.path))
  }
}

// MARK: - BlockingBackend

/// Test-only `FrameProcessorBackend` that signals on its first `process(...)` call and then
/// suspends on a cancellation-aware sleep until the enclosing task is cancelled. Used by
/// `cancelRemovesPartialOutput` to deterministically pin an export at a known mid-flight
/// point without depending on wall-clock time.
private struct BlockingBackend: FrameProcessorBackend {
  let inputSize: CGSize
  let outputSize: CGSize
  let onFirstProcess: @Sendable () -> Void

  func process(
    _ pixelBuffer: sending CVPixelBuffer,
    presentationTimeStamp: CMTime,
    outputPool: sending CVPixelBufferPool?
  ) async throws -> [FrameProcessorOutput] {
    onFirstProcess()
    // Cancellation-aware suspension. `Task.sleep` throws `CancellationError` when the
    // enclosing task is cancelled, which propagates through `FrameProcessorChain.processAll`
    // and into `UpscalingExportSession.export()`'s cleanup path. Bounded at 60s as a
    // safety net so a regression in cancellation propagation fails CI in a reasonable
    // time rather than hanging for the full test duration.
    try await Task.sleep(for: .seconds(60))
    return []
  }
}

// MARK: - Super Resolution Processing Tests

@Suite(
  "Super Resolution Processing Tests",
  .enabled(
    if: VTSuperResolutionScalerConfiguration.isSupported,
    "VTSuperResolutionScalerConfiguration not supported on this device")
)
struct SuperResolutionProcessingTests {
  @Test("Processes two frames at output size")
  func processesTwoFrames() async throws {
    // Pick the smallest supported factor so the output stays well within macOS limits and
    // the test doesn't allocate huge buffers. Match the pattern used by
    // `superResolutionAcceptsSupportedFactor` so we don't hard-code 2×.
    let supported = VTSuperResolutionScalerConfiguration.supportedScaleFactors.sorted()
    let factor = try #require(supported.first)
    let inputSize = CGSize(width: 320, height: 180)
    let outputSize = CGSize(
      width: inputSize.width * CGFloat(factor),
      height: inputSize.height * CGFloat(factor))

    let processor: VTSuperResolutionUpscaler
    do {
      processor = try await VTSuperResolutionUpscaler(
        inputSize: inputSize, outputSize: outputSize)
    } catch {
      // Model download or configuration may legitimately fail on devices without network /
      // without the ML model cached. Treat as a skip rather than a failure so CI matrices
      // without the model available don't flake.
      throw TestSkipError(
        "VTSuperResolutionUpscaler init failed (likely model unavailable): \(error)")
    }

    #expect(processor.inputSize == inputSize)
    #expect(processor.outputSize == outputSize)
    #expect(processor.requiresInstancePerStream)
    #expect(processor.displayName == "Super resolution")

    // First frame — no previous temporal reference, processor still produces a full output.
    let first = try makeTestPixelBuffer(size: inputSize)
    nonisolated(unsafe) let firstCaptured = first
    let firstPts = CMTime(value: 0, timescale: 30)
    let firstOutputs = try await processor.process(
      firstCaptured, presentationTimeStamp: firstPts, outputPool: nil)
    try #require(firstOutputs.count == 1)
    #expect(CVPixelBufferGetWidth(firstOutputs[0].pixelBuffer) == Int(outputSize.width))
    #expect(CVPixelBufferGetHeight(firstOutputs[0].pixelBuffer) == Int(outputSize.height))
    #expect(firstOutputs[0].presentationTimeStamp == firstPts)

    // Second frame — exercises the temporal-reference path where `previousSourceFrame` is
    // non-nil. Output must match the configured upscale dimensions.
    let second = try makeTestPixelBuffer(size: inputSize)
    nonisolated(unsafe) let secondCaptured = second
    let secondPts = CMTime(value: 1, timescale: 30)
    let secondOutputs = try await processor.process(
      secondCaptured, presentationTimeStamp: secondPts, outputPool: nil)
    try #require(secondOutputs.count == 1)
    #expect(CVPixelBufferGetWidth(secondOutputs[0].pixelBuffer) == Int(outputSize.width))
    #expect(CVPixelBufferGetHeight(secondOutputs[0].pixelBuffer) == Int(outputSize.height))
    #expect(secondOutputs[0].presentationTimeStamp == secondPts)

    // Finish should release temporal references and return no flushed frames (this backend
    // doesn't look ahead).
    let flushed = try await processor.finish(outputPool: nil)
    #expect(flushed.isEmpty)
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
  func defaultDoubles() throws {
    let out = try DimensionCalculation.calculateOutputDimensions(
      inputSize: CGSize(width: 640, height: 480),
      requestedWidth: nil, requestedHeight: nil)
    #expect(out == CGSize(width: 1280, height: 960))
  }

  @Test("Width-only preserves aspect ratio")
  func widthOnly() throws {
    let out = try DimensionCalculation.calculateOutputDimensions(
      inputSize: CGSize(width: 1920, height: 1080),
      requestedWidth: 3840, requestedHeight: nil)
    #expect(out == CGSize(width: 3840, height: 2160))
  }

  @Test("Height-only preserves aspect ratio")
  func heightOnly() throws {
    let out = try DimensionCalculation.calculateOutputDimensions(
      inputSize: CGSize(width: 1920, height: 1080),
      requestedWidth: nil, requestedHeight: 2160)
    #expect(out == CGSize(width: 3840, height: 2160))
  }

  @Test("Both width and height honored")
  func bothProvided() throws {
    let out = try DimensionCalculation.calculateOutputDimensions(
      inputSize: CGSize(width: 1920, height: 1080),
      requestedWidth: 1000, requestedHeight: 800)
    #expect(out == CGSize(width: 1000, height: 800))
  }

  @Test("Odd widths are rounded up to even")
  func oddDimensionsAreEvened() throws {
    let out = try DimensionCalculation.calculateOutputDimensions(
      inputSize: CGSize(width: 1001, height: 563),
      requestedWidth: 2001, requestedHeight: nil)
    #expect(Int(out.width) % 2 == 0)
    #expect(Int(out.height) % 2 == 0)
  }

  @Test("Non-integer aspect ratios produce even dimensions")
  func nonIntegerRatio() throws {
    // 720x405 → request width 1000 → height 562.5 → rounded 563 → evened to 564
    let out = try DimensionCalculation.calculateOutputDimensions(
      inputSize: CGSize(width: 720, height: 405),
      requestedWidth: 1000, requestedHeight: nil)
    #expect(Int(out.width) == 1000)
    #expect(Int(out.height) % 2 == 0)
  }

  @Test("Single-pixel input survives even-rounding")
  func onePixelInput() throws {
    let out = try DimensionCalculation.calculateOutputDimensions(
      inputSize: CGSize(width: 1, height: 1),
      requestedWidth: nil, requestedHeight: nil)
    #expect(out == CGSize(width: 2, height: 2))
  }

  @Test("Non-positive requested width throws")
  func invalidRequestedWidthThrows() {
    #expect(throws: DimensionCalculation.Error.self) {
      _ = try DimensionCalculation.calculateOutputDimensions(
        inputSize: CGSize(width: 1920, height: 1080),
        requestedWidth: 0, requestedHeight: nil)
    }
  }

  @Test("Non-positive input size throws")
  func invalidInputSizeThrows() {
    #expect(throws: DimensionCalculation.Error.self) {
      _ = try DimensionCalculation.calculateOutputDimensions(
        inputSize: CGSize(width: 0, height: 0),
        requestedWidth: nil, requestedHeight: nil)
    }
  }

  @Test("Requested width smaller than input produces a downscaled output")
  func requestedWidthSmallerThanInput() throws {
    // Pin down the current behavior: DimensionCalculation is not special-cased for downscale.
    // It just honors the requested width and derives the height from the input aspect ratio.
    // Even-rounding still applies. This acts as a regression guard against accidentally
    // adding a "reject if smaller than input" branch later — downstream (UpscalingExportSession
    // / MetalFX) is free to require upscaling, but this helper stays scale-agnostic.
    let out = try DimensionCalculation.calculateOutputDimensions(
      inputSize: CGSize(width: 1920, height: 1080),
      requestedWidth: 640, requestedHeight: nil)
    #expect(out == CGSize(width: 640, height: 360))
    #expect(Int(out.width) % 2 == 0)
    #expect(Int(out.height) % 2 == 0)

    // And with both dims explicit, non-matching aspect ratio is honored verbatim (up to even
    // rounding).
    let explicit = try DimensionCalculation.calculateOutputDimensions(
      inputSize: CGSize(width: 1920, height: 1080),
      requestedWidth: 100, requestedHeight: 50)
    #expect(explicit == CGSize(width: 100, height: 50))
  }
}

// MARK: - Pipeline Metrics Tests

@Suite("Pipeline Metrics")
struct PipelineMetricsTests {

  // MARK: StageMetrics computed properties

  @Test("StageMetrics fps and average duration with recorded data")
  func stageMetricsComputedProperties() {
    let stage = StageMetrics(
      name: "Test stage",
      framesProcessed: 100,
      totalDuration: .seconds(2)
    )
    #expect(stage.framesPerSecond == 50.0)
    #expect(stage.averageDuration == .milliseconds(20))
  }

  @Test("StageMetrics returns zero for no frames")
  func stageMetricsZeroFrames() {
    let stage = StageMetrics(
      name: "Empty",
      framesProcessed: 0,
      totalDuration: .zero
    )
    #expect(stage.framesPerSecond == 0)
    #expect(stage.averageDuration == .zero)
  }

  // MARK: PipelineMetrics computed properties

  @Test("PipelineMetrics fps from frames and elapsed time")
  func pipelineMetricsFPS() {
    let metrics = PipelineMetrics(
      stages: [],
      framesProcessed: 300,
      framesEmitted: 300,
      elapsed: .seconds(10)
    )
    #expect(metrics.framesPerSecond == 30.0)
  }

  @Test("PipelineMetrics returns zero fps before any frames")
  func pipelineMetricsZeroBeforeStart() {
    let metrics = PipelineMetrics(
      stages: [],
      framesProcessed: 0,
      framesEmitted: 0,
      elapsed: .zero
    )
    #expect(metrics.framesPerSecond == 0)
  }

  // MARK: PipelineMetricsCollector

  @Test("Collector registers stages and records data correctly")
  func collectorBasicRecording() {
    let collector = PipelineMetricsCollector()
    let idx0 = collector.addStage(name: "Scale")
    let idx1 = collector.addStage(name: "Denoise")

    collector.record(stageIndex: idx0, duration: .milliseconds(10))
    collector.record(stageIndex: idx0, duration: .milliseconds(12))
    collector.record(stageIndex: idx1, duration: .milliseconds(5))
    collector.recordChainCompletion(outputCount: 1)
    collector.recordChainCompletion(outputCount: 1)

    let snapshot = collector.snapshot()
    #expect(snapshot.stages.count == 2)
    #expect(snapshot.stages[0].name == "Scale")
    #expect(snapshot.stages[0].framesProcessed == 2)
    #expect(snapshot.stages[1].name == "Denoise")
    #expect(snapshot.stages[1].framesProcessed == 1)
    #expect(snapshot.framesProcessed == 2)
    #expect(snapshot.framesEmitted == 2)
    #expect(snapshot.elapsed > .zero)
  }

  @Test("Collector snapshot is empty before any recording")
  func collectorEmptySnapshot() {
    let collector = PipelineMetricsCollector()
    _ = collector.addStage(name: "Unused")

    let snapshot = collector.snapshot()
    #expect(snapshot.stages.count == 1)
    #expect(snapshot.stages[0].framesProcessed == 0)
    #expect(snapshot.framesProcessed == 0)
    #expect(snapshot.framesEmitted == 0)
    #expect(snapshot.elapsed == .zero)
  }

  @Test("Collector accumulates durations")
  func collectorDurationAccumulation() {
    let collector = PipelineMetricsCollector()
    let idx = collector.addStage(name: "Scale")

    let d1 = Duration.milliseconds(10)
    let d2 = Duration.milliseconds(20)
    collector.record(stageIndex: idx, duration: d1)
    collector.record(stageIndex: idx, duration: d2)

    let snapshot = collector.snapshot()
    #expect(snapshot.stages[0].totalDuration == d1 + d2)
  }

  @Test("Collector tracks frame emission count for 1:N stages")
  func collectorFrameEmission() {
    let collector = PipelineMetricsCollector()
    _ = collector.addStage(name: "FRC")

    // Simulate: 3 source frames, first emits 0, second emits 3, third emits 2.
    collector.recordChainCompletion(outputCount: 0)
    collector.recordChainCompletion(outputCount: 3)
    collector.recordChainCompletion(outputCount: 2)

    let snapshot = collector.snapshot()
    #expect(snapshot.framesProcessed == 3)
    #expect(snapshot.framesEmitted == 5)
  }

  // MARK: FrameProcessorChain metrics integration

  @Test("Chain populates metrics collector during processing")
  func chainPopulatesMetrics() async throws {
    let inputSize = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)

    guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
      throw TestSkipError("Metal device not available")
    }

    let collector = PipelineMetricsCollector()
    let chain = try FrameProcessorChain(
      inputSize: inputSize, outputSize: outputSize,
      stages: [upscaler],
      metricsCollector: collector
    )

    let inputBuffer = try makeTestPixelBuffer(size: inputSize)
    _ = try await chain.process(inputBuffer, presentationTimeStamp: .zero, outputPool: nil)

    let snapshot = collector.snapshot()
    #expect(snapshot.stages.count == 1)
    #expect(snapshot.stages[0].name == "MetalFX spatial")
    #expect(snapshot.stages[0].framesProcessed == 1)
    #expect(snapshot.stages[0].totalDuration > .zero)
    #expect(snapshot.framesProcessed == 1)
    #expect(snapshot.framesEmitted == 1)
  }

  @Test("Chain without collector works normally")
  func chainWithoutCollector() async throws {
    let inputSize = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)

    guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
      throw TestSkipError("Metal device not available")
    }

    let chain = try FrameProcessorChain(
      inputSize: inputSize, outputSize: outputSize,
      stages: [upscaler]
    )

    let inputBuffer = try makeTestPixelBuffer(size: inputSize)
    let outputs = try await chain.process(inputBuffer, presentationTimeStamp: .zero, outputPool: nil)
    #expect(outputs.count == 1)
  }

  @Test("Identity chain records no stage metrics")
  func identityChainMetrics() async throws {
    let size = CGSize(width: 320, height: 240)
    let collector = PipelineMetricsCollector()
    let chain = try FrameProcessorChain(
      inputSize: size, outputSize: size, stages: [],
      metricsCollector: collector
    )

    let inputBuffer = try makeTestPixelBuffer(size: size)
    _ = try await chain.process(inputBuffer, presentationTimeStamp: .zero, outputPool: nil)

    let snapshot = collector.snapshot()
    #expect(snapshot.stages.isEmpty)
    #expect(snapshot.framesProcessed == 1)
  }

  // MARK: displayName

  @Test("Upscaler has expected display name")
  func upscalerDisplayName() throws {
    let u = Upscaler(
      inputSize: CGSize(width: 320, height: 240),
      outputSize: CGSize(width: 640, height: 480)
    )
    guard let upscaler = u else {
      throw TestSkipError("Metal device not available")
    }
    #expect(upscaler.displayName == "MetalFX spatial")
  }

  // MARK: Duration.timeInterval

  @Test("Duration.timeInterval converts correctly")
  func durationTimeInterval() {
    let d = Duration.seconds(3) + .milliseconds(500)
    let interval = d.timeInterval
    // 3.5 seconds — allow tiny floating-point tolerance.
    #expect(abs(interval - 3.5) < 1e-9)
  }
}

// MARK: - Pipeline Channel Tests

@Suite("Pipeline Channel Tests")
struct PipelineChannelTests {
  @Test("Single element flows through channel")
  func singleElement() async {
    let channel = PipelineChannel<Int>(capacity: 1)
    await channel.send(42)
    channel.finish()
    var iterator = channel.makeAsyncIterator()
    let value = await iterator.next()
    #expect(value == 42)
    let end = await iterator.next()
    #expect(end == nil)
  }

  @Test("Multiple elements flow in order")
  func multipleElements() async {
    let channel = PipelineChannel<Int>(capacity: 2)
    await channel.send(1)
    await channel.send(2)
    channel.finish()
    var results: [Int] = []
    for await value in channel {
      results.append(value)
    }
    #expect(results == [1, 2])
  }

  @Test("Backpressure suspends producer when full")
  func backpressure() async {
    let channel = PipelineChannel<Int>(capacity: 1)
    // Fill the buffer.
    await channel.send(1)
    // Consume concurrently to unblock the producer.
    async let producer: Void = channel.send(2)
    var iter = channel.makeAsyncIterator()
    let first = await iter.next()
    await producer
    channel.finish()
    #expect(first == 1)
  }

  @Test("Finish signals end to waiting consumer")
  func finishWakesConsumer() async {
    let channel = PipelineChannel<Int>(capacity: 1)
    let task = Task {
      var iter = channel.makeAsyncIterator()
      return await iter.next()
    }
    // Brief yield to let the consumer park.
    try? await Task.sleep(for: .milliseconds(10))
    channel.finish()
    let value = await task.value
    #expect(value == nil)
  }

  @Test("Cancelled consumer returns nil")
  func cancelledConsumer() async {
    let channel = PipelineChannel<Int>(capacity: 1)
    let task = Task {
      var iter = channel.makeAsyncIterator()
      return await iter.next()
    }
    // Let the consumer park, then cancel.
    try? await Task.sleep(for: .milliseconds(10))
    task.cancel()
    let value = await task.value
    #expect(value == nil)
  }

  @Test("Cancelled producer drops element")
  func cancelledProducer() async {
    let channel = PipelineChannel<Int>(capacity: 1)
    await channel.send(1) // fill buffer
    let task = Task {
      await channel.send(2) // should suspend (buffer full)
    }
    try? await Task.sleep(for: .milliseconds(10))
    task.cancel()
    await task.value
    // Consumer should get 1 from the buffer, then nil after finish.
    channel.finish()
    var iter = channel.makeAsyncIterator()
    #expect(await iter.next() == 1)
    #expect(await iter.next() == nil)
  }

  @Test("Producer-consumer pipeline transfers all elements")
  func producerConsumerPipeline() async {
    let channel = PipelineChannel<Int>(capacity: 2)
    let count = 100
    async let producer: Void = {
      for i in 0..<count {
        await channel.send(i)
      }
      channel.finish()
    }()
    var received: [Int] = []
    for await value in channel {
      received.append(value)
    }
    await producer
    #expect(received == Array(0..<count))
  }
}

// MARK: - Pipeline processAll Tests

@Suite("Pipeline processAll Tests")
struct PipelineProcessAllTests {
  @Test("processAll produces same output as sequential process for single stage")
  func singleStageEquivalence() async throws {
    let size = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)
    guard let backend = Upscaler(inputSize: size, outputSize: outputSize) else {
      throw TestSkipError("Metal device not available")
    }
    let chain = try FrameProcessorChain(
      inputSize: size, outputSize: outputSize, stages: [backend])

    let frameCount = 5
    let inputBuffers = try (0..<frameCount).map { _ in try makeTestPixelBuffer(size: size) }

    // Feed frames through processAll
    let inputChannel = PipelineChannel<FrameProcessorOutput>(capacity: 2)
    let outputCollector = OSAllocatedUnfairLock(initialState: [[FrameProcessorOutput]]())

    async let feeder: Void = {
      for (i, buffer) in inputBuffers.enumerated() {
        nonisolated(unsafe) let captured = buffer
        await inputChannel.send(
          FrameProcessorOutput(
            pixelBuffer: captured,
            presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 30)))
      }
      inputChannel.finish()
    }()

    try await chain.processAll(from: inputChannel, outputPool: nil) { batch in
      outputCollector.withLock { $0.append(batch) }
    }
    await feeder

    let outputs = outputCollector.withLock { $0 }
    #expect(outputs.count == frameCount)
    for batch in outputs {
      #expect(batch.count == 1) // 1:1 stage
      let buf = batch[0].pixelBuffer
      #expect(CVPixelBufferGetWidth(buf) == Int(outputSize.width))
      #expect(CVPixelBufferGetHeight(buf) == Int(outputSize.height))
    }
  }

  @Test("processAll identity chain passes through frames")
  func identityChain() async throws {
    let size = CGSize(width: 320, height: 240)
    let chain = try FrameProcessorChain(
      inputSize: size, outputSize: size, stages: [])

    let buffer = try makeTestPixelBuffer(size: size)
    let inputChannel = PipelineChannel<FrameProcessorOutput>(capacity: 1)
    nonisolated(unsafe) let captured = buffer
    await inputChannel.send(
      FrameProcessorOutput(
        pixelBuffer: captured, presentationTimeStamp: CMTime(value: 1, timescale: 30)))
    inputChannel.finish()

    let countBox = OSAllocatedUnfairLock(initialState: 0)
    try await chain.processAll(from: inputChannel, outputPool: nil) { batch in
      countBox.withLock { $0 += batch.count }
    }
    #expect(countBox.withLock { $0 } == 1)
  }

  @Test("processAll records metrics")
  func metricsRecording() async throws {
    let size = CGSize(width: 320, height: 240)
    let outputSize = CGSize(width: 640, height: 480)
    guard let backend = Upscaler(inputSize: size, outputSize: outputSize) else {
      throw TestSkipError("Metal device not available")
    }
    let collector = PipelineMetricsCollector()
    let chain = try FrameProcessorChain(
      inputSize: size, outputSize: outputSize, stages: [backend],
      metricsCollector: collector)

    let inputChannel = PipelineChannel<FrameProcessorOutput>(capacity: 1)
    let buf = try makeTestPixelBuffer(size: size)
    nonisolated(unsafe) let captured = buf
    await inputChannel.send(
      FrameProcessorOutput(
        pixelBuffer: captured, presentationTimeStamp: .zero))
    inputChannel.finish()

    try await chain.processAll(from: inputChannel, outputPool: nil) { _ in }

    let snapshot = collector.snapshot()
    #expect(snapshot.stages.count == 1)
    #expect(snapshot.stages[0].framesProcessed == 1)
    #expect(snapshot.framesProcessed == 1)
    #expect(snapshot.framesEmitted == 1)
  }
}

// MARK: - Final Output Dimensions

@Suite("Final Output Dimensions")
struct FinalOutputDimensionsTests {
  @Test("Both nil returns scalerOutputSize verbatim")
  func bothNilReturnsScaler() throws {
    let scaler = CGSize(width: 3840, height: 2160)
    let out = try DimensionCalculation.calculateFinalOutputDimensions(
      scalerOutputSize: scaler, requestedWidth: nil, requestedHeight: nil)
    #expect(out == scaler)
  }

  @Test("Width-only derives height from scalerOutputSize's aspect")
  func widthOnlyDerivesHeight() throws {
    let scaler = CGSize(width: 3840, height: 2160)
    let out = try DimensionCalculation.calculateFinalOutputDimensions(
      scalerOutputSize: scaler, requestedWidth: 1920, requestedHeight: nil)
    #expect(out == CGSize(width: 1920, height: 1080))
  }

  @Test("Height-only derives width from scalerOutputSize's aspect")
  func heightOnlyDerivesWidth() throws {
    let scaler = CGSize(width: 3840, height: 2160)
    let out = try DimensionCalculation.calculateFinalOutputDimensions(
      scalerOutputSize: scaler, requestedWidth: nil, requestedHeight: 1080)
    #expect(out == CGSize(width: 1920, height: 1080))
  }

  @Test("Both given are honored verbatim after even-rounding")
  func bothGivenHonored() throws {
    let scaler = CGSize(width: 3840, height: 2160)
    let out = try DimensionCalculation.calculateFinalOutputDimensions(
      scalerOutputSize: scaler, requestedWidth: 1280, requestedHeight: 720)
    #expect(out == CGSize(width: 1280, height: 720))
  }

  @Test("Non-positive requested width throws")
  func nonPositiveWidthThrows() {
    #expect(throws: DimensionCalculation.Error.self) {
      _ = try DimensionCalculation.calculateFinalOutputDimensions(
        scalerOutputSize: CGSize(width: 3840, height: 2160),
        requestedWidth: 0, requestedHeight: nil)
    }
  }

  @Test("Non-positive requested height throws")
  func nonPositiveHeightThrows() {
    #expect(throws: DimensionCalculation.Error.self) {
      _ = try DimensionCalculation.calculateFinalOutputDimensions(
        scalerOutputSize: CGSize(width: 3840, height: 2160),
        requestedWidth: nil, requestedHeight: -1)
    }
  }

  @Test("Non-positive scalerOutputSize throws")
  func invalidScalerSizeThrows() {
    #expect(throws: DimensionCalculation.Error.self) {
      _ = try DimensionCalculation.calculateFinalOutputDimensions(
        scalerOutputSize: CGSize(width: 0, height: 0),
        requestedWidth: nil, requestedHeight: nil)
    }
  }

  @Test("Odd scalerOutputSize with both-nil returns even dimensions")
  func oddScalerBothNil() throws {
    let scaler = CGSize(width: 3841, height: 2161)
    let out = try DimensionCalculation.calculateFinalOutputDimensions(
      scalerOutputSize: scaler, requestedWidth: nil, requestedHeight: nil)
    #expect(out.width <= scaler.width)
    #expect(out.height <= scaler.height)
  }

  @Test("Clamps result to scalerOutputSize on the width axis")
  func clampsWidth() throws {
    let scaler = CGSize(width: 1920, height: 1080)
    let out = try DimensionCalculation.calculateFinalOutputDimensions(
      scalerOutputSize: scaler, requestedWidth: 1920, requestedHeight: nil)
    #expect(out.width == 1920)
    #expect(out.width <= scaler.width)
    #expect(out.height <= scaler.height)
  }

  @Test("Final dims smaller than scaler produce even, correct output")
  func downsample() throws {
    let out = try DimensionCalculation.calculateFinalOutputDimensions(
      scalerOutputSize: CGSize(width: 3840, height: 2160),
      requestedWidth: 1920, requestedHeight: 1080)
    #expect(out == CGSize(width: 1920, height: 1080))
  }
}

// MARK: - CILanczosDownsampler Tests

private func makeSolidGrayBuffer(size: CGSize, gray: UInt8 = 128) throws -> CVPixelBuffer {
  let buffer = try makeTestPixelBuffer(size: size)
  CVPixelBufferLockBaseAddress(buffer, [])
  defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
  guard let base = CVPixelBufferGetBaseAddress(buffer) else {
    throw TestSkipError("Failed to lock pixel buffer base address")
  }
  let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
  let height = CVPixelBufferGetHeight(buffer)
  let width = CVPixelBufferGetWidth(buffer)
  let ptr = base.assumingMemoryBound(to: UInt8.self)
  for y in 0..<height {
    for x in 0..<width {
      let offset = y * bytesPerRow + x * 4
      ptr[offset + 0] = gray  // B
      ptr[offset + 1] = gray  // G
      ptr[offset + 2] = gray  // R
      ptr[offset + 3] = 255  // A
    }
  }
  return buffer
}

@Suite("CI Lanczos Downsampler")
struct CILanczosDownsamplerTests {
  @Test("Init succeeds for valid downsample sizes")
  func initSucceeds() throws {
    _ = try CILanczosDownsampler(
      inputSize: CGSize(width: 1920, height: 1080),
      outputSize: CGSize(width: 1280, height: 720))
  }

  @Test("Init rejects outputSize larger than inputSize")
  func initRejectsUpscale() {
    #expect(throws: CILanczosDownsampler.Error.self) {
      _ = try CILanczosDownsampler(
        inputSize: CGSize(width: 1280, height: 720),
        outputSize: CGSize(width: 1920, height: 1080))
    }
  }

  @Test("Init rejects odd dimensions")
  func initRejectsOddDimensions() {
    #expect(throws: CILanczosDownsampler.Error.self) {
      _ = try CILanczosDownsampler(
        inputSize: CGSize(width: 1281, height: 720),
        outputSize: CGSize(width: 640, height: 360))
    }
  }

  @Test("Init rejects non-positive sizes")
  func initRejectsInvalidSizes() {
    #expect(throws: CILanczosDownsampler.Error.self) {
      _ = try CILanczosDownsampler(
        inputSize: CGSize(width: 0, height: 0),
        outputSize: CGSize(width: 0, height: 0))
    }
  }

  @Test("Preflight mirrors init-time validation")
  func preflight() throws {
    try CILanczosDownsampler.preflight(
      inputSize: CGSize(width: 1920, height: 1080),
      outputSize: CGSize(width: 640, height: 480))
    #expect(throws: CILanczosDownsampler.Error.self) {
      try CILanczosDownsampler.preflight(
        inputSize: CGSize(width: 640, height: 480),
        outputSize: CGSize(width: 1920, height: 1080))
    }
    #expect(throws: CILanczosDownsampler.Error.self) {
      try CILanczosDownsampler.preflight(
        inputSize: CGSize(width: 1921, height: 1080),
        outputSize: CGSize(width: 640, height: 480))
    }
  }

  @Test("Process returns one output at outputSize with source PTS")
  func processReturnsOutputAtOutputSize() async throws {
    let inputSize = CGSize(width: 640, height: 480)
    let outputSize = CGSize(width: 320, height: 240)
    let downsampler = try CILanczosDownsampler(
      inputSize: inputSize, outputSize: outputSize)
    let buffer = try makeTestPixelBuffer(size: inputSize)
    nonisolated(unsafe) let captured = buffer
    let pts = CMTime(value: 42, timescale: 30)

    let outputs = try await downsampler.process(
      captured, presentationTimeStamp: pts, outputPool: nil)

    try #require(outputs.count == 1)
    #expect(CVPixelBufferGetWidth(outputs[0].pixelBuffer) == Int(outputSize.width))
    #expect(CVPixelBufferGetHeight(outputs[0].pixelBuffer) == Int(outputSize.height))
    #expect(outputs[0].presentationTimeStamp == pts)
  }

  @Test("Process rejects input with wrong size")
  func processRejectsWrongSize() async throws {
    let downsampler = try CILanczosDownsampler(
      inputSize: CGSize(width: 640, height: 480),
      outputSize: CGSize(width: 320, height: 240))
    let wrong = try makeTestPixelBuffer(size: CGSize(width: 320, height: 240))
    nonisolated(unsafe) let captured = wrong
    await #expect(throws: (any Error).self) {
      _ = try await downsampler.process(
        captured, presentationTimeStamp: .zero, outputPool: nil)
    }
  }

  @Test("Gamma round-trip: uniform 50% gray stays ±1 LSB")
  func gammaRoundTrip() async throws {
    // Pins the sRGB color-space contract: a uniform perceptual gray must stay uniform after
    // downsampling. If the filter were to convert to linear-light and back with a wrong
    // inverse, a 128-gray input would shift.
    let inputSize = CGSize(width: 256, height: 256)
    let outputSize = CGSize(width: 128, height: 128)
    let downsampler = try CILanczosDownsampler(
      inputSize: inputSize, outputSize: outputSize)
    let buffer = try makeSolidGrayBuffer(size: inputSize, gray: 128)
    nonisolated(unsafe) let captured = buffer

    let outputs = try await downsampler.process(
      captured, presentationTimeStamp: .zero, outputPool: nil)
    try #require(outputs.count == 1)

    let outBuffer = outputs[0].pixelBuffer
    CVPixelBufferLockBaseAddress(outBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(outBuffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(outBuffer)!
    let bytesPerRow = CVPixelBufferGetBytesPerRow(outBuffer)
    let w = CVPixelBufferGetWidth(outBuffer)
    let h = CVPixelBufferGetHeight(outBuffer)
    let ptr = base.assumingMemoryBound(to: UInt8.self)

    // Sample the center — edges can pick up kernel-extension artifacts on bounded input.
    let cx = w / 2
    let cy = h / 2
    let offset = cy * bytesPerRow + cx * 4
    let b = ptr[offset + 0]
    let g = ptr[offset + 1]
    let r = ptr[offset + 2]
    #expect(abs(Int(b) - 128) <= 1, "blue channel drifted: \(b)")
    #expect(abs(Int(g) - 128) <= 1, "green channel drifted: \(g)")
    #expect(abs(Int(r) - 128) <= 1, "red channel drifted: \(r)")
  }
}

// MARK: - Chain Integration with Lanczos

@Suite("Chain with Lanczos")
struct ChainWithLanczosTests {
  @Test("Scaler + Lanczos produces final size from source")
  func scalerThenLanczos() async throws {
    let sourceSize = CGSize(width: 320, height: 240)
    let scalerOutputSize = CGSize(width: 640, height: 480)
    let finalSize = CGSize(width: 480, height: 360)

    guard
      let upscaler = Upscaler(inputSize: sourceSize, outputSize: scalerOutputSize)
    else {
      throw TestSkipError("Metal device not available")
    }
    let downsampler = try CILanczosDownsampler(
      inputSize: scalerOutputSize, outputSize: finalSize)

    let chain = try FrameProcessorChain(
      inputSize: sourceSize, outputSize: finalSize,
      stages: [upscaler, downsampler])

    let input = try makeTestPixelBuffer(size: sourceSize)
    nonisolated(unsafe) let captured = input
    let pts = CMTime(value: 1, timescale: 30)
    let outputs = try await chain.process(
      captured, presentationTimeStamp: pts, outputPool: nil)

    try #require(outputs.count == 1)
    #expect(CVPixelBufferGetWidth(outputs[0].pixelBuffer) == Int(finalSize.width))
    #expect(CVPixelBufferGetHeight(outputs[0].pixelBuffer) == Int(finalSize.height))
    #expect(outputs[0].presentationTimeStamp == pts)
  }

  @Test("Lanczos inputSize must match upstream outputSize or chain init fails")
  func chainRejectsSizeMismatch() async throws {
    guard
      let upscaler = Upscaler(
        inputSize: CGSize(width: 320, height: 240),
        outputSize: CGSize(width: 640, height: 480))
    else {
      throw TestSkipError("Metal device not available")
    }
    let downsampler = try CILanczosDownsampler(
      inputSize: CGSize(width: 800, height: 600),
      outputSize: CGSize(width: 400, height: 300))

    #expect(throws: FrameProcessorChain.Error.self) {
      _ = try FrameProcessorChain(
        inputSize: CGSize(width: 320, height: 240),
        outputSize: CGSize(width: 400, height: 300),
        stages: [upscaler, downsampler])
    }
  }

  @Test("--scale alone produces a chain with no Lanczos stage (regression guard)")
  func scaleAloneNoLanczos() async throws {
    let sourceSize = CGSize(width: 320, height: 240)
    let scalerOutputSize = CGSize(width: 640, height: 480)
    let finalSize = scalerOutputSize

    guard
      let upscaler = Upscaler(inputSize: sourceSize, outputSize: scalerOutputSize)
    else {
      throw TestSkipError("Metal device not available")
    }
    let chain = try FrameProcessorChain(
      inputSize: sourceSize, outputSize: finalSize, stages: [upscaler])
    #expect(chain.inputSize == sourceSize)
    #expect(chain.outputSize == finalSize)
  }
}
