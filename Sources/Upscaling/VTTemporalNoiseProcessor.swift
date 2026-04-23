import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// MARK: - VTTemporalNoiseProcessor

/// Performs `VTFrameProcessor` temporal-noise filtering on `CVPixelBuffer`s.
///
/// Denoise is a 1:1 effect: one input frame produces one output frame at the same dimensions.
/// The processor is **stateful** — it retains the prior source frame across `process(...)` calls
/// to accumulate temporal coherence. Feed frames in presentation-time order; concurrent calls
/// serialize on the actor.
///
/// - Important: The temporal-noise processor has strict input constraints that are checked at
///   init time and surface as `Error` cases before any pixels are touched:
///   - The device must return `true` for `VTTemporalNoiseFilterConfiguration.isSupported`.
///   - Input size must be within the processor's supported dimensions.
///   - `strength` must be in the 1–100 range. The integer is mapped to the native Float
///     0.0–1.0 `filterStrength` range documented by `VTTemporalNoiseFilterParameters`.
public actor VTTemporalNoiseProcessor: FrameProcessorBackend {
  // MARK: Lifecycle

  /// Creates a temporal-noise processor for frames at the given size.
  ///
  /// Denoise preserves dimensions, so `inputSize == outputSize == frameSize`.
  public init(frameSize: CGSize, strength: Int) async throws {
    self.frameSize = frameSize
    self.filterStrength = Float(try Self.validateStrength(strength)) / Float(Self.maxStrength)

    self.core = try VTStatefulBackendCore(
      configuration: try Self.makeConfiguration(frameSize: frameSize),
      poolSize: frameSize,
      minimumPoolBufferCount: Self.minimumPoolBufferCount,
      backend: .temporalNoise)
  }

  /// Cheap synchronous validation that only checks strength bounds and whether the
  /// configuration can be constructed at the requested dimensions. Does not start a session.
  public static func preflight(frameSize: CGSize, strength: Int) throws {
    _ = try validateStrength(strength)
    _ = try makeConfiguration(frameSize: frameSize)
  }

  // MARK: Public

  public nonisolated var inputSize: CGSize { frameSize }
  public nonisolated var outputSize: CGSize { frameSize }
  public static let displayName = "Denoise"
  public nonisolated var displayName: String { Self.displayName }

  public nonisolated var requiresInstancePerStream: Bool { true }

  public func process(
    _ pixelBuffer: sending CVPixelBuffer,
    presentationTimeStamp: CMTime,
    outputPool externalPool: sending CVPixelBufferPool?
  ) async throws -> [FrameProcessorOutput] {
    let vtPts = core.nextPts(frameIndex: &frameIndex)
    let sourceFrame = try core.makeFrame(pixelBuffer, pts: vtPts)

    // The API requires at least one reference frame (previous or next). This backend doesn't
    // look ahead, so the first frame has neither — pass it through unchanged and apply the
    // filter from the second frame onward.
    guard let previousSourceFrame else {
      self.previousSourceFrame = sourceFrame
      nonisolated(unsafe) let passthrough = pixelBuffer
      return [
        FrameProcessorOutput(pixelBuffer: passthrough, presentationTimeStamp: presentationTimeStamp)
      ]
    }

    let output = try resolveProcessorOutputBuffer(
      input: pixelBuffer,
      expectedInputSize: frameSize,
      expectedOutputSize: frameSize,
      externalPool: externalPool,
      internalPool: core.pixelBufferPool,
      providedOutput: nil
    )

    let destinationFrame = try core.makeFrame(output, pts: vtPts)
    guard
      let parameters = VTTemporalNoiseFilterParameters(
        sourceFrame: sourceFrame,
        nextFrames: [],
        previousFrames: [previousSourceFrame],
        destinationFrame: destinationFrame,
        filterStrength: filterStrength,
        hasDiscontinuity: false
      )
    else {
      throw VTBackendError.vtFrameConstructionFailed(backend: .temporalNoise)
    }

    try await core.run(parameters: SendableBox(parameters))

    self.previousSourceFrame = sourceFrame

    return [FrameProcessorOutput(pixelBuffer: output, presentationTimeStamp: presentationTimeStamp)]
  }

  public func finish(
    outputPool _: sending CVPixelBufferPool?
  ) async throws -> [FrameProcessorOutput] {
    // Release the retained previous source wrapper so its buffer isn't kept alive past the
    // end of the stream. This backend doesn't look ahead, so nothing is flushed.
    previousSourceFrame = nil
    return []
  }

  // MARK: Private

  /// `kCVPixelBufferPoolMinimumBufferCountKey` value. We hold the previous source wrapper
  /// across calls, and the next stage may hold our output while we start the next frame.
  private static let minimumPoolBufferCount = 4

  /// Public-facing strength bounds. Mapped to the native 0.0–1.0 `filterStrength` range.
  private static let minStrength = 1
  private static let maxStrength = 100

  /// Source pixel format the rest of the pipeline uses end-to-end.
  private static let sourcePixelFormat: OSType = kCVPixelFormatType_32BGRA

  private let frameSize: CGSize
  private let filterStrength: Float
  private let core: VTStatefulBackendCore

  private var frameIndex: UInt64 = 0
  private var previousSourceFrame: VTFrameProcessorFrame?

  @discardableResult
  private static func validateStrength(_ strength: Int) throws -> Int {
    guard (minStrength...maxStrength).contains(strength) else {
      throw Error.strengthOutOfRange(
        requested: strength, minimum: minStrength, maximum: maxStrength)
    }
    return strength
  }

  /// Builds and validates a `VTTemporalNoiseFilterConfiguration` for this frame size.
  ///
  /// Factored out so `preflight(...)` and `init(...)` share one source of truth for the
  /// dimension / device-support / pixel-format rules. Construction is cheap — it does not
  /// start a session.
  private static func makeConfiguration(
    frameSize: CGSize
  ) throws -> VTTemporalNoiseFilterConfiguration {
    guard VTTemporalNoiseFilterConfiguration.isSupported else {
      throw VTBackendError.notSupportedOnDevice(backend: .temporalNoise)
    }

    let (frameWidth, frameHeight) = frameSize.intDimensions

    guard
      let configuration = VTTemporalNoiseFilterConfiguration(
        frameWidth: frameWidth,
        frameHeight: frameHeight,
        sourcePixelFormat: sourcePixelFormat
      )
    else {
      throw Error.configurationInitFailed(frameWidth: frameWidth, frameHeight: frameHeight)
    }

    return configuration
  }
}

// MARK: VTTemporalNoiseProcessor.Error

extension VTTemporalNoiseProcessor {
  public enum Error: Swift.Error, LocalizedError {
    case strengthOutOfRange(requested: Int, minimum: Int, maximum: Int)
    case configurationInitFailed(frameWidth: Int, frameHeight: Int)

    public var errorDescription: String? {
      switch self {
      case .strengthOutOfRange(let requested, let minimum, let maximum):
        "Denoise strength \(requested) is out of range. "
          + "Valid range is \(minimum)–\(maximum)."
      case .configurationInitFailed(let frameWidth, let frameHeight):
        "Temporal noise filter rejected the input configuration "
          + "(\(frameWidth)×\(frameHeight)). The dimensions may exceed the processor's "
          + "supported range, or the source pixel format may be unsupported."
      }
    }
  }
}
