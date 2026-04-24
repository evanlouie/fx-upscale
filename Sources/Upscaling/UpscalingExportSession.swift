import AVFoundation
import Foundation
import VideoToolbox
import os

// MARK: - UpscalingExportSession

public final class UpscalingExportSession: @unchecked Sendable {
  // MARK: ChainFactory

  /// Builds a `FrameProcessorChain` for a video track of the given `inputSize`. The factory
  /// closure encodes which effects to include and in what order — the session is intentionally
  /// agnostic to pipeline ordering so callers (CLIs, GUIs, future config files) can define
  /// their own policy without touching library code.
  ///
  /// The factory is invoked once per video track, and a second time per track when a stereo
  /// export's chain reports `requiresInstancePerStream == true`. The returned chain's
  /// `outputSize` must match the session's configured `outputSize`.
  public typealias ChainFactory = @Sendable (
    _ inputSize: CGSize
  ) async throws -> FrameProcessorChain

  // MARK: ChainCapabilities

  /// Synchronous snapshot of what the `chainFactory`'s output would accept and produce. The
  /// session consults this before opening any reader/writer — so HDR chains can ask for a
  /// 10-bit 420 round-trip without paying `VTSuperResolutionUpscaler.init`'s model-download
  /// cost up front.
  public struct ChainCapabilities: Sendable {
    public let supportedSourceInputFormats: Set<OSType>
    public let producedOutputFormat: OSType
    public let srgbRejectingStageName: String?

    public init(
      supportedSourceInputFormats: Set<OSType>,
      producedOutputFormat: OSType,
      srgbRejectingStageName: String? = nil
    ) {
      self.supportedSourceInputFormats = supportedSourceInputFormats
      self.producedOutputFormat = producedOutputFormat
      self.srgbRejectingStageName = srgbRejectingStageName
    }

    public static let bgraSRGB = ChainCapabilities(
      supportedSourceInputFormats: [kCVPixelFormatType_32BGRA],
      producedOutputFormat: kCVPixelFormatType_32BGRA)
  }

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
  ///   - chainFactory: Builds the frame-processing chain applied to video tracks. When
  ///     `nil` (default), a single-stage `MTLFXSpatialScaler` chain sized to `outputSize`
  ///     is used — callers that need other effects (super resolution, denoise, motion blur,
  ///     frame-rate conversion) provide their own factory and encode ordering there.
  ///   - chainCapabilities: Declares what the `chainFactory`'s output accepts and produces
  ///     — consulted before opening any reader/writer. Defaults to `.bgraSRGB`.
  public init(
    asset: AVAsset,
    outputCodec: AVVideoCodecType? = nil,
    preferredOutputURL: URL,
    outputSize: CGSize,
    quality: Double? = nil,
    keyFrameInterval: TimeInterval? = nil,
    creator: String? = nil,
    chainFactory: ChainFactory? = nil,
    chainCapabilities: ChainCapabilities = .bgraSRGB
  ) {
    self.asset = asset
    self.outputCodec = outputCodec
    self.quality = quality
    self.keyFrameInterval = keyFrameInterval
    outputURL = preferredOutputURL
    self.outputSize = outputSize
    self.creator = creator
    self.chainFactory = chainFactory ?? { inputSize in
      let backend = try await UpscalerKind.spatial.makeBackend(
        inputSize: inputSize, outputSize: outputSize)
      return try FrameProcessorChain(
        inputSize: inputSize, outputSize: outputSize, stages: [backend])
    }
    self.chainCapabilities = chainCapabilities
    progress = Progress(parent: nil, userInfo: [.fileURLKey: outputURL])
    progress.isCancellable = true
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
  private let chainFactory: ChainFactory
  private let chainCapabilities: ChainCapabilities

  public let progress: Progress

  public func export() async throws {
    #if os(macOS)
      progress.publish()
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

      switch mediaType {
      case .video:
        // Use encoded pixel dimensions, not naturalSize. AVAssetReaderTrackOutput delivers
        // decoded frames at encoded dimensions; naturalSize can differ due to PAR or transforms.
        guard let formatDescription else { continue }
        let encodedInputSize = CMVideoFormatDescriptionGetDimensions(formatDescription).cgSize
        let colorMetadata = formatDescription.colorMetadata

        let chainRequiresSRGB =
          chainCapabilities.supportedSourceInputFormats == [kCVPixelFormatType_32BGRA]
        if colorMetadata.isUnsupportedForBGRAPath, chainRequiresSRGB {
          throw Error.unsupportedColorSpace(
            stageName: chainCapabilities.srgbRejectingStageName)
        }

        let pipelinePixelFormat = Self.resolvePipelinePixelFormat(
          colorMetadata: colorMetadata,
          accepted: chainCapabilities.supportedSourceInputFormats)

        guard
          let assetReaderOutput = Self.videoAssetReaderOutput(
            for: track,
            formatDescription: formatDescription,
            colorMetadata: colorMetadata,
            pixelFormat: pipelinePixelFormat),
          let assetWriterInput = try await Self.videoAssetWriterInput(
            for: track, formatDescription: formatDescription,
            colorMetadata: colorMetadata,
            outputSize: outputSize, outputCodec: outputCodec, quality: quality,
            keyFrameInterval: keyFrameInterval,
            outputPixelFormat: chainCapabilities.producedOutputFormat)
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
        // Decoders may attach color metadata per decoded buffer even for SDR sources
        // (ICC/gamma/range/guessed color info). Preserve propagating attachments across
        // freshly allocated processor outputs instead of treating only HDR as metadata-bearing.
        let preserveColorAttachments = true
        if formatDescription.hasLeftAndRightEye {
          let receiver = assetWriter.inputTaggedPixelBufferGroupReceiver(
            for: assetWriterInput, pixelBufferAttributes: nil)
          mediaTracks.append(
            .spatialVideo(
              output: assetReaderOutput, input: assetWriterInput,
              inputSize: encodedInputSize, receiver: receiver,
              preserveColorAttachments: preserveColorAttachments))
        } else {
          let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: assetWriterInput,
            sourcePixelBufferAttributes: PixelBufferAttributes.formatted(
              chainCapabilities.producedOutputFormat, size: outputSize)
          )
          mediaTracks.append(
            .video(
              output: assetReaderOutput, input: assetWriterInput,
              inputSize: encodedInputSize, adaptor: adaptor,
              preserveColorAttachments: preserveColorAttachments))
        }

      case .audio:
        let assetReaderOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        assetReaderOutput.alwaysCopiesSampleData = false
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
        assetReaderOutput.alwaysCopiesSampleData = false
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
            case .video(let output, let input, let inputSize, let adaptor, let preserveColorAttachments):
              let childProgress = Progress(totalUnitCount: durationUnits)
              self.progress.addChild(
                childProgress, withPendingUnitCount: Self.videoTrackProgressWeight)
              try await Self.processVideoSamples(
                from: output, to: input, adaptor: adaptor,
                inputSize: inputSize,
                chainFactory: self.chainFactory,
                preserveColorAttachments: preserveColorAttachments,
                progress: childProgress)
            case .spatialVideo(let output, let input, let inputSize, let receiver, let preserveColorAttachments):
              let childProgress = Progress(totalUnitCount: durationUnits)
              self.progress.addChild(
                childProgress, withPendingUnitCount: Self.videoTrackProgressWeight)
              try await Self.processSpatialVideoSamples(
                from: output, to: input, receiver: receiver,
                inputSize: inputSize,
                chainFactory: self.chainFactory,
                preserveColorAttachments: preserveColorAttachments,
                progress: childProgress)
            }
          }
        }
        do {
          try await group.waitForAllCancellingOnFirstError()
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
      // Throw the conventional `CancellationError` so callers using the standard-library
      // pattern (`catch is CancellationError`) can treat cooperative cancellation differently
      // from a real export failure. `AVAssetWriter.Status.cancelled` is reached via the
      // `progress.cancellationHandler` installed earlier in `export()`, which runs when the
      // caller either invokes `progress.cancel()` directly or cancels the surrounding Task.
      try? FileManager.default.removeItem(at: outputURL)
      throw CancellationError()
    case .failed:
      try? FileManager.default.removeItem(at: outputURL)
      throw assetWriter.error ?? Error.failedToStartWriting
    case .unknown:
      fallthrough
    @unknown default:
      try? FileManager.default.removeItem(at: outputURL)
      throw assetWriter.error ?? Error.failedToStartWriting
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
      adaptor: AVAssetWriterInputPixelBufferAdaptor,
      preserveColorAttachments: Bool
    )
    case spatialVideo(
      output: AVAssetReaderOutput,
      input: AVAssetWriterInput,
      inputSize: CGSize,
      receiver: AVAssetWriterInput.TaggedPixelBufferGroupReceiver,
      preserveColorAttachments: Bool
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
    formatDescription: CMFormatDescription?,
    colorMetadata: VideoColorMetadata,
    pixelFormat: OSType = kCVPixelFormatType_32BGRA
  ) -> AVAssetReaderOutput? {
    var outputSettings: [String: Any] = PixelBufferAttributes.formatted(pixelFormat)
    if let colorProperties = colorMetadata.avColorProperties {
      outputSettings[AVVideoColorPropertiesKey] = colorProperties
    }
    if colorMetadata.isWideGamut {
      outputSettings[AVVideoAllowWideColorKey] = NSNumber(value: true)
    }
    if formatDescription?.hasLeftAndRightEye ?? false {
      outputSettings[AVVideoDecompressionPropertiesKey] = [
        kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs: [0, 1]
      ]
    }
    let assetReaderOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
    assetReaderOutput.alwaysCopiesSampleData = false
    return assetReaderOutput
  }

  /// Picks the pipeline pixel format by intersecting the source color/range preference with
  /// the chain's negotiated input formats. Full-range and 10-bit sources prefer matching
  /// YUV formats first, with BGRA only as a final fallback.
  private static func resolvePipelinePixelFormat(
    colorMetadata: VideoColorMetadata,
    accepted: Set<OSType>
  ) -> OSType {
    FrameFormat.resolvePreferredPixelFormat(for: colorMetadata, accepted: accepted)
  }

  private static func videoAssetWriterInput(
    for track: AVAssetTrack,
    formatDescription: CMFormatDescription?,
    colorMetadata: VideoColorMetadata,
    outputSize: CGSize,
    outputCodec: AVVideoCodecType?,
    quality: Double?,
    keyFrameInterval: TimeInterval?,
    outputPixelFormat: OSType
  ) async throws -> AVAssetWriterInput? {
    let codec = outputCodec ?? formatDescription?.videoCodecType ?? .hevc
    var outputSettings: [String: Any] = [
      AVVideoWidthKey: Int(outputSize.width),
      AVVideoHeightKey: Int(outputSize.height),
      AVVideoCodecKey: codec,
    ]
    if let colorProperties = colorMetadata.avColorProperties {
      outputSettings[AVVideoColorPropertiesKey] = colorProperties
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
    for (key, value) in colorMetadata.compressionColorProperties {
      compressionProperties[key] = value
    }
    if codec == .hevc, colorMetadata.requiresMain10 || FrameFormat.isTenBit(outputPixelFormat) {
      compressionProperties[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel
    }
    if formatDescription?.hasLeftAndRightEye ?? false {
      compressionProperties[kVTCompressionPropertyKey_MVHEVCVideoLayerIDs as String] = [0, 1]
      if let extensions = formatDescription?.extensions {
        for key in [
          kVTCompressionPropertyKey_HeroEye,
          kVTCompressionPropertyKey_StereoCameraBaseline,
          kVTCompressionPropertyKey_HorizontalDisparityAdjustment,
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
    chainFactory: ChainFactory,
    preserveColorAttachments: Bool,
    progress: Progress
  ) async throws {
    let chain = try await chainFactory(inputSize)

    let sampleBuffers = makeSampleBufferStream(
      from: assetReaderOutput, label: "com.upscaling.video.reader")

    defer { assetWriterInput.markAsFinished() }

    let inputChannel = PipelineChannel<FrameProcessorOutput>(capacity: 2)
    let attachmentTimeline: AttachmentTimeline? =
      preserveColorAttachments ? AttachmentTimeline() : nil

    nonisolated(unsafe) let capturedAdaptor = adaptor
    nonisolated(unsafe) let capturedWriterInput = assetWriterInput
    guard let pool = adaptor.pixelBufferPool else {
      throw Error.failedToStartWriting
    }
    nonisolated(unsafe) let capturedPool: CVPixelBufferPool? = pool

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        defer { inputChannel.finish() }
        var sourceSequence: Int64 = 0
        for await envelope in sampleBuffers {
          defer { envelope.release() }
          try Task.checkCancellation()
          let sampleBuffer = envelope.buffer
          let pts = sampleBuffer.presentationTimeStamp
          updateProgress(progress, pts: pts)
          guard let imageBuffer = sampleBuffer.imageBuffer else {
            throw Error.missingImageBuffer
          }
          if let attachmentTimeline {
            attachmentTimeline.store(
              sourceSequence: sourceSequence,
              pts: pts,
              attachments: CVBufferCopyAttachments(imageBuffer, .shouldPropagate))
          }
          nonisolated(unsafe) let capturedBuffer = imageBuffer
          await inputChannel.send(
            FrameProcessorOutput(
              pixelBuffer: capturedBuffer,
              presentationTimeStamp: pts))
          sourceSequence += 1
        }
      }

      group.addTask {
        try await chain.processAllBatches(
          from: inputChannel,
          outputPool: capturedPool
        ) { batch in
          if batch.completesSource {
            if let sourceSequence = batch.sourceSequence {
              attachmentTimeline?.complete(sourceSequence: sourceSequence)
            }
            return
          }
          for output in batch.outputs {
            if let attachmentTimeline,
              let attachments = attachmentTimeline.attachments(
                for: output.presentationTimeStamp)
            {
              CVBufferSetAttachments(output.pixelBuffer, attachments, .shouldPropagate)
            }
            try await waitForInputReady(capturedWriterInput)
            if !capturedAdaptor.append(
              output.pixelBuffer, withPresentationTime: output.presentationTimeStamp)
            {
              throw Error.appendFailed(output.presentationTimeStamp)
            }
          }
        }
      }

      try await group.waitForAllCancellingOnFirstError()
    }
  }

  /// Processes spatial (MV-HEVC) video samples through per-eye chains.
  private static func processSpatialVideoSamples(
    from assetReaderOutput: AVAssetReaderOutput,
    to assetWriterInput: AVAssetWriterInput,
    receiver: AVAssetWriterInput.TaggedPixelBufferGroupReceiver,
    inputSize: CGSize,
    chainFactory: ChainFactory,
    preserveColorAttachments: Bool,
    progress: Progress
  ) async throws {
    let leftAttachmentTimeline: AttachmentTimeline? =
      preserveColorAttachments ? AttachmentTimeline() : nil
    let rightAttachmentTimeline: AttachmentTimeline? =
      preserveColorAttachments ? AttachmentTimeline() : nil
    // If any stage is stateful, each eye must get its own chain so prior-frame references
    // don't cross-pollute between eyes. A fully stateless chain (e.g. MetalFX spatial only)
    // can safely be shared, saving the ~30 MiB second pool at 4K output.
    let leftChain = try await chainFactory(inputSize)
    let rightChain =
      leftChain.requiresInstancePerStream
      ? try await chainFactory(inputSize)
      : leftChain

    let sampleBuffers = makeSampleBufferStream(
      from: assetReaderOutput, label: "com.upscaling.spatialvideo.reader")

    defer { assetWriterInput.markAsFinished() }

    // Per-eye source-frame channels feed each chain's batch-aware `processAll` variant.
    // The chains may stream multiple output batches for one source frame (FRC chunking), so
    // layer tags are keyed by source sequence instead of consumed one-batch-per-source.
    let leftInputChannel = PipelineChannel<FrameProcessorOutput>(capacity: 2)
    let rightInputChannel = PipelineChannel<FrameProcessorOutput>(capacity: 2)
    let leftOutputChannel = PipelineChannel<FrameProcessorBatch>(capacity: 2)
    let rightOutputChannel = PipelineChannel<FrameProcessorBatch>(capacity: 2)
    let tagCache = PerSourceTagCache()

    nonisolated(unsafe) let capturedReceiver = receiver
    nonisolated(unsafe) let capturedWriterInput = assetWriterInput

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        defer {
          leftInputChannel.finish()
          rightInputChannel.finish()
        }
        var sourceSequence: Int64 = 0
        for await envelope in sampleBuffers {
          defer { envelope.release() }
          try Task.checkCancellation()
          let sampleBuffer = envelope.buffer
          let pts = sampleBuffer.presentationTimeStamp
          updateProgress(progress, pts: pts)
          guard let taggedBuffers = sampleBuffer.taggedBuffers else {
            throw Error.missingTaggedBuffers
          }

          // Preserve each source tagged buffer's `videoLayerID` rather than synthesizing 0/1
          // in a fixed order — downstream tools may rely on the hero-eye tag staying on its
          // original layer. Copy the source `CMTag` directly so we don't have to parse its
          // numeric value.
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

          if let leftAttachmentTimeline {
            leftAttachmentTimeline.store(
              sourceSequence: sourceSequence,
              pts: pts,
              attachments: CVBufferCopyAttachments(left.buffer, .shouldPropagate))
          }
          if let rightAttachmentTimeline {
            rightAttachmentTimeline.store(
              sourceSequence: sourceSequence,
              pts: pts,
              attachments: CVBufferCopyAttachments(right.buffer, .shouldPropagate))
          }

          nonisolated(unsafe) let leftBuf = left.buffer
          nonisolated(unsafe) let rightBuf = right.buffer
          tagCache.store(
            sourceSequence: sourceSequence,
            left: left.layerTag,
            right: right.layerTag)
          await leftInputChannel.send(
            FrameProcessorOutput(pixelBuffer: leftBuf, presentationTimeStamp: pts))
          await rightInputChannel.send(
            FrameProcessorOutput(pixelBuffer: rightBuf, presentationTimeStamp: pts))
          sourceSequence += 1
        }
      }

      // Left-eye pipeline.
      group.addTask {
        defer { leftOutputChannel.finish() }
        try await leftChain.processAllBatches(
          from: leftInputChannel,
          outputPool: nil
        ) { batch in
          if batch.completesSource {
            if let sourceSequence = batch.sourceSequence {
              leftAttachmentTimeline?.complete(sourceSequence: sourceSequence)
            }
          } else if let leftAttachmentTimeline {
            for output in batch.outputs {
              if let attachments = leftAttachmentTimeline.attachments(
                for: output.presentationTimeStamp)
              {
                CVBufferSetAttachments(output.pixelBuffer, attachments, .shouldPropagate)
              }
            }
          }
          await leftOutputChannel.send(batch)
        }
      }

      // Right-eye pipeline.
      group.addTask {
        defer { rightOutputChannel.finish() }
        try await rightChain.processAllBatches(
          from: rightInputChannel,
          outputPool: nil
        ) { batch in
          if batch.completesSource {
            if let sourceSequence = batch.sourceSequence {
              rightAttachmentTimeline?.complete(sourceSequence: sourceSequence)
            }
          } else if let rightAttachmentTimeline {
            for output in batch.outputs {
              if let attachments = rightAttachmentTimeline.attachments(
                for: output.presentationTimeStamp)
              {
                CVBufferSetAttachments(output.pixelBuffer, attachments, .shouldPropagate)
              }
            }
          }
          await rightOutputChannel.send(batch)
        }
      }

      // Assembly: zip per-eye handler-batches, re-attach layer tags, and append.
      group.addTask {
        var leftIter = leftOutputChannel.makeAsyncIterator()
        var rightIter = rightOutputChannel.makeAsyncIterator()
        while true {
          try Task.checkCancellation()
          let leftBatch = await leftIter.next()
          let rightBatch = await rightIter.next()
          switch (leftBatch, rightBatch) {
          case (nil, nil):
            return
          case (.some(let l), nil):
            throw Error.spatialFrameCountMismatch(left: l.outputs.count, right: 0)
          case (nil, .some(let r)):
            throw Error.spatialFrameCountMismatch(left: 0, right: r.outputs.count)
          case (.some(let leftOutputs), .some(let rightOutputs)):
            guard leftOutputs.sourceSequence == rightOutputs.sourceSequence,
              leftOutputs.completesSource == rightOutputs.completesSource
            else {
              throw Error.spatialFrameCountMismatch(
                left: leftOutputs.outputs.count,
                right: rightOutputs.outputs.count)
            }
            if leftOutputs.completesSource {
              if let sourceSequence = leftOutputs.sourceSequence {
                tagCache.remove(sourceSequence: sourceSequence)
              }
              continue
            }
            // Both eyes must emit the same number of frames on the same PTS schedule.
            // 1:1 stages always produce a single output; FRC stages emit M interpolated
            // frames but — because both eyes run the same chain with the same input
            // PTS — the emitted counts and timestamps must agree.
            guard leftOutputs.outputs.count == rightOutputs.outputs.count else {
              throw Error.spatialFrameCountMismatch(
                left: leftOutputs.outputs.count, right: rightOutputs.outputs.count)
            }
            let tags = leftOutputs.sourceSequence.flatMap {
              tagCache.tags(sourceSequence: $0)
            }
            try await appendStereo(
              leftOutputs: leftOutputs.outputs, rightOutputs: rightOutputs.outputs,
              leftLayerTag: tags?.left, rightLayerTag: tags?.right,
              receiver: capturedReceiver, input: capturedWriterInput)
          }
        }
      }

      try await group.waitForAllCancellingOnFirstError()
    }
  }

  private static func appendStereo(
    leftOutputs: [FrameProcessorOutput],
    rightOutputs: [FrameProcessorOutput],
    leftLayerTag: CMTag?,
    rightLayerTag: CMTag?,
    receiver: AVAssetWriterInput.TaggedPixelBufferGroupReceiver,
    input: AVAssetWriterInput
  ) async throws {
    for (leftOutput, rightOutput) in zip(leftOutputs, rightOutputs) {
      let outputPts = leftOutput.presentationTimeStamp
      let leftTags: [CMTag] = [.stereoView(.leftEye), leftLayerTag ?? .videoLayerID(0)]
      let rightTags: [CMTag] = [.stereoView(.rightEye), rightLayerTag ?? .videoLayerID(1)]
      nonisolated(unsafe) let leftTagged = CMTaggedBuffer(
        tags: leftTags, pixelBuffer: leftOutput.pixelBuffer)
      nonisolated(unsafe) let rightTagged = CMTaggedBuffer(
        tags: rightTags, pixelBuffer: rightOutput.pixelBuffer)
      let taggedGroup: [CMTaggedDynamicBuffer] = [
        CMTaggedDynamicBuffer(unsafeBuffer: leftTagged),
        CMTaggedDynamicBuffer(unsafeBuffer: rightTagged),
      ]

      try await waitForInputReady(input)
      if try !receiver.appendImmediately(taggedGroup, with: outputPts) {
        throw Error.appendFailed(outputPts)
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

// MARK: - AttachmentTimeline

/// Lock-protected timeline for CVBuffer `.shouldPropagate` attachments.
///
/// Lookups are intentionally non-destructive: FRC can emit several frames between the same
/// source pair, and every pass-through/interpolated output needs the latest applicable color
/// metadata. Eviction is driven by chain source-completion markers and keeps the completed
/// source alive until the following source has emitted its interpolation window.
final class AttachmentTimeline: @unchecked Sendable {
  private struct Entry {
    let pts: CMTime
    let attachments: CFDictionary?
  }

  private let lock = NSLock()
  private var storage: [Int64: Entry] = [:]

  func store(sourceSequence: Int64, pts: CMTime, attachments: CFDictionary?) {
    lock.lock()
    defer { lock.unlock() }
    storage[sourceSequence] = Entry(pts: pts, attachments: attachments)
  }

  /// Returns attachments for the source PTS exactly matching `pts`, or — when no exact match
  /// exists — the latest source PTS ≤ `pts`.
  func attachments(for pts: CMTime) -> CFDictionary? {
    lock.lock()
    defer { lock.unlock() }
    guard !storage.isEmpty else { return nil }
    var best: Entry?
    for entry in storage.values where entry.pts <= pts {
      if let current = best {
        if entry.pts > current.pts { best = entry }
      } else {
        best = entry
      }
    }
    return best?.attachments
  }

  func complete(sourceSequence: Int64) {
    lock.lock()
    defer { lock.unlock() }
    storage = storage.filter { sequence, _ in sequence >= sourceSequence }
  }
}

// MARK: - PerSourceTagCache

final class PerSourceTagCache: @unchecked Sendable {
  typealias Tags = (left: CMTag?, right: CMTag?)

  private let lock = OSAllocatedUnfairLock(initialState: [Int64: Tags]())

  func store(sourceSequence: Int64, left: CMTag?, right: CMTag?) {
    lock.withLock { storage in
      storage[sourceSequence] = (left, right)
    }
  }

  func tags(sourceSequence: Int64) -> Tags? {
    lock.withLock { storage in
      storage[sourceSequence]
    }
  }

  func remove(sourceSequence: Int64) {
    _ = lock.withLock { storage in
      storage.removeValue(forKey: sourceSequence)
    }
  }
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
    case unsupportedColorSpace(stageName: String?)
    case noMediaTracks
    case spatialFrameCountMismatch(left: Int, right: Int)

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
      case .unsupportedColorSpace(let stageName):
        "\(stageName ?? "This chain") requires an 8-bit RGB SDR path; HDR (PQ / HLG), "
          + "Rec. 2020, and 10-bit sources are rejected to avoid silent clipping or "
          + "precision loss. Use a chain whose stages report native YUV / high-precision "
          + "support, or pre-convert the source to 8-bit SDR."
      case .noMediaTracks:
        "Input asset contains no media tracks to export."
      case .spatialFrameCountMismatch(let left, let right):
        "Spatial video frame processor emitted mismatched output counts "
          + "(left eye: \(left), right eye: \(right)). Both eyes must produce the same "
          + "number of output frames."
      }
    }
  }
}
