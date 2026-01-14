@preconcurrency import AVFoundation
import VideoToolbox

// MARK: - UpscalingExportSession

public final class UpscalingExportSession: @unchecked Sendable {
  // MARK: Lifecycle

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
    progress = Progress(
      parent: nil,
      userInfo: [
        .fileURLKey: outputURL
      ])
    progress.fileURL = outputURL
    progress.isCancellable = false
    #if os(macOS)
      progress.publish()
    #endif
  }

  // MARK: Public

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

    var mediaTracks: [MediaTrack] = []
    let tracks = try await asset.load(.tracks)
    for track in tracks {
      guard [.audio, .video].contains(track.mediaType) else { continue }
      let formatDescription = try await track.load(.formatDescriptions).first

      guard
        let assetReaderOutput = Self.assetReaderOutput(
          for: track,
          formatDescription: formatDescription
        ),
        let assetWriterInput = try await Self.assetWriterInput(
          for: track,
          formatDescription: formatDescription,
          outputSize: outputSize,
          outputCodec: outputCodec,
          quality: quality
        )
      else { continue }

      if assetReader.canAdd(assetReaderOutput) {
        assetReader.add(assetReaderOutput)
      } else {
        throw Error.couldNotAddAssetReaderOutput(track.mediaType)
      }

      if assetWriter.canAdd(assetWriterInput) {
        assetWriter.add(assetWriterInput)
      } else {
        throw Error.couldNotAddAssetWriterInput(track.mediaType)
      }

      if track.mediaType == .audio {
        progress.totalUnitCount += 1
        mediaTracks.append(.audio(assetReaderOutput, assetWriterInput))
      } else if track.mediaType == .video {
        progress.totalUnitCount += 10
        if #available(macOS 14.0, iOS 17.0, *),
          formatDescription?.hasLeftAndRightEye ?? false
        {
          try await mediaTracks.append(
            .spatialVideo(
              assetReaderOutput,
              assetWriterInput,
              track.load(.naturalSize),
              AVAssetWriterInputTaggedPixelBufferGroupAdaptor(
                assetWriterInput: assetWriterInput,
                sourcePixelBufferAttributes: [
                  kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                  kCVPixelBufferMetalCompatibilityKey as String: true,
                  kCVPixelBufferWidthKey as String: outputSize.width,
                  kCVPixelBufferHeightKey as String: outputSize.height,
                ]
              )
            ))
        } else {
          try await mediaTracks.append(
            .video(
              assetReaderOutput,
              assetWriterInput,
              track.load(.naturalSize),
              AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: assetWriterInput,
                sourcePixelBufferAttributes: [
                  kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                  kCVPixelBufferMetalCompatibilityKey as String: true,
                  kCVPixelBufferWidthKey as String: outputSize.width,
                  kCVPixelBufferHeightKey as String: outputSize.height,
                ]
              )
            ))
        }
      }
    }

    assert(assetWriter.inputs.count == assetReader.outputs.count)

    assetWriter.startWriting()
    assetReader.startReading()
    assetWriter.startSession(atSourceTime: .zero)

    do {
      try await withThrowingTaskGroup(of: Void.self) { [weak self] group in
        for mediaTrack in mediaTracks {
          group.addTask { [weak self] in
            guard let self else { return }
            switch mediaTrack {
            case .audio(let output, let input):
              let progress = Progress(totalUnitCount: Int64(duration.seconds))
              self.progress.addChild(progress, withPendingUnitCount: 1)
              try await Self.processAudioSamples(from: output, to: input, progress: progress)
            case .video(let output, let input, let inputSize, let adaptor):
              let progress = Progress(totalUnitCount: Int64(duration.seconds))
              self.progress.addChild(progress, withPendingUnitCount: 10)
              try await Self.processVideoSamples(
                from: output,
                to: input,
                adaptor: adaptor,
                inputSize: inputSize,
                outputSize: outputSize,
                progress: progress
              )
            case .spatialVideo(let output, let input, let inputSize, let adaptor):
              if #available(macOS 14.0, iOS 17.0, *) {
                guard
                  let taggedAdaptor = adaptor as? AVAssetWriterInputTaggedPixelBufferGroupAdaptor
                else {
                  throw Error.invalidTaggedBufferAdaptor
                }
                let progress = Progress(totalUnitCount: Int64(duration.seconds))
                self.progress.addChild(progress, withPendingUnitCount: 10)
                try await Self.processSpatialVideoSamples(
                  from: output,
                  to: input,
                  adaptor: taggedAdaptor,
                  inputSize: inputSize,
                  outputSize: outputSize,
                  progress: progress
                )
              }
            }
          }
        }
        try await group.waitForAll()
      }
    } catch {
      try? FileManager.default.removeItem(at: outputURL)
      throw error
    }

    if let error = assetWriter.error {
      try? FileManager.default.removeItem(at: outputURL)
      throw error
    }
    if let error = assetReader.error {
      try? FileManager.default.removeItem(at: outputURL)
      throw error
    }
    if assetWriter.status == .cancelled || assetReader.status == .cancelled {
      try? FileManager.default.removeItem(at: outputURL)
      return
    }

    await assetWriter.finishWriting()

    if let creator {
      let value = try PropertyListSerialization.data(
        fromPropertyList: creator,
        format: .binary,
        options: 0
      )
      _ = outputURL.withUnsafeFileSystemRepresentation { fileSystemPath in
        value.withUnsafeBytes {
          setxattr(
            fileSystemPath,
            "com.apple.metadata:kMDItemCreator",
            $0.baseAddress,
            value.count,
            0,
            0
          )
        }
      }
    }
  }

  // MARK: Private

  private enum MediaTrack: @unchecked Sendable {
    case audio(
      _ output: AVAssetReaderOutput,
      _ input: AVAssetWriterInput
    )
    case video(
      _ output: AVAssetReaderOutput,
      _ input: AVAssetWriterInput,
      _ inputSize: CGSize,
      _ adaptor: AVAssetWriterInputPixelBufferAdaptor
    )
    case spatialVideo(
      _ output: AVAssetReaderOutput,
      _ input: AVAssetWriterInput,
      _ inputSize: CGSize,
      _ adaptor: NSObject
    )
  }

  private static func assetReaderOutput(
    for track: AVAssetTrack,
    formatDescription: CMFormatDescription?
  ) -> AVAssetReaderOutput? {
    switch track.mediaType {
    case .video:
      var outputSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ]
      if #available(macOS 14.0, iOS 17.0, *),
        formatDescription?.hasLeftAndRightEye ?? false
      {
        outputSettings[AVVideoDecompressionPropertiesKey] = [
          kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs: [0, 1]
        ]
      }
      let assetReaderOutput = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: outputSettings
      )
      assetReaderOutput.alwaysCopiesSampleData = false
      return assetReaderOutput
    case .audio:
      let assetReaderOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
      assetReaderOutput.alwaysCopiesSampleData = false
      return assetReaderOutput
    default: return nil
    }
  }

  private static func assetWriterInput(
    for track: AVAssetTrack,
    formatDescription: CMFormatDescription?,
    outputSize: CGSize,
    outputCodec: AVVideoCodecType?,
    quality: Double?
  ) async throws -> AVAssetWriterInput? {
    switch track.mediaType {
    case .video:
      var outputSettings: [String: Any] = [
        AVVideoWidthKey: outputSize.width,
        AVVideoHeightKey: outputSize.height,
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
            if let value = extensions.first(
              where: { $0.key == key }
            )?.value {
              compressionProperties[key as String] = value
            }
          }
        }
      }
      if !compressionProperties.isEmpty {
        outputSettings[AVVideoCompressionPropertiesKey] = compressionProperties
      }
      let assetWriterInput = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: outputSettings
      )
      assetWriterInput.transform = try await track.load(.preferredTransform)
      assetWriterInput.expectsMediaDataInRealTime = false
      return assetWriterInput
    case .audio:
      let assetWriterInput = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: nil,
        sourceFormatHint: formatDescription
      )
      assetWriterInput.expectsMediaDataInRealTime = false
      return assetWriterInput
    default: return nil
    }
  }

  private static func processAudioSamples(
    from assetReaderOutput: AVAssetReaderOutput,
    to assetWriterInput: AVAssetWriterInput,
    progress: Progress
  ) async throws {
    nonisolated(unsafe) let assetWriterInput = assetWriterInput
    nonisolated(unsafe) let assetReaderOutput = assetReaderOutput
    nonisolated(unsafe) var hasResumed = false
    try await withCheckedThrowingContinuation { continuation in
      let queue = DispatchQueue(
        label: "\(String(describing: Self.self)).audio.\(UUID().uuidString)",
        qos: .userInitiated
      )
      assetWriterInput.requestMediaDataWhenReady(on: queue) {
        guard !hasResumed else { return }
        while assetWriterInput.isReadyForMoreMediaData {
          if let nextSampleBuffer = assetReaderOutput.copyNextSampleBuffer() {
            if nextSampleBuffer.presentationTimeStamp.isNumeric {
              progress.completedUnitCount = Int64(nextSampleBuffer.presentationTimeStamp.seconds)
            }
            guard assetWriterInput.append(nextSampleBuffer) else {
              assetWriterInput.markAsFinished()
              hasResumed = true
              continuation.resume()
              return
            }
          } else {
            assetWriterInput.markAsFinished()
            hasResumed = true
            continuation.resume()
            return
          }
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
    nonisolated(unsafe) let assetWriterInput = assetWriterInput
    nonisolated(unsafe) let assetReaderOutput = assetReaderOutput
    nonisolated(unsafe) let adaptor = adaptor
    nonisolated(unsafe) var hasResumed = false
    try await withCheckedThrowingContinuation { continuation in
      let queue = DispatchQueue(
        label: "\(String(describing: Self.self)).video.\(UUID().uuidString)",
        qos: .userInitiated
      )
      assetWriterInput.requestMediaDataWhenReady(on: queue) {
        guard !hasResumed else { return }
        while assetWriterInput.isReadyForMoreMediaData {
          if let nextSampleBuffer = assetReaderOutput.copyNextSampleBuffer() {
            if nextSampleBuffer.presentationTimeStamp.isNumeric {
              let timestamp = Int64(nextSampleBuffer.presentationTimeStamp.seconds)
              DispatchQueue.main.async {
                progress.completedUnitCount = timestamp
              }
            }
            if let imageBuffer = nextSampleBuffer.imageBuffer {
              let upscaledImageBuffer = upscaler.upscale(
                imageBuffer,
                pixelBufferPool: adaptor.pixelBufferPool
              )
              guard
                adaptor.append(
                  upscaledImageBuffer,
                  withPresentationTime: nextSampleBuffer.presentationTimeStamp
                )
              else {
                assetWriterInput.markAsFinished()
                hasResumed = true
                continuation.resume()
                return
              }
            } else {
              assetWriterInput.markAsFinished()
              hasResumed = true
              continuation.resume(throwing: Error.missingImageBuffer)
              return
            }
          } else {
            assetWriterInput.markAsFinished()
            hasResumed = true
            continuation.resume()
            return
          }
        }
      }
    } as Void
  }

  @available(macOS 14.0, iOS 17.0, *) private static func processSpatialVideoSamples(
    from assetReaderOutput: AVAssetReaderOutput,
    to assetWriterInput: AVAssetWriterInput,
    adaptor: AVAssetWriterInputTaggedPixelBufferGroupAdaptor,
    inputSize: CGSize,
    outputSize: CGSize,
    progress: Progress
  ) async throws {
    guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
      throw Error.failedToCreateUpscaler
    }
    nonisolated(unsafe) let assetWriterInput = assetWriterInput
    nonisolated(unsafe) let assetReaderOutput = assetReaderOutput
    nonisolated(unsafe) let adaptor = adaptor
    nonisolated(unsafe) var hasResumed = false
    try await withCheckedThrowingContinuation { continuation in
      let queue = DispatchQueue(
        label: "\(String(describing: Self.self)).spatialvideo.\(UUID().uuidString)",
        qos: .userInitiated
      )
      assetWriterInput.requestMediaDataWhenReady(on: queue) {
        guard !hasResumed else { return }
        while assetWriterInput.isReadyForMoreMediaData {
          if let nextSampleBuffer = assetReaderOutput.copyNextSampleBuffer() {
            if nextSampleBuffer.presentationTimeStamp.isNumeric {
              let timestamp = Int64(nextSampleBuffer.presentationTimeStamp.seconds)
              DispatchQueue.main.async {
                progress.completedUnitCount = timestamp
              }
            }
            if let taggedBuffers = nextSampleBuffer.taggedBuffers {
              let leftEyeBuffer = taggedBuffers.first(where: {
                $0.tags.first(matchingCategory: .stereoView) == .stereoView(.leftEye)
              })?.buffer
              let rightEyeBuffer = taggedBuffers.first(where: {
                $0.tags.first(matchingCategory: .stereoView) == .stereoView(.rightEye)
              })?.buffer
              guard let leftEyeBuffer,
                let rightEyeBuffer,
                case .pixelBuffer(let leftEyePixelBuffer) = leftEyeBuffer,
                case .pixelBuffer(let rightEyePixelBuffer) = rightEyeBuffer
              else {
                assetWriterInput.markAsFinished()
                hasResumed = true
                continuation.resume(throwing: Error.invalidTaggedBuffers)
                return
              }
              let upscaledLeftEyePixelBuffer = upscaler.upscale(
                leftEyePixelBuffer,
                pixelBufferPool: adaptor.pixelBufferPool
              )
              let upscaledRightEyePixelBuffer = upscaler.upscale(
                rightEyePixelBuffer,
                pixelBufferPool: adaptor.pixelBufferPool
              )
              let leftEyeTaggedBuffer = CMTaggedBuffer(
                tags: [.stereoView(.leftEye), .videoLayerID(0)],
                pixelBuffer: upscaledLeftEyePixelBuffer
              )
              let rightEyeTaggedBuffer = CMTaggedBuffer(
                tags: [.stereoView(.rightEye), .videoLayerID(1)],
                pixelBuffer: upscaledRightEyePixelBuffer
              )
              guard
                adaptor.appendTaggedBuffers(
                  [leftEyeTaggedBuffer, rightEyeTaggedBuffer],
                  withPresentationTime: nextSampleBuffer.presentationTimeStamp
                )
              else {
                assetWriterInput.markAsFinished()
                hasResumed = true
                continuation.resume()
                return
              }
            } else {
              assetWriterInput.markAsFinished()
              hasResumed = true
              continuation.resume(throwing: Error.missingTaggedBuffers)
              return
            }
          } else {
            assetWriterInput.markAsFinished()
            hasResumed = true
            continuation.resume()
            return
          }
        }
      }
    } as Void
  }
}

// MARK: UpscalingExportSession.Error

extension UpscalingExportSession {
  public enum Error: Swift.Error {
    case outputURLAlreadyExists
    case couldNotAddAssetReaderOutput(AVMediaType)
    case couldNotAddAssetWriterInput(AVMediaType)
    case missingImageBuffer
    case missingTaggedBuffers
    case invalidTaggedBuffers
    case invalidTaggedBufferAdaptor
    case failedToCreateUpscaler
  }
}
