import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// MARK: - VTMotionBlurProcessor

/// Performs `VTFrameProcessor` motion-blur synthesis on `CVPixelBuffer`s.
///
/// Motion blur is a 1:1 effect: one input frame produces one output frame at the same
/// dimensions. The processor is **stateful** — it retains the prior source frame across
/// `process(...)` calls to derive motion. Feed frames in presentation-time order; concurrent
/// calls serialize on the actor.
///
/// - Important: The motion-blur processor has strict input constraints that are checked at
///   init time and surface as `Error` cases before any pixels are touched:
///   - Input size must be within the processor's `maximumDimensions` (macOS: 8192×4320).
///   - The device must return `true` for `VTMotionBlurConfiguration.isSupported`.
///   - `strength` must be in the 1–100 range documented by the configuration.
public actor VTMotionBlurProcessor: FrameProcessorBackend {
  // MARK: FrameProcessorBackend

  public nonisolated let requiresInstancePerStream: Bool = true

  // MARK: Lifecycle

  /// Creates a motion-blur processor for frames at the given size.
  ///
  /// Motion blur preserves dimensions, so `inputSize == outputSize == frameSize`.
  public init(frameSize: CGSize, strength: Int) async throws {
    self.frameSize = frameSize
    self.strength = try Self.validateStrength(strength)

    let configuration = try Self.makeConfiguration(frameSize: frameSize)

    let processor = VTFrameProcessor()
    try processor.startSession(configuration: configuration)
    self.processor = processor

    guard
      let pixelBufferPool = makeBGRAPixelBufferPool(
        size: frameSize, minimumBufferCount: Self.minimumPoolBufferCount)
    else { throw Error.pixelBufferPoolCreationFailed }
    self.pixelBufferPool = pixelBufferPool
  }

  isolated deinit {
    processor.endSession()
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

  public func process(
    _ pixelBuffer: sending CVPixelBuffer,
    presentationTimeStamp: CMTime,
    outputPool externalPool: sending CVPixelBufferPool?
  ) async throws -> [FrameProcessorOutput] {
    // Synthesize a monotonically increasing PTS for VT's internal ordering check. VT rejects
    // out-of-order timestamps but doesn't care what base they use; the `presentationTimeStamp`
    // we expose on the returned `FrameProcessorOutput` is the real source PTS.
    let vtPts = CMTime(value: Int64(frameIndex), timescale: Self.syntheticTimescale)
    frameIndex &+= 1

    guard
      let sourceFrame = VTFrameProcessorFrame(
        buffer: pixelBuffer, presentationTimeStamp: vtPts)
    else {
      throw Error.vtFrameConstructionFailed
    }

    // VT returns -19730 if both previous and next reference frames are missing. This backend
    // doesn't look ahead, so the first frame has neither — pass it through unchanged and
    // apply motion blur from the second frame onward.
    guard let previousSourceFrame else {
      self.previousSourceFrame = sourceFrame
      nonisolated(unsafe) let passthrough = pixelBuffer
      return [
        FrameProcessorOutput(pixelBuffer: passthrough, presentationTimeStamp: presentationTimeStamp)
      ]
    }

    let output = try resolveUpscalerOutputBuffer(
      input: pixelBuffer,
      expectedInputSize: frameSize,
      expectedOutputSize: frameSize,
      externalPool: externalPool,
      internalPool: pixelBufferPool,
      providedOutput: nil
    )

    guard
      let destinationFrame = VTFrameProcessorFrame(
        buffer: output, presentationTimeStamp: vtPts),
      let parameters = VTMotionBlurParameters(
        sourceFrame: sourceFrame,
        nextFrame: nil,
        previousFrame: previousSourceFrame,
        nextOpticalFlow: nil,
        previousOpticalFlow: nil,
        motionBlurStrength: strength,
        submissionMode: .sequential,
        destinationFrame: destinationFrame
      )
    else {
      throw Error.vtFrameConstructionFailed
    }

    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Swift.Error>) in
      processor.process(parameters: parameters) { _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }

    self.previousSourceFrame = sourceFrame

    return [FrameProcessorOutput(pixelBuffer: output, presentationTimeStamp: presentationTimeStamp)]
  }

  // MARK: Private

  /// `kCVPixelBufferPoolMinimumBufferCountKey` value. We hold the previous source wrapper
  /// across calls, so the pool needs at least one more live buffer than a purely stateless
  /// path would.
  private static let minimumPoolBufferCount = 3

  /// Fixed timescale for synthesized PTS. Any constant works — VT only cares about monotonicity.
  private static let syntheticTimescale: CMTimeScale = 600

  /// API-documented strength bounds from `VTMotionBlurParameters`.
  private static let minStrength = 1
  private static let maxStrength = 100

  private let frameSize: CGSize
  private let strength: Int
  private let processor: VTFrameProcessor
  private let pixelBufferPool: CVPixelBufferPool

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

  /// Builds and validates a `VTMotionBlurConfiguration` for this frame size.
  ///
  /// Factored out so `preflight(...)` and `init(...)` share one source of truth for the
  /// dimension / device-support rules. Construction is cheap — it does not start a session.
  private static func makeConfiguration(
    frameSize: CGSize
  ) throws -> VTMotionBlurConfiguration {
    guard VTMotionBlurConfiguration.isSupported else {
      throw Error.notSupportedOnDevice
    }

    let frameWidth = Int(frameSize.width.rounded())
    let frameHeight = Int(frameSize.height.rounded())

    guard
      let configuration = VTMotionBlurConfiguration(
        frameWidth: frameWidth,
        frameHeight: frameHeight,
        usePrecomputedFlow: false,
        qualityPrioritization: .normal,
        revision: VTMotionBlurConfiguration.defaultRevision
      )
    else {
      throw Error.configurationInitFailed(frameWidth: frameWidth, frameHeight: frameHeight)
    }

    return configuration
  }
}

// MARK: VTMotionBlurProcessor.Error

extension VTMotionBlurProcessor {
  public enum Error: Swift.Error, LocalizedError {
    case notSupportedOnDevice
    case strengthOutOfRange(requested: Int, minimum: Int, maximum: Int)
    case configurationInitFailed(frameWidth: Int, frameHeight: Int)
    case pixelBufferPoolCreationFailed
    case vtFrameConstructionFailed

    public var errorDescription: String? {
      switch self {
      case .notSupportedOnDevice:
        "The VideoToolbox motion-blur processor is not supported on this device."
      case .strengthOutOfRange(let requested, let minimum, let maximum):
        "Motion-blur strength \(requested) is out of range. "
          + "Valid range is \(minimum)–\(maximum) (50 matches a 180° film shutter)."
      case .configurationInitFailed(let frameWidth, let frameHeight):
        "Motion blur rejected the input configuration (\(frameWidth)×\(frameHeight)). "
          + "On macOS, inputs must be ≤ 8192×4320."
      case .pixelBufferPoolCreationFailed:
        "Failed to create the motion-blur output pixel buffer pool."
      case .vtFrameConstructionFailed:
        "Failed to construct motion-blur frame parameters "
          + "(pixel buffers must be IOSurface-backed)."
      }
    }
  }
}
