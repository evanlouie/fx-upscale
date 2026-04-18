import AVFoundation
import Foundation
import VideoToolbox
import os

// MARK: - UpscalingExportSession

public final class UpscalingExportSession: @unchecked Sendable {
  // MARK: Lifecycle

  /// Creates a new upscaling export session.
  ///
  /// - Parameters:
  ///   - asset: Source asset to upscale.
  ///   - outputCodec: Output codec. If `nil`, the source's codec is preserved.
  ///   - preferredOutputURL: Output URL. If a file already exists here, `export()` throws.
  ///   - outputSize: Target dimensions. Must be ≤ `maxOutputSize` on each axis.
  ///   - quality: Optional encoder quality in the range 0...1.
  ///   - keyFrameInterval: Maximum interval between keyframes, in seconds. If `nil`, the
  ///     encoder chooses (VideoToolbox HEVC can emit very sparse IDRs in that case, which
  ///     breaks keyframe-snap seeking in players like IINA).
  ///   - creator: Optional creator string applied as a Spotlight xattr on macOS.
  ///   - upscaler: Upscaling algorithm selector. Defaults to `.spatial` (MetalFX). Choose
  ///     `.superResolution` to route video tracks through `VTFrameProcessor`; that backend
  ///     has stricter input constraints and may trigger a one-time ML model download.
  public init(
    asset: AVAsset,
    outputCodec: AVVideoCodecType? = nil,
    preferredOutputURL: URL,
    outputSize: CGSize,
    quality: Double? = nil,
    keyFrameInterval: TimeInterval? = nil,
    creator: String? = nil,
    upscaler: UpscalerKind = .spatial
  ) {
    self.asset = asset
    self.outputCodec = outputCodec
    self.quality = quality
    self.keyFrameInterval = keyFrameInterval
    outputURL = preferredOutputURL
    self.outputSize = outputSize
    self.creator = creator
    self.upscalerKind = upscaler
    progress = Progress(parent: nil, userInfo: [.fileURLKey: outputURL])
    progress.isCancellable = true
    #if os(macOS)
      progress.publish()
    #endif
  }

  // MARK: Public

  /// Maximum supported output width/height per axis (Metal/MetalFX upper bound).
  public static let maxOutputSize = 16384

  public let asset: AVAsset
  public let outputCodec: AVVideoCodecType?
  public let outputURL: URL
  public let outputSize: CGSize
  public let quality: Double?
  public let keyFrameInterval: TimeInterval?
  public let creator: String?
  public let upscalerKind: UpscalerKind

  public let progress: Progress

  public func export() async throws {
    #if os(macOS)
      defer { progress.unpublish() }
    #endif
    defer { progress.cancellationHandler = nil }

    guard !FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) else {
      throw Error.outputURLAlreadyExists
    }

    let outputFileType: AVFileType =
      switch outputURL.pathExtension.lowercased() {
      case "mov": .mov
      case "m4v": .m4v
      default: .mp4
      }

    let assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: outputFileType)
    assetWriter.metadata = try await asset.load(.metadata)

    let assetReader = try AVAssetReader(asset: asset)

    let duration = try await asset.load(.duration)
    let durationUnits: Int64 =
      duration.isNumeric
      ? max(1, Int64(duration.seconds * Double(Self.progressUnitsPerSecond))) : 1

    nonisolated(unsafe) let cancelReader = assetReader
    nonisolated(unsafe) let cancelWriter = assetWriter
    progress.cancellationHandler = {
      cancelReader.cancelReading()
      cancelWriter.cancelWriting()
    }

    var mediaTracks: [MediaTrack] = []
    var minStartTime: CMTime = .positiveInfinity
    let tracks = try await asset.load(.tracks)

    for track in tracks {
      let mediaType = track.mediaType
      let formatDescription = try await track.load(.formatDescriptions).first
      let timeRange = try await track.load(.timeRange)
      if timeRange.start.isNumeric, timeRange.start < minStartTime {
        minStartTime = timeRange.start
      }

      if mediaType == .video, formatDescription?.isUnsupportedForSRGBPath == true {
        // Reject HDR / wide-gamut inputs: the 8-bit BGRA sRGB-perceptual MetalFX path would
        // silently clip or shift these values while propagating the source's color metadata.
        throw Error.unsupportedColorSpace
      }

      switch mediaType {
      case .video:
        guard
          let assetReaderOutput = Self.videoAssetReaderOutput(
            for: track, formatDescription: formatDescription),
          let assetWriterInput = try await Self.videoAssetWriterInput(
            for: track, formatDescription: formatDescription,
            outputSize: outputSize, outputCodec: outputCodec, quality: quality,
            keyFrameInterval: keyFrameInterval)
        else { continue }

        guard assetReader.canAdd(assetReaderOutput) else {
          throw Error.couldNotAddAssetReaderOutput(mediaType)
        }
        assetReader.add(assetReaderOutput)
        guard assetWriter.canAdd(assetWriterInput) else {
          throw Error.couldNotAddAssetWriterInput(mediaType)
        }
        assetWriter.add(assetWriterInput)

        progress.totalUnitCount += Self.videoTrackProgressWeight
        if formatDescription?.hasLeftAndRightEye ?? false {
          let receiver = assetWriter.inputTaggedPixelBufferGroupReceiver(
            for: assetWriterInput, pixelBufferAttributes: nil)
          try await mediaTracks.append(
            .spatialVideo(
              output: assetReaderOutput, input: assetWriterInput,
              inputSize: track.load(.naturalSize), receiver: receiver))
        } else {
          let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: assetWriterInput,
            sourcePixelBufferAttributes: PixelBufferAttributes.bgra(size: outputSize)
          )
          try await mediaTracks.append(
            .video(
              output: assetReaderOutput, input: assetWriterInput,
              inputSize: track.load(.naturalSize), adaptor: adaptor))
        }

      case .audio:
        let assetReaderOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        let assetWriterInput = AVAssetWriterInput(
          mediaType: .audio, outputSettings: nil, sourceFormatHint: formatDescription)
        assetWriterInput.expectsMediaDataInRealTime = false
        guard assetReader.canAdd(assetReaderOutput) else {
          throw Error.couldNotAddAssetReaderOutput(mediaType)
        }
        assetReader.add(assetReaderOutput)
        guard assetWriter.canAdd(assetWriterInput) else {
          throw Error.couldNotAddAssetWriterInput(mediaType)
        }
        assetWriter.add(assetWriterInput)
        progress.totalUnitCount += 1
        mediaTracks.append(.passthrough(output: assetReaderOutput, input: assetWriterInput))

      default:
        // Preserve timecode, subtitle, closed caption, metadata tracks via passthrough.
        let assetReaderOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        let assetWriterInput = AVAssetWriterInput(
          mediaType: mediaType, outputSettings: nil, sourceFormatHint: formatDescription)
        assetWriterInput.expectsMediaDataInRealTime = false
        guard assetReader.canAdd(assetReaderOutput), assetWriter.canAdd(assetWriterInput) else {
          // Non-critical track — skip if not addable.
          continue
        }
        assetReader.add(assetReaderOutput)
        assetWriter.add(assetWriterInput)
        mediaTracks.append(.passthrough(output: assetReaderOutput, input: assetWriterInput))
      }
    }

    guard !mediaTracks.isEmpty else {
      throw Error.noMediaTracks
    }

    guard assetWriter.startWriting() else {
      throw assetWriter.error ?? Error.failedToStartWriting
    }
    guard assetReader.startReading() else {
      assetWriter.cancelWriting()
      throw assetReader.error ?? Error.failedToStartReading
    }
    // Start at the earliest track-range start so assets with a leading offset (edited clips,
    // compositions) don't produce a leading gap or fail the first append.
    let startTime: CMTime = minStartTime.isNumeric ? minStartTime : .zero
    assetWriter.startSession(atSourceTime: startTime)

    do {
      try await withThrowingTaskGroup(of: Void.self) { [weak self] group in
        for mediaTrack in mediaTracks {
          group.addTask { [weak self] in
            guard let self else { return }
            try Task.checkCancellation()
            switch mediaTrack {
            case .passthrough(let output, let input):
              // Only audio tracks contribute to the parent progress. Subtitle / timecode /
              // closed-caption / metadata tracks are tiny and don't need reporting.
              let childProgress: Progress? =
                if input.mediaType == .audio {
                  Progress(totalUnitCount: durationUnits)
                } else {
                  nil
                }
              if let childProgress {
                self.progress.addChild(childProgress, withPendingUnitCount: 1)
              }
              try await Self.processPassthroughSamples(
                from: output, to: input, progress: childProgress)
            case .video(let output, let input, let inputSize, let adaptor):
              let childProgress = Progress(totalUnitCount: durationUnits)
              self.progress.addChild(
                childProgress, withPendingUnitCount: Self.videoTrackProgressWeight)
              try await Self.processVideoSamples(
                from: output, to: input, adaptor: adaptor,
                inputSize: inputSize, outputSize: self.outputSize,
                upscalerKind: self.upscalerKind,
                progress: childProgress)
            case .spatialVideo(let output, let input, let inputSize, let receiver):
              let childProgress = Progress(totalUnitCount: durationUnits)
              self.progress.addChild(
                childProgress, withPendingUnitCount: Self.videoTrackProgressWeight)
              try await Self.processSpatialVideoSamples(
                from: output, to: input, receiver: receiver,
                inputSize: inputSize, outputSize: self.outputSize,
                upscalerKind: self.upscalerKind,
                progress: childProgress)
            }
          }
        }
        do {
          try await group.waitForAll()
        } catch {
          group.cancelAll()
          assetReader.cancelReading()
          assetWriter.cancelWriting()
          throw error
        }
      }
    } catch {
      assetReader.cancelReading()
      assetWriter.cancelWriting()
      try? FileManager.default.removeItem(at: outputURL)
      throw error
    }

    if let error = assetReader.error {
      assetWriter.cancelWriting()
      try? FileManager.default.removeItem(at: outputURL)
      throw error
    }

    switch assetWriter.status {
    case .writing:
      await assetWriter.finishWriting()
      if let error = assetWriter.error {
        try? FileManager.default.removeItem(at: outputURL)
        throw error
      }
    case .completed:
      break
    case .cancelled:
      try? FileManager.default.removeItem(at: outputURL)
      throw CancellationError()
    case .failed:
      try? FileManager.default.removeItem(at: outputURL)
      throw assetWriter.error ?? Error.failedToStartWriting
    case .unknown:
      fallthrough
    @unknown default:
      try? FileManager.default.removeItem(at: outputURL)
      throw Error.failedToStartWriting
    }

    #if os(macOS)
      if let creator {
        let value = try PropertyListSerialization.data(
          fromPropertyList: creator,
          format: .binary,
          options: 0
        )
        _ = outputURL.withUnsafeFileSystemRepresentation { fileSystemPath -> Int32 in
          value.withUnsafeBytes { bytes in
            setxattr(
              fileSystemPath,
              Self.creatorXattrName,
              bytes.baseAddress,
              value.count,
              0,
              0
            )
          }
        }
        // Ignore failure: creator metadata is a non-essential convenience xattr.
      }
    #endif
  }

  // MARK: Private

  /// Progress ticks per second of source duration (millisecond resolution).
  private static let progressUnitsPerSecond: Int64 = 1000

  /// Minimum delta (in progress ticks, i.e. milliseconds) between `completedUnitCount` writes.
  /// Throttles the KVO / `Progress.publish()` notification storm on long videos.
  private static let progressUpdateThresholdUnits: Int64 = 100

  /// Pending-unit-count weight assigned to each video/spatial-video track inside the parent
  /// `Progress`. Audio passthrough is weighted 1; video tracks dominate the export time, so
  /// they're weighted 10.
  private static let videoTrackProgressWeight: Int64 = 10

  /// Spotlight creator metadata xattr key (macOS).
  private static let creatorXattrName = "com.apple.metadata:kMDItemCreator"

  /// Polling interval used by `waitForInputReady` while the writer input is saturated.
  /// `isReadyForMoreMediaData` typically flips within microseconds, so 500µs minimizes wasted
  /// throughput when the writer is briefly saturated without burning CPU.
  private static let writerReadyPollInterval: Duration = .microseconds(500)

  /// Maximum number of decoded sample buffers in flight between the reader pump and the writer
  /// consumer. Bounded so slow-writer stalls can't accumulate unbounded decoded `CVPixelBuffer`s
  /// (a single 4K frame is ~24 MiB). Small enough to cap memory, large enough to smooth jitter.
  private static let sampleBufferBufferDepth: Int = 4

  private enum MediaTrack: @unchecked Sendable {
    // Exclusive-ownership invariant: each `MediaTrack` is handed to exactly one child
    // `addTask` and never touched from any other isolation domain. That's what makes
    // @unchecked Sendable safe here despite AVFoundation's reference types being non-Sendable.
    case passthrough(
      output: AVAssetReaderOutput,
      input: AVAssetWriterInput
    )
    case video(
      output: AVAssetReaderOutput,
      input: AVAssetWriterInput,
      inputSize: CGSize,
      adaptor: AVAssetWriterInputPixelBufferAdaptor
    )
    case spatialVideo(
      output: AVAssetReaderOutput,
      input: AVAssetWriterInput,
      inputSize: CGSize,
      receiver: AVAssetWriterInput.TaggedPixelBufferGroupReceiver
    )
  }

  /// Update `progress.completedUnitCount` only if the presentation time has advanced by at least
  /// `progressUpdateThresholdUnits` milliseconds since the last write, or the end has been
  /// reached. Clamps to `totalUnitCount` so that composition edits or muxer rounding can't push
  /// the reported percentage above 100.
  private static func updateProgress(_ progress: Progress, pts: CMTime) {
    guard pts.isNumeric else { return }
    let raw = Int64(pts.seconds * Double(progressUnitsPerSecond))
    let newUnits = min(raw, progress.totalUnitCount)
    let last = progress.completedUnitCount
    if newUnits - last >= progressUpdateThresholdUnits
      || newUnits >= progress.totalUnitCount
    {
      progress.completedUnitCount = newUnits
    }
  }

  private static func videoAssetReaderOutput(
    for track: AVAssetTrack,
    formatDescription: CMFormatDescription?
  ) -> AVAssetReaderOutput? {
    var outputSettings: [String: Any] = PixelBufferAttributes.bgra
    if formatDescription?.hasLeftAndRightEye ?? false {
      outputSettings[AVVideoDecompressionPropertiesKey] = [
        kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs: [0, 1]
      ]
    }
    let assetReaderOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
    assetReaderOutput.alwaysCopiesSampleData = false
    return assetReaderOutput
  }

  private static func videoAssetWriterInput(
    for track: AVAssetTrack,
    formatDescription: CMFormatDescription?,
    outputSize: CGSize,
    outputCodec: AVVideoCodecType?,
    quality: Double?,
    keyFrameInterval: TimeInterval?
  ) async throws -> AVAssetWriterInput? {
    var outputSettings: [String: Any] = [
      AVVideoWidthKey: Int(outputSize.width),
      AVVideoHeightKey: Int(outputSize.height),
      AVVideoCodecKey: outputCodec ?? formatDescription?.videoCodecType ?? .hevc,
    ]
    if let colorPrimaries = formatDescription?.colorPrimaries,
      let colorTransferFunction = formatDescription?.colorTransferFunction,
      let colorYCbCrMatrix = formatDescription?.colorYCbCrMatrix
    {
      outputSettings[AVVideoColorPropertiesKey] = [
        AVVideoColorPrimariesKey: colorPrimaries,
        AVVideoTransferFunctionKey: colorTransferFunction,
        AVVideoYCbCrMatrixKey: colorYCbCrMatrix,
      ]
    }
    var compressionProperties: [String: Any] = [:]
    if let quality {
      compressionProperties[kVTCompressionPropertyKey_Quality as String] = quality
    }
    if let keyFrameInterval {
      // Without this, VideoToolbox HEVC can emit a single IDR at t=0 and rely on scene-change
      // detection. That breaks keyframe-snap seeking (e.g. IINA arrow keys jump to start).
      compressionProperties[kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration as String] =
        keyFrameInterval
    }
    if formatDescription?.hasLeftAndRightEye ?? false {
      compressionProperties[kVTCompressionPropertyKey_MVHEVCVideoLayerIDs as String] = [0, 1]
      if let extensions = formatDescription?.extensions {
        for key in [
          kVTCompressionPropertyKey_HeroEye,
          kVTCompressionPropertyKey_StereoCameraBaseline,
          kVTCompressionPropertyKey_HorizontalDisparityAdjustment,
          kCMFormatDescriptionExtension_HorizontalFieldOfView,
        ] {
          if let value = extensions.first(where: { $0.key == key })?.value {
            compressionProperties[key as String] = value
          }
        }
      }
    }
    if !compressionProperties.isEmpty {
      outputSettings[AVVideoCompressionPropertiesKey] = compressionProperties
    }
    let assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
    assetWriterInput.transform = try await track.load(.preferredTransform)
    assetWriterInput.expectsMediaDataInRealTime = false
    return assetWriterInput
  }

  // MARK: Per-track processing

  private static func processPassthroughSamples(
    from assetReaderOutput: AVAssetReaderOutput,
    to assetWriterInput: AVAssetWriterInput,
    progress: Progress?
  ) async throws {
    let sampleBuffers = makeSampleBufferStream(
      from: assetReaderOutput, label: "com.upscaling.passthrough.reader")

    defer { assetWriterInput.markAsFinished() }

    for await envelope in sampleBuffers {
      defer { envelope.release() }
      try Task.checkCancellation()
      let sampleBuffer = envelope.buffer
      if let progress {
        updateProgress(progress, pts: sampleBuffer.presentationTimeStamp)
      }
      try await waitForInputReady(assetWriterInput)
      if !assetWriterInput.append(sampleBuffer) {
        throw Error.appendFailed(sampleBuffer.presentationTimeStamp)
      }
    }
  }

  private static func processVideoSamples(
    from assetReaderOutput: AVAssetReaderOutput,
    to assetWriterInput: AVAssetWriterInput,
    adaptor: AVAssetWriterInputPixelBufferAdaptor,
    inputSize: CGSize,
    outputSize: CGSize,
    upscalerKind: UpscalerKind,
    progress: Progress
  ) async throws {
    let upscaler = try await upscalerKind.makeBackend(
      inputSize: inputSize, outputSize: outputSize)

    let sampleBuffers = makeSampleBufferStream(
      from: assetReaderOutput, label: "com.upscaling.video.reader")

    defer { assetWriterInput.markAsFinished() }

    for await envelope in sampleBuffers {
      defer { envelope.release() }
      try Task.checkCancellation()
      let sampleBuffer = envelope.buffer
      let pts = sampleBuffer.presentationTimeStamp
      updateProgress(progress, pts: pts)
      guard let imageBuffer = sampleBuffer.imageBuffer else {
        throw Error.missingImageBuffer
      }
      nonisolated(unsafe) let capturedBuffer = imageBuffer
      nonisolated(unsafe) let capturedPool = adaptor.pixelBufferPool
      let upscaled = try await upscaler.upscale(
        capturedBuffer, pixelBufferPool: capturedPool, outputPixelBuffer: nil)
      try await waitForInputReady(assetWriterInput)
      if !adaptor.append(upscaled, withPresentationTime: pts) {
        throw Error.appendFailed(pts)
      }
    }
  }

  private static func processSpatialVideoSamples(
    from assetReaderOutput: AVAssetReaderOutput,
    to assetWriterInput: AVAssetWriterInput,
    receiver: AVAssetWriterInput.TaggedPixelBufferGroupReceiver,
    inputSize: CGSize,
    outputSize: CGSize,
    upscalerKind: UpscalerKind,
    progress: Progress
  ) async throws {
    // Temporal backends (currently super resolution) accumulate prior-frame state and would
    // cross-pollute the two eyes if shared. Stateless backends (spatial) can share one instance
    // across both eyes, saving a second pool + pipeline allocation.
    let leftUpscaler: any UpscalerBackend
    let rightUpscaler: any UpscalerBackend
    if upscalerKind.requiresInstancePerStream {
      async let left = upscalerKind.makeBackend(inputSize: inputSize, outputSize: outputSize)
      async let right = upscalerKind.makeBackend(inputSize: inputSize, outputSize: outputSize)
      (leftUpscaler, rightUpscaler) = try await (left, right)
    } else {
      leftUpscaler = try await upscalerKind.makeBackend(
        inputSize: inputSize, outputSize: outputSize)
      rightUpscaler = leftUpscaler
    }

    let sampleBuffers = makeSampleBufferStream(
      from: assetReaderOutput, label: "com.upscaling.spatialvideo.reader")

    defer { assetWriterInput.markAsFinished() }

    for await envelope in sampleBuffers {
      defer { envelope.release() }
      try Task.checkCancellation()
      let sampleBuffer = envelope.buffer
      let pts = sampleBuffer.presentationTimeStamp
      updateProgress(progress, pts: pts)
      guard let taggedBuffers = sampleBuffer.taggedBuffers else {
        throw Error.missingTaggedBuffers
      }

      // Preserve each source tagged buffer's `videoLayerID` rather than synthesizing 0/1 in a
      // fixed order — downstream tools may rely on the hero-eye tag staying on its original
      // layer. Copy the source `CMTag` directly so we don't have to parse its numeric value.
      var leftEye: (buffer: CVPixelBuffer, layerTag: CMTag?)?
      var rightEye: (buffer: CVPixelBuffer, layerTag: CMTag?)?
      for tagged in taggedBuffers {
        let stereoTag = tagged.tags.first(matchingCategory: .stereoView)
        let layerTag = tagged.tags.first(matchingCategory: .videoLayerID)
        guard case .pixelBuffer(let buffer) = tagged.buffer else { continue }
        if stereoTag == .stereoView(.leftEye) {
          leftEye = (buffer, layerTag)
        } else if stereoTag == .stereoView(.rightEye) {
          rightEye = (buffer, layerTag)
        }
        if leftEye != nil, rightEye != nil { break }
      }
      guard let left = leftEye, let right = rightEye else {
        throw Error.invalidTaggedBuffers
      }

      nonisolated(unsafe) let leftCaptured = left.buffer
      nonisolated(unsafe) let rightCaptured = right.buffer
      async let upscaledLeftTask = leftUpscaler.upscale(leftCaptured)
      async let upscaledRightTask = rightUpscaler.upscale(rightCaptured)
      let upscaledLeft = try await upscaledLeftTask
      let upscaledRight = try await upscaledRightTask

      let leftTags: [CMTag] = [.stereoView(.leftEye), left.layerTag ?? .videoLayerID(0)]
      let rightTags: [CMTag] = [.stereoView(.rightEye), right.layerTag ?? .videoLayerID(1)]
      nonisolated(unsafe) let leftTagged = CMTaggedBuffer(
        tags: leftTags, pixelBuffer: upscaledLeft)
      nonisolated(unsafe) let rightTagged = CMTaggedBuffer(
        tags: rightTags, pixelBuffer: upscaledRight)
      let taggedGroup: [CMTaggedDynamicBuffer] = [
        CMTaggedDynamicBuffer(unsafeBuffer: leftTagged),
        CMTaggedDynamicBuffer(unsafeBuffer: rightTagged),
      ]

      try await waitForInputReady(assetWriterInput)
      if try !receiver.appendImmediately(taggedGroup, with: pts) {
        throw Error.appendFailed(pts)
      }
    }
  }

  /// Drives an `AVAssetReaderOutput` on a dedicated GCD queue and yields each sample buffer into
  /// an `AsyncStream` with bounded backpressure. The producer parks on a semaphore until the
  /// consumer releases a permit (via `envelope.release()`), capping the number of decoded
  /// buffers held in memory at `sampleBufferBufferDepth`. Running `copyNextSampleBuffer` off the
  /// cooperative pool avoids priority-inversion deadlocks.
  private static func makeSampleBufferStream(
    from output: AVAssetReaderOutput,
    label: String
  ) -> AsyncStream<SampleBufferEnvelope> {
    let queue = DispatchQueue(label: label, qos: .userInitiated)
    let semaphore = DispatchSemaphore(value: sampleBufferBufferDepth)
    return AsyncStream { continuation in
      continuation.onTermination = { _ in
        // Wake a parked producer so it exits rather than blocking forever on a dead stream.
        for _ in 0..<sampleBufferBufferDepth { semaphore.signal() }
      }
      nonisolated(unsafe) let unsafeOutput = output
      queue.async {
        while true {
          semaphore.wait()
          guard let buffer = unsafeOutput.copyNextSampleBuffer() else {
            continuation.finish()
            return
          }
          let envelope = SampleBufferEnvelope(buffer: buffer) { semaphore.signal() }
          if case .terminated = continuation.yield(envelope) { return }
        }
      }
    }
  }

  /// Polls `isReadyForMoreMediaData` with short sleeps. Cooperative-pool-friendly — the `await
  /// Task.sleep` yields instead of blocking a thread, and cancellation is observed between ticks.
  private static func waitForInputReady(_ input: AVAssetWriterInput) async throws {
    while !input.isReadyForMoreMediaData {
      try Task.checkCancellation()
      try await Task.sleep(for: writerReadyPollInterval)
    }
  }
}

// MARK: - SampleBufferEnvelope

/// Transfers a `CMSampleBuffer` across an `AsyncStream` boundary and carries the producer-side
/// backpressure permit. Consumers must call `release()` once per envelope (via `defer` at the
/// top of each loop iteration) so the producer can fetch the next frame.
private struct SampleBufferEnvelope: @unchecked Sendable {
  let buffer: CMSampleBuffer
  let release: @Sendable () -> Void
}

// MARK: UpscalingExportSession.Error

extension UpscalingExportSession {
  public enum Error: Swift.Error, LocalizedError {
    case outputURLAlreadyExists
    case couldNotAddAssetReaderOutput(AVMediaType)
    case couldNotAddAssetWriterInput(AVMediaType)
    case missingImageBuffer
    case missingTaggedBuffers
    case invalidTaggedBuffers
    case failedToStartWriting
    case failedToStartReading
    case appendFailed(CMTime)
    case unsupportedColorSpace
    case noMediaTracks

    public var errorDescription: String? {
      switch self {
      case .outputURLAlreadyExists:
        "A file already exists at the output URL."
      case .couldNotAddAssetReaderOutput(let mediaType):
        "Could not add asset reader output for media type: \(mediaType.rawValue)."
      case .couldNotAddAssetWriterInput(let mediaType):
        "Could not add asset writer input for media type: \(mediaType.rawValue)."
      case .missingImageBuffer:
        "A video sample buffer did not contain an image buffer."
      case .missingTaggedBuffers:
        "A spatial video sample buffer did not contain tagged buffers."
      case .invalidTaggedBuffers:
        "Spatial video sample buffer is missing left- or right-eye tagged buffers."
      case .failedToStartWriting:
        "AVAssetWriter failed to start writing."
      case .failedToStartReading:
        "AVAssetReader failed to start reading."
      case .appendFailed(let time):
        "Failed to append sample at time \(time.seconds)s."
      case .unsupportedColorSpace:
        "Unsupported color space. This 8-bit sRGB-perceptual MetalFX path only supports "
          + "Rec. 709 / sRGB SDR sources. HDR (PQ / HLG) and Rec. 2020 wide-gamut inputs "
          + "are rejected because they would be silently clipped or shifted."
      case .noMediaTracks:
        "Input asset contains no media tracks to export."
      }
    }
  }
}
