@preconcurrency import AVFoundation
import VideoToolbox

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
  ///   - creator: Optional creator string applied as a Spotlight xattr on macOS.
  public init(
    asset: AVAsset,
    outputCodec: AVVideoCodecType? = nil,
    preferredOutputURL: URL,
    outputSize: CGSize,
    quality: Double? = nil,
    creator: String? = nil
  ) {
    self.asset = asset
    self.outputCodec = outputCodec
    self.quality = quality
    outputURL = preferredOutputURL
    self.outputSize = outputSize
    self.creator = creator
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
  public let creator: String?

  public let progress: Progress

  public func export() async throws {
    #if os(macOS)
      defer { progress.unpublish() }
    #endif
    // Always clear the cancellation handler on exit so the progress object doesn't outlive the
    // session while still retaining AVFoundation reader/writer references.
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
    // Use millisecond precision for smooth progress, guarding against non-numeric durations
    // (e.g. indefinite / live streams).
    let durationUnits: Int64 =
      duration.isNumeric
      ? max(1, Int64(duration.seconds * Double(Self.progressUnitsPerSecond))) : 1

    // Install a cancellation handler that tears down AVFoundation objects on user cancel.
    nonisolated(unsafe) let cancelReader = assetReader
    nonisolated(unsafe) let cancelWriter = assetWriter
    progress.cancellationHandler = {
      cancelReader.cancelReading()
      cancelWriter.cancelWriting()
    }

    var mediaTracks: [MediaTrack] = []
    let tracks = try await asset.load(.tracks)

    for track in tracks {
      let mediaType = track.mediaType
      let formatDescription = try await track.load(.formatDescriptions).first

      if mediaType == .video, formatDescription?.isHDR == true {
        // Reject HDR inputs: the 8-bit BGRA MetalFX path would silently clip HDR pixels while
        // propagating HDR metadata, producing an incorrect file. See review finding C3/C4.
        throw Error.hdrNotSupported
      }

      switch mediaType {
      case .video:
        guard
          let assetReaderOutput = Self.videoAssetReaderOutput(
            for: track, formatDescription: formatDescription),
          let assetWriterInput = try await Self.videoAssetWriterInput(
            for: track, formatDescription: formatDescription,
            outputSize: outputSize, outputCodec: outputCodec, quality: quality)
        else { continue }

        guard assetReader.canAdd(assetReaderOutput) else {
          throw Error.couldNotAddAssetReaderOutput(mediaType)
        }
        assetReader.add(assetReaderOutput)
        guard assetWriter.canAdd(assetWriterInput) else {
          throw Error.couldNotAddAssetWriterInput(mediaType)
        }
        assetWriter.add(assetWriterInput)

        progress.totalUnitCount += 10
        if #available(macOS 14.0, iOS 17.0, *),
          formatDescription?.hasLeftAndRightEye ?? false
        {
          let adaptor = AVAssetWriterInputTaggedPixelBufferGroupAdaptor(
            assetWriterInput: assetWriterInput,
            sourcePixelBufferAttributes: PixelBufferAttributes.bgra(size: outputSize)
          )
          try await mediaTracks.append(
            .spatialVideo(
              output: assetReaderOutput, input: assetWriterInput,
              inputSize: track.load(.naturalSize), adaptor: adaptor))
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
        // Passthrough audio: do not request format conversion; append sample buffers as-is.
        let assetReaderOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        // Default (true) is safer across multiple queues; see review M6.
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
    assetWriter.startSession(atSourceTime: .zero)

    do {
      try await withThrowingTaskGroup(of: Void.self) { [weak self] group in
        for mediaTrack in mediaTracks {
          group.addTask { [weak self] in
            guard let self else { return }
            try Task.checkCancellation()
            switch mediaTrack {
            case .passthrough(let output, let input):
              // Only audio passthrough contributes to the weighted parent progress. Timecode,
              // subtitle, CC, and metadata tracks are tiny and don't need their own child.
              let childProgress: Progress
              if input.mediaType == .audio {
                childProgress = Progress(totalUnitCount: durationUnits)
                self.progress.addChild(childProgress, withPendingUnitCount: 1)
              } else {
                childProgress = Progress(totalUnitCount: durationUnits)
              }
              try await Self.processPassthroughSamples(
                from: output, to: input, progress: childProgress)
            case .video(let output, let input, let inputSize, let adaptor):
              let childProgress = Progress(totalUnitCount: durationUnits)
              self.progress.addChild(childProgress, withPendingUnitCount: 10)
              try await Self.processVideoSamples(
                from: output, to: input, adaptor: adaptor,
                inputSize: inputSize, outputSize: self.outputSize,
                progress: childProgress)
            case .spatialVideo(let output, let input, let inputSize, let adaptor):
              if #available(macOS 14.0, iOS 17.0, *) {
                let childProgress = Progress(totalUnitCount: durationUnits)
                self.progress.addChild(childProgress, withPendingUnitCount: 10)
                try await Self.processSpatialVideoSamples(
                  from: output, to: input, adaptor: adaptor,
                  inputSize: inputSize, outputSize: self.outputSize,
                  progress: childProgress)
              }
            }
          }
        }
        do {
          try await group.waitForAll()
        } catch {
          // On any task failure, cancel siblings and tear down AVFoundation objects so that
          // pending `requestMediaDataWhenReady` loops observe the cancelled state and resume
          // their continuations.
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
    case .cancelled:
      try? FileManager.default.removeItem(at: outputURL)
      throw CancellationError()
    case .failed:
      try? FileManager.default.removeItem(at: outputURL)
      throw assetWriter.error ?? Error.failedToStartWriting
    default:
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

  /// Spotlight creator metadata xattr key (macOS).
  private static let creatorXattrName = "com.apple.metadata:kMDItemCreator"

  private enum MediaTrack: @unchecked Sendable {
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
      // AVAssetWriterInputTaggedPixelBufferGroupAdaptor (macOS 14+). Stored as NSObject so the
      // enum is available on older OS versions; cast at use site via `preconditionFailure`
      // since construction is the only place this can be set (see export()).
      adaptor: NSObject
    )
  }

  /// Update `progress.completedUnitCount` only if the presentation time has advanced by at least
  /// `progressUpdateThresholdUnits` milliseconds since the last write, or the end has been
  /// reached. Eliminates ~99% of KVO/publish notifications on typical long videos with no
  /// user-visible UX change.
  private static func updateProgress(_ progress: Progress, pts: CMTime) {
    guard pts.isNumeric else { return }
    let newUnits = Int64(pts.seconds * Double(progressUnitsPerSecond))
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
    var outputSettings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
    ]
    if #available(macOS 14.0, iOS 17.0, *),
      formatDescription?.hasLeftAndRightEye ?? false
    {
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
    quality: Double?
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
    if #available(macOS 14.0, iOS 17.0, *),
      formatDescription?.hasLeftAndRightEye ?? false
    {
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
    progress: Progress
  ) async throws {
    nonisolated(unsafe) let input = assetWriterInput
    nonisolated(unsafe) let output = assetReaderOutput
    let resume = AsyncResume()
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Swift.Error>) in
      let queue = DispatchQueue(label: "com.upscaling.passthrough", qos: .userInitiated)
      input.requestMediaDataWhenReady(on: queue) {
        if resume.isResumed { return }
        while input.isReadyForMoreMediaData {
          autoreleasepool {
            if Task.isCancelled {
              input.markAsFinished()
              resume.resume(continuation: continuation, throwing: CancellationError())
              return
            }
            guard let nextSampleBuffer = output.copyNextSampleBuffer() else {
              input.markAsFinished()
              resume.resume(continuation: continuation, throwing: nil)
              return
            }
            let pts = nextSampleBuffer.presentationTimeStamp
            updateProgress(progress, pts: pts)
            if !input.append(nextSampleBuffer) {
              input.markAsFinished()
              resume.resume(
                continuation: continuation,
                throwing: Error.appendFailed(pts))
              return
            }
          }
          if resume.isResumed { break }
        }
      }
    } as Void
  }

  private static func processVideoSamples(
    from assetReaderOutput: AVAssetReaderOutput,
    to assetWriterInput: AVAssetWriterInput,
    adaptor: AVAssetWriterInputPixelBufferAdaptor,
    inputSize: CGSize,
    outputSize: CGSize,
    progress: Progress
  ) async throws {
    guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
      throw Error.failedToCreateUpscaler
    }
    nonisolated(unsafe) let input = assetWriterInput
    nonisolated(unsafe) let output = assetReaderOutput
    nonisolated(unsafe) let adaptor = adaptor
    let resume = AsyncResume()
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Swift.Error>) in
      let queue = DispatchQueue(label: "com.upscaling.video", qos: .userInitiated)
      input.requestMediaDataWhenReady(on: queue) {
        if resume.isResumed { return }
        while input.isReadyForMoreMediaData {
          autoreleasepool {
            if Task.isCancelled {
              input.markAsFinished()
              resume.resume(continuation: continuation, throwing: CancellationError())
              return
            }
            guard let nextSampleBuffer = output.copyNextSampleBuffer() else {
              input.markAsFinished()
              resume.resume(continuation: continuation, throwing: nil)
              return
            }
            let pts = nextSampleBuffer.presentationTimeStamp
            updateProgress(progress, pts: pts)
            guard let imageBuffer = nextSampleBuffer.imageBuffer else {
              input.markAsFinished()
              resume.resume(continuation: continuation, throwing: Error.missingImageBuffer)
              return
            }
            let upscaled: CVPixelBuffer
            do {
              upscaled = try upscaler.upscale(
                imageBuffer, pixelBufferPool: adaptor.pixelBufferPool)
            } catch {
              input.markAsFinished()
              resume.resume(continuation: continuation, throwing: error)
              return
            }
            if !adaptor.append(upscaled, withPresentationTime: pts) {
              input.markAsFinished()
              resume.resume(
                continuation: continuation,
                throwing: Error.appendFailed(pts))
              return
            }
          }
          if resume.isResumed { break }
        }
      }
    } as Void
  }

  @available(macOS 14.0, iOS 17.0, *)
  private static func processSpatialVideoSamples(
    from assetReaderOutput: AVAssetReaderOutput,
    to assetWriterInput: AVAssetWriterInput,
    adaptor: NSObject,
    inputSize: CGSize,
    outputSize: CGSize,
    progress: Progress
  ) async throws {
    // Construction in `export()` is the only place this enum case is instantiated, and it's
    // always built from an `AVAssetWriterInputTaggedPixelBufferGroupAdaptor`. A failure here
    // is a programmer error, not a runtime condition.
    guard let taggedAdaptor = adaptor as? AVAssetWriterInputTaggedPixelBufferGroupAdaptor else {
      preconditionFailure("MediaTrack.spatialVideo adaptor was not a tagged-buffer adaptor")
    }
    guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
      throw Error.failedToCreateUpscaler
    }
    nonisolated(unsafe) let input = assetWriterInput
    nonisolated(unsafe) let output = assetReaderOutput
    nonisolated(unsafe) let adaptor = taggedAdaptor
    let resume = AsyncResume()
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Swift.Error>) in
      let queue = DispatchQueue(label: "com.upscaling.spatialvideo", qos: .userInitiated)
      input.requestMediaDataWhenReady(on: queue) {
        if resume.isResumed { return }
        while input.isReadyForMoreMediaData {
          autoreleasepool {
            if Task.isCancelled {
              input.markAsFinished()
              resume.resume(continuation: continuation, throwing: CancellationError())
              return
            }
            guard let nextSampleBuffer = output.copyNextSampleBuffer() else {
              input.markAsFinished()
              resume.resume(continuation: continuation, throwing: nil)
              return
            }
            let pts = nextSampleBuffer.presentationTimeStamp
            updateProgress(progress, pts: pts)
            guard let taggedBuffers = nextSampleBuffer.taggedBuffers else {
              input.markAsFinished()
              resume.resume(continuation: continuation, throwing: Error.missingTaggedBuffers)
              return
            }
            // Single pass over the tagged-buffer array — previously scanned twice per frame.
            var leftEye: CVPixelBuffer?
            var rightEye: CVPixelBuffer?
            for tagged in taggedBuffers {
              let stereoTag = tagged.tags.first(matchingCategory: .stereoView)
              if stereoTag == .stereoView(.leftEye),
                case .pixelBuffer(let buffer) = tagged.buffer
              {
                leftEye = buffer
              } else if stereoTag == .stereoView(.rightEye),
                case .pixelBuffer(let buffer) = tagged.buffer
              {
                rightEye = buffer
              }
              if leftEye != nil && rightEye != nil { break }
            }
            guard let leftEyePixelBuffer = leftEye,
              let rightEyePixelBuffer = rightEye
            else {
              input.markAsFinished()
              resume.resume(continuation: continuation, throwing: Error.invalidTaggedBuffers)
              return
            }
            let upscaledLeft: CVPixelBuffer
            let upscaledRight: CVPixelBuffer
            do {
              upscaledLeft = try upscaler.upscale(
                leftEyePixelBuffer, pixelBufferPool: adaptor.pixelBufferPool)
              upscaledRight = try upscaler.upscale(
                rightEyePixelBuffer, pixelBufferPool: adaptor.pixelBufferPool)
            } catch {
              input.markAsFinished()
              resume.resume(continuation: continuation, throwing: error)
              return
            }
            let leftTagged = CMTaggedBuffer(
              tags: [.stereoView(.leftEye), .videoLayerID(0)],
              pixelBuffer: upscaledLeft)
            let rightTagged = CMTaggedBuffer(
              tags: [.stereoView(.rightEye), .videoLayerID(1)],
              pixelBuffer: upscaledRight)
            if !adaptor.appendTaggedBuffers(
              [leftTagged, rightTagged], withPresentationTime: pts)
            {
              input.markAsFinished()
              resume.resume(
                continuation: continuation,
                throwing: Error.appendFailed(pts))
              return
            }
          }
          if resume.isResumed { break }
        }
      }
    } as Void
  }
}

// MARK: - AsyncResume

/// Helper that guarantees a `CheckedContinuation` is resumed exactly once.
private final class AsyncResume: @unchecked Sendable {
  private let lock = NSLock()
  private var resumed = false

  var isResumed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return resumed
  }

  func resume(
    continuation: CheckedContinuation<Void, Swift.Error>,
    throwing error: Swift.Error?
  ) {
    lock.lock()
    if resumed {
      lock.unlock()
      return
    }
    resumed = true
    lock.unlock()
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume()
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
    case failedToCreateUpscaler
    case failedToStartWriting
    case failedToStartReading
    case appendFailed(CMTime)
    case hdrNotSupported
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
      case .failedToCreateUpscaler:
        "Failed to create the MetalFX upscaler. This device may not support MetalFX."
      case .failedToStartWriting:
        "AVAssetWriter failed to start writing."
      case .failedToStartReading:
        "AVAssetReader failed to start reading."
      case .appendFailed(let time):
        "Failed to append sample at time \(time.seconds)s."
      case .hdrNotSupported:
        "HDR (PQ / HLG) video is not supported by this 8-bit upscaling path."
      case .noMediaTracks:
        "Input asset contains no media tracks to export."
      }
    }
  }
}
